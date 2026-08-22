data "azurerm_client_config" "current" {}

locals {
  tenant_root_group_id = "/providers/Microsoft.Management/managementGroups/${var.tenant_id}"

  common_tags = {
    week       = "bootstrap"
    env        = "platform"
    managed-by = "terraform"
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Management groups
//
// A management group answers "what is allowed here?". It holds no resources.
// Policy and RBAC assigned to one apply to every subscription below it,
// including subscriptions that do not exist yet, which is what makes placement
// the primary governance decision and keeps this tree shallow.
//
// Nothing is assigned at Tenant Root Group. An assignment there reaches every
// subscription in the tenant forever, and undoing it needs elevated access.
// mg-katta is the intermediate root so the blast radius stops at the lab.
// ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_management_group" "root" {
  name                       = var.root_management_group_name
  display_name               = "Katta Platform"
  parent_management_group_id = local.tenant_root_group_id
}

// ── Platform: permanent shared services, strictest policy ──────────────────

resource "azurerm_management_group" "platform" {
  name                       = "mg-platform"
  display_name               = "Platform"
  parent_management_group_id = azurerm_management_group.root.id
}

// Split from management rather than merged with it because whoever can rewrite
// the hub network's routing should not by the same grant be able to read every
// diagnostic log in the estate. In a solo lab that separation is academic; it is
// also free, and it is the subject of the governance posts.
resource "azurerm_management_group" "connectivity" {
  name                       = "mg-connectivity"
  display_name               = "Connectivity"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "management" {
  name                       = "mg-management"
  display_name               = "Management"
  parent_management_group_id = azurerm_management_group.platform.id
}

// ── Landing zones: where workloads live ────────────────────────────────────

resource "azurerm_management_group" "landing_zones" {
  name                       = "mg-landingzones"
  display_name               = "Landing Zones"
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "lz_dev" {
  name                       = "mg-lz-dev"
  display_name               = "Landing Zones - Dev"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

// ── Sandbox: the pre-existing subscription, quarantined ────────────────────
//
// The existing subscription carries seven resource groups of accumulated
// history and a wide provider surface from years of experimentation. Adopting
// it as lab infrastructure would mean every policy-compliance screenshot has
// pre-existing noise in it. It stays useful for throwaway work and is not
// depended on.

resource "azurerm_management_group" "sandbox" {
  name                       = "mg-sandbox"
  display_name               = "Sandbox"
  parent_management_group_id = azurerm_management_group.root.id
}

// ── Decommissioned ─────────────────────────────────────────────────────────
//
// This node exists because a cancelled Azure subscription does not disappear.
// It enters a retention period during which it still exists, still appears in
// listings, and can still be reactivated. It needs somewhere to sit under a
// deny-all assignment for that window.

resource "azurerm_management_group" "decommissioned" {
  name                       = "mg-decommissioned"
  display_name               = "Decommissioned"
  parent_management_group_id = azurerm_management_group.root.id
}

locals {
  // Keyed so var.subscriptions can name a parent without repeating resource IDs.
  management_groups = {
    root           = azurerm_management_group.root.id
    platform       = azurerm_management_group.platform.id
    connectivity   = azurerm_management_group.connectivity.id
    management     = azurerm_management_group.management.id
    landing_zones  = azurerm_management_group.landing_zones.id
    lz_dev         = azurerm_management_group.lz_dev.id
    sandbox        = azurerm_management_group.sandbox.id
    decommissioned = azurerm_management_group.decommissioned.id
  }
}

// Move the pre-existing subscription under mg-sandbox.
//
// Done as a separate association resource rather than through the management
// group's own subscription_ids argument: that argument is authoritative, so
// Terraform would fight anything that later moves a subscription in or out by
// any other means. The association resource manages exactly one edge.
resource "azurerm_management_group_subscription_association" "sandbox" {
  management_group_id = azurerm_management_group.sandbox.id
  subscription_id     = "/subscriptions/${var.sandbox_subscription_id}"
}

// ═══════════════════════════════════════════════════════════════════════════
// Subscriptions
//
// A subscription answers "who pays, and what is the ceiling?". Quota is counted
// per subscription per region, which is the whole reason there is more than one
// here: a runaway lab week must not be able to exhaust the vCPU the hub network
// and logging depend on.
//
// Gated behind var.create_subscriptions. The billing account is Microsoft
// Customer Agreement (Individual), which should make the Subscription Alias API
// available, but that has not been proven on this account. Apply once with the
// flag false, confirm the tree and the identity, then flip it.
// ═══════════════════════════════════════════════════════════════════════════

data "azurerm_billing_mca_account_scope" "lab" {
  count = var.create_subscriptions ? 1 : 0

  billing_account_name = var.billing_account_name
  billing_profile_name = var.billing_profile_name
  invoice_section_name = var.invoice_section_name
}

resource "azurerm_subscription" "lab" {
  for_each = var.create_subscriptions ? var.subscriptions : {}

  subscription_name = each.value.display_name
  alias             = each.value.display_name
  billing_scope_id  = data.azurerm_billing_mca_account_scope.lab[0].id

  tags = local.common_tags

  # Subscription alias creation is slow and wildly variable — measured
  # 2026-08-22 on this billing account, one subscription completed in about ten
  # minutes and another blew past the provider's default and failed with:
  #
  #   performing AliasCreate: Failure sending request: StatusCode=0
  #   -- Original Error: context deadline exceeded
  #
  # StatusCode=0 means no HTTP response was ever received, so this is a client
  # giving up rather than Azure rejecting anything. Azure often finishes the
  # creation anyway, which leaves a subscription that exists but is absent from
  # state — the worst outcome available, since subscriptions cannot be deleted.
  #
  # Create them ONE AT A TIME with -target on first run. Three at once produced
  # an apply that sat for an hour and committed nothing.
  timeouts {
    create = "60m"
    read   = "10m"
  }
}

resource "azurerm_management_group_subscription_association" "lab" {
  for_each = var.create_subscriptions ? var.subscriptions : {}

  management_group_id = local.management_groups[each.value.management_group]
  subscription_id     = "/subscriptions/${azurerm_subscription.lab[each.key].subscription_id}"
}

// A budget alerts. It does not stop spend. Nothing with a per-hour price is
// deployed by any week until the budget for its subscription exists.
resource "azurerm_consumption_budget_subscription" "lab" {
  for_each = var.create_subscriptions ? var.subscriptions : {}

  name = "budget-${each.key}-monthly"
  // NOT azurerm_subscription.lab[each.key].id — that attribute is the ALIAS
  // resource ID, "/providers/Microsoft.Subscription/aliases/sub-connectivity",
  // because the resource models the alias rather than the subscription. The
  // budget wants a subscription ID, and fails to parse the alias form with:
  //
  //   parsing "/providers/Microsoft.Subscription/aliases/sub-connectivity":
  //   parsing segment "subscriptions": the segment at position 0 didn't match
  //
  // The `subscription_id` ATTRIBUTE holds the bare GUID, so build the real
  // resource ID from that.
  subscription_id = "/subscriptions/${azurerm_subscription.lab[each.key].subscription_id}"

  amount     = each.value.monthly_budget
  time_grain = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }

  // Forecasted, not actual — an actual-spend alert at 90% of a monthly budget
  // arrives after the money is already committed. The forecast is what gives
  // enough warning to tear something down.
  notification {
    enabled        = true
    threshold      = 90
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_alert_emails
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CI identity — federated credentials only, no client secret
//
// There is no azuread_application_password anywhere in this repo and there
// never will be. HCP Terraform presents an OIDC token; Entra exchanges it for
// an access token because the token's issuer, audience and subject match a
// federated identity credential registered below.
// ═══════════════════════════════════════════════════════════════════════════

resource "azuread_application" "terraform" {
  display_name     = "sp-hcp-terraform-lab"
  owners           = [data.azurerm_client_config.current.object_id]
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "terraform" {
  client_id = azuread_application.terraform.client_id
  owners    = [data.azurerm_client_config.current.object_id]
}

locals {
  // HCP Terraform issues a distinct token per run phase, so each workspace needs
  // two credentials. Entra caps federated identity credentials at 20 per
  // application, which is why var.hcp_workspaces is validated at 10 entries.
  federated_credentials = merge([
    for workspace in var.hcp_workspaces : {
      for phase in ["plan", "apply"] :
      "${workspace}-${phase}" => {
        workspace = workspace
        phase     = phase
      }
    }
  ]...)
}

resource "azuread_application_federated_identity_credential" "hcp" {
  for_each = local.federated_credentials

  application_id = azuread_application.terraform.id
  display_name   = "hcp-${each.key}"
  description    = "HCP Terraform ${each.value.phase} phase for workspace ${each.value.workspace}"

  audiences = ["api://AzureADTokenExchange"]
  issuer    = "https://app.terraform.io"
  subject   = "organization:${var.hcp_organization}:project:${var.hcp_project}:workspace:${each.value.workspace}:run_phase:${each.value.phase}"
}

// ── What the CI identity may do ────────────────────────────────────────────
//
// Scoped at mg-katta, not at Tenant Root Group, and not Owner.
//
// Owner is Contributor plus the ability to grant roles, bundled together with no
// way to separate them. Splitting it into Contributor and Role Based Access
// Control Administrator gives the same capability with the grant-roles half
// visible as its own assignment in the audit trail.

resource "azurerm_role_assignment" "terraform_contributor" {
  scope                = azurerm_management_group.root.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.terraform.object_id
}

resource "azurerm_role_assignment" "terraform_rbac_admin" {
  scope                = azurerm_management_group.root.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.terraform.object_id
}

// Creating and moving management groups is not a Contributor action — the
// Microsoft.Management/managementGroups/* operations live in their own role.
resource "azurerm_role_assignment" "terraform_mg_contributor" {
  scope                = azurerm_management_group.root.id
  role_definition_name = "Management Group Contributor"
  principal_id         = azuread_service_principal.terraform.object_id
}

// ═══════════════════════════════════════════════════════════════════════════
// Deny-all on mg-decommissioned
//
// This lives in bootstrap rather than in a week, because it is permanent
// platform governance: the parking bay is useless if the assignment on it can
// be torn down with the week that happened to create it.
//
// Until this existed, mg-decommissioned was an empty management group with no
// assignment — it would have accepted resources quite happily, while every
// diagram and README described it as deny-all. A node that is documented as a
// control and enforces nothing is worse than no node, because it is believed.
// ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_policy_definition" "deny_all" {
  name                = "deny-all-resources"
  display_name        = "Deny all resource creation"
  description         = <<-EOT
    Denies creation or update of every resource type. Assigned only to the
    decommissioned management group, where a cancelled subscription waits out
    its retention window before Azure removes it.
  EOT
  policy_type         = "Custom"
  management_group_id = azurerm_management_group.root.id

  // mode All, not Indexed. Indexed evaluates only resource types that support
  // tags and location, which would leave the parking bay accepting everything
  // else — including resource groups, the very first thing someone would create.
  mode = "All"

  metadata = jsonencode({
    category = "General"
    version  = "1.0.0"
  })

  policy_rule = jsonencode({
    if = {
      field = "type"
      like  = "*"
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })

  parameters = jsonencode({
    effect = {
      type = "String"
      metadata = {
        displayName = "Effect"
        description = "Deny to block, Audit to report only, Disabled to switch off."
      }
      allowedValues = ["Deny", "Audit", "Disabled"]
      defaultValue  = "Deny"
    }
  })
}

resource "azurerm_management_group_policy_assignment" "decommissioned_deny_all" {
  // 24 characters is the hard limit on a policy assignment name — "assign-deny-
  // all-decommissioned" is 30 and fails at plan time, not apply time.
  name                 = "assign-deny-all-decomm"
  display_name         = "Deny all — decommissioned"
  management_group_id  = azurerm_management_group.decommissioned.id
  policy_definition_id = azurerm_policy_definition.deny_all.id
  location             = var.location

  // Enforcing from the moment it exists. There is no report-only phase for this
  // one: the scope is empty by definition, so there is nothing to measure and
  // nothing that can break.
  enforce = true

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    effect = { value = "Deny" }
  })

  non_compliance_message {
    content = "This subscription is decommissioned and is waiting out its retention window. Nothing may be created in it. If you need these resources, move the subscription out of the decommissioned management group first."
  }
}
