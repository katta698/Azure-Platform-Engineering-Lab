locals {
  common_tags = {
    week       = "01"
    env        = "dev"
    managed-by = "terraform"
  }

  # Built-in definition IDs, confirmed against this tenant with
  # `az policy definition list --query "[?displayName=='...']"` rather than
  # copied from a blog post. Built-in GUIDs are stable, but the display names
  # they map to are not always what you remember.
  builtin = {
    allowed_locations = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
    require_tag       = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# The custom definition
#
# Defined at the intermediate root, not at a tenant or subscription scope. A
# definition's scope determines where it can be ASSIGNED from: anything at or
# below mg-katta can use this one, and nothing outside the lab can see it.
#
# This is the first thing that makes the management group tree do work rather
# than exist.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_policy_definition" "deny_public_ip_on_nic" {
  name                = "deny-public-ip-on-nic"
  display_name        = "Network interfaces must not have a public IP address"
  description         = <<-EOT
    Denies any network interface carrying a public IP configuration. Inbound
    access belongs to a load balancer, a gateway or Bastion — a public IP on the
    NIC itself puts the workload's own network stack on the internet, and it is
    the configuration that turns one compromised credential into a reachable
    host.
  EOT
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = var.root_management_group_id

  metadata = jsonencode({
    category = "Network"
    version  = "1.0.0"
  })

  # The alias is the part that has to be right. `ipConfigurations[*]` walks every
  # IP configuration on the NIC; `field(...)` with a [*] alias evaluates true if
  # ANY element matches, which is what "no public IP anywhere on this NIC" needs.
  # Testing only ipConfigurations[0] would pass a NIC whose second configuration
  # is public.
  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field  = "type"
          equals = "Microsoft.Network/networkInterfaces"
        },
        {
          field  = "Microsoft.Network/networkInterfaces/ipConfigurations[*].publicIpAddress.id"
          exists = "true"
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })

  # The effect is a parameter, not a constant. The same definition is assigned in
  # report-only mode first and enforcing mode second, and a definition that
  # hardcodes "Deny" cannot do that.
  parameters = jsonencode({
    effect = {
      type = "String"
      metadata = {
        displayName = "Effect"
        description = "Audit to report, Deny to block, Disabled to switch off."
      }
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })
}

# ═══════════════════════════════════════════════════════════════════════════
# The initiative
#
# Three definitions assigned as one unit. The reason to group them is not
# tidiness — it is that compliance is reported per assignment, so three separate
# assignments produce three separate compliance percentages and no answer to
# "is this management group compliant?".
# ═══════════════════════════════════════════════════════════════════════════

# azurerm_management_group_policy_set_definition, NOT azurerm_policy_set_definition.
# In azurerm 5.x the plain resource dropped its management_group_id argument and
# is subscription-scoped only; management group scope is a separate resource
# type. The definition above is the opposite case — azurerm_policy_definition
# still takes management_group_id directly. The two are not symmetrical, and
# assuming they are fails at validate with "argument not expected here".
resource "azurerm_management_group_policy_set_definition" "baseline" {
  name                = "initiative-lab-baseline"
  display_name        = "Lab baseline"
  description         = "The minimum every subscription in this lab must satisfy."
  policy_type         = "Custom"
  management_group_id = var.root_management_group_id

  metadata = jsonencode({
    category = "Lab"
    version  = "1.0.0"
  })

  # Parameters are surfaced at the initiative level so an assignment can set
  # them once. Without this, each policy_definition_reference would have to
  # hardcode its values and the initiative could not be reused across tiers.
  parameters = jsonencode({
    allowedLocations = {
      type = "Array"
      metadata = {
        displayName = "Allowed locations"
        description = "Regions resources may be created in."
        strongType  = "location"
      }
    }
    requiredTagName = {
      type     = "String"
      metadata = { displayName = "Required tag name" }
    }
    publicIpEffect = {
      type          = "String"
      metadata      = { displayName = "Effect for the public IP rule" }
      allowedValues = ["Audit", "Deny", "Disabled"]
    }
  })

  policy_definition_reference {
    policy_definition_id = local.builtin.allowed_locations
    reference_id         = "allowed-locations"
    parameter_values = jsonencode({
      listOfAllowedLocations = { value = "[parameters('allowedLocations')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = local.builtin.require_tag
    reference_id         = "require-tag"
    parameter_values = jsonencode({
      tagName = { value = "[parameters('requiredTagName')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.deny_public_ip_on_nic.id
    reference_id         = "deny-public-ip-on-nic"
    parameter_values = jsonencode({
      effect = { value = "[parameters('publicIpEffect')]" }
    })
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# Assignments
#
# Assigned at management group scope, never at the subscription. The assignment
# never names sub-lab-dev, and it will govern every subscription placed under
# mg-lz-dev in future without being touched again. That inheritance is the
# entire reason the tree exists.
#
# Note what this means for teardown: these assignments live OUTSIDE any resource
# group. Deleting the week's resource group leaves them in place, still
# governing. cleanup.sh has to remove them explicitly.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_management_group_policy_assignment" "lz_dev" {
  name                 = "assign-baseline-lz-dev"
  display_name         = "Lab baseline — dev landing zones"
  management_group_id  = var.lz_dev_management_group_id
  policy_definition_id = azurerm_management_group_policy_set_definition.baseline.id
  location             = var.location

  # `enforce`, not `enforcement_mode` — azurerm 5.x renamed it and inverted
  # nothing: true is Azure's "Default" mode, false is "DoNotEnforce".
  #
  # DoNotEnforce is the report-only mode. The assignment evaluates and reports
  # compliance but blocks nothing, which is how a guardrail gets introduced to a
  # populated environment without an outage. Stage 2 of this week flips it.
  enforce = var.enforce_policy

  # Needed by any assignment carrying a definition that could later gain a
  # deployIfNotExists or modify effect. Assigning one without an identity fails
  # at assignment time, not at evaluation time, which is a confusing place to
  # discover it.
  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    allowedLocations = { value = var.allowed_locations }
    requiredTagName  = { value = "managed-by" }
    publicIpEffect   = { value = var.enforce_policy ? "Deny" : "Audit" }
  })

  # ONE message per policy, keyed by policy_definition_reference_id.
  #
  # A non_compliance_message with no reference id applies to EVERY policy in the
  # initiative. Measured 2026-08-22: a storage account rejected for being in the
  # wrong region was told "network interfaces may not carry a public IP", because
  # a single generic message was attached to all three. The rejection was
  # correct and the explanation was nonsense, which is worse than no explanation
  # — it sends someone to debug the wrong thing.
  non_compliance_message {
    policy_definition_reference_id = "deny-public-ip-on-nic"
    content                        = "Denied by the lab baseline: a network interface may not carry a public IP. Front the workload with a load balancer, Application Gateway or Bastion."
  }

  non_compliance_message {
    policy_definition_reference_id = "allowed-locations"
    content                        = "Denied by the lab baseline: this region is not allowed. Deploy to southcentralus, or northcentralus for paired-region work."
  }

  non_compliance_message {
    policy_definition_reference_id = "require-tag"
    content                        = "Denied by the lab baseline: every resource needs a managed-by tag. Azure tags do not inherit from the resource group, so set it on the resource itself."
  }
}

resource "azurerm_management_group_policy_assignment" "platform" {
  name                 = "assign-baseline-platform"
  display_name         = "Lab baseline — platform"
  management_group_id  = var.platform_management_group_id
  policy_definition_id = azurerm_management_group_policy_set_definition.baseline.id
  location             = var.location

  # The platform tier is always enforcing. Its contents are permanent shared
  # services, so there is no "let us see what breaks first" phase to run.
  enforce = true

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    allowedLocations = { value = var.allowed_locations }
    requiredTagName  = { value = "managed-by" }
    publicIpEffect   = { value = "Deny" }
  })

  non_compliance_message {
    policy_definition_reference_id = "deny-public-ip-on-nic"
    content                        = "Denied by the lab baseline: platform resources may not carry a public IP on a network interface."
  }

  non_compliance_message {
    policy_definition_reference_id = "allowed-locations"
    content                        = "Denied by the lab baseline: this region is not allowed for platform resources."
  }

  non_compliance_message {
    policy_definition_reference_id = "require-tag"
    content                        = "Denied by the lab baseline: platform resources need a managed-by tag."
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# The test bed
#
# One resource group, holding the resources used to prove the policy works. Its
# deletion is the week's teardown for everything except the assignments above.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_resource_group" "week" {
  name     = "rg-wk01-landing-zone-dev-scus-001"
  location = var.location

  # Tags are set here explicitly because Azure tags do not inherit — a resource
  # group's tags are not applied to the resources inside it. Every resource in
  # this lab carries its own.
  tags = local.common_tags
}

resource "azurerm_virtual_network" "test" {
  name                = "vnet-wk01-dev-scus-001"
  resource_group_name = azurerm_resource_group.week.name
  location            = azurerm_resource_group.week.location
  address_space       = ["10.90.0.0/24"]

  tags = local.common_tags
}

resource "azurerm_subnet" "test" {
  name                 = "snet-test"
  resource_group_name  = azurerm_resource_group.week.name
  virtual_network_name = azurerm_virtual_network.test.name
  address_prefixes     = ["10.90.0.0/26"]
}
