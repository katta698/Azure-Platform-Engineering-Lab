# ═══════════════════════════════════════════════════════════════════════════
# Subscription vending
#
# The bootstrap created three subscriptions by hand, one at a time, watching
# each one. This turns that into a pipeline: a request goes in, and a landing
# zone comes out created, placed, budgeted and granted — with no portal step and
# nobody deciding case by case which management group it belongs in.
#
# The shape worth noticing is that vending is not one operation. It is four,
# against three different APIs, and only the first creates anything you would
# call a subscription:
#
#   1. create   the Subscription Alias API. Tenant-level, slow, irreversible
#   2. place    a separate call. The alias API puts everything under the Tenant
#               Root Group and does not move it
#   3. budget   Cost Management, on the new subscription
#   4. grant    RBAC, on the new subscription
#
# Steps 2 to 4 are the ones that make it a landing zone rather than an empty
# subscription, and all three are equally applicable to a subscription that
# already exists — which is what the second stage does.
# ═══════════════════════════════════════════════════════════════════════════

locals {
  # Assembled, not pasted. The three names are meaningless apart, and an
  # invoice section paired with the wrong billing profile is accepted at plan
  # and refused several minutes into an apply.
  billing_scope = join("/", [
    "/providers/Microsoft.Billing/billingAccounts", var.billing_account_name,
    "billingProfiles", var.billing_profile_name,
    "invoiceSections", var.invoice_section_name,
  ])

  common_tags = {
    week       = "04"
    env        = "dev"
    managed-by = "terraform"
  }

  # Every subscription this run vends a payload onto.
  #
  # The KEYS are static, so for_each resolves at plan time even though the
  # vended subscription's ID is not known until apply. That is the property
  # that lets one payload definition serve both stages: "what does a landing
  # zone get" has a single answer, and it cannot drift between the rehearsal
  # and the real thing.
  vend_targets = merge(
    {
      existing = var.existing_subscription_id
    },
    var.vend_new_subscription ? {
      vended = azurerm_subscription.vended[0].subscription_id
    } : {},
  )
}

# ── 1. Create ───────────────────────────────────────────────────────────────
#
# The alias API is the only way to create a subscription programmatically on an
# MCA, and it is slow: measured in the bootstrap at roughly ten minutes for one,
# with a second failing at the provider's default timeout with
# `StatusCode=0 -- context deadline exceeded`. StatusCode=0 means no HTTP
# response arrived, i.e. the client gave up rather than Azure refusing.
resource "azurerm_subscription" "vended" {
  count = var.vend_new_subscription ? 1 : 0

  alias             = var.landing_zone_name
  subscription_name = var.landing_zone_name
  billing_scope_id  = local.billing_scope
  workload          = var.subscription_workload

  tags = merge(local.common_tags, { vended = "true" })

  timeouts {
    create = "60m"
  }
}

# ── 2. Place ────────────────────────────────────────────────────────────────
#
# A separate resource, because it is a separate operation — not an attribute of
# the subscription. This is the step a vending pipeline forgets, and the failure
# is invisible: the subscription exists, is billed correctly and looks healthy,
# while inheriting no policy and no role assignments from the tree it was
# supposed to land in. Nothing goes wrong until something that should have been
# stopped is not.
resource "azurerm_management_group_subscription_association" "vended" {
  count = var.vend_new_subscription ? 1 : 0

  management_group_id = "/providers/Microsoft.Management/managementGroups/${var.target_management_group_id}"

  # The SUBSCRIPTION id, not the resource's own id. `azurerm_subscription.id`
  # is the alias resource ID — /providers/Microsoft.Subscription/aliases/<name>
  # — because the resource models the alias rather than the subscription, and
  # passing it here fails with "the segment at position 0 didn't match".
  subscription_id = "/subscriptions/${azurerm_subscription.vended[0].subscription_id}"
}

# ── 3. Budget ───────────────────────────────────────────────────────────────
#
# A budget alerts; it does not stop spend. That is worth being exact about,
# because "the landing zone has a budget" is heard as a cap by everyone who did
# not build it. What it buys is that somebody finds out.
resource "azurerm_consumption_budget_subscription" "vended" {
  for_each = local.vend_targets

  name            = "budget-${var.landing_zone_name}-${each.key}"
  subscription_id = "/subscriptions/${each.value}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  # Static, from variables. A window derived from `timestamp()` is re-evaluated
  # on every plan, so the budget reports drift forever against a resource
  # nobody touched — and a drift check that always fails is one nobody reads.
  time_period {
    start_date = var.budget_start_date
    end_date   = var.budget_end_date
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }

  # A forecast alert as well as an actual one. An 80% actual alert on a monthly
  # budget arrives when 80% is already spent; the forecast alert arrives while
  # the month can still be changed.
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_alert_emails
  }

  depends_on = [azurerm_management_group_subscription_association.vended]
}

# ── 4. Grant ────────────────────────────────────────────────────────────────
#
# Reader by default, and the default is the point. Vending decides what a
# landing zone owner holds on day one, for every landing zone, forever. The
# interesting failure is not "they could not deploy" — that is a request away —
# it is a pipeline that hands out Owner on every subscription it creates because
# Owner was the value in the example.
resource "azurerm_role_assignment" "landing_zone_owner" {
  for_each = local.vend_targets

  scope                = "/subscriptions/${each.value}"
  role_definition_name = var.role_assignment_definition
  principal_id         = var.role_assignment_principal_id

  depends_on = [azurerm_management_group_subscription_association.vended]
}
