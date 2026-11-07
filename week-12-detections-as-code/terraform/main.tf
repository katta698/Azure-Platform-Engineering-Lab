# ─────────────────────────────────────────────────────────────────────────────
# Week 12 — the workspace, and Sentinel switched on over the top of it.
#
# Sentinel is not a thing you deploy. It is a thing you ENABLE on a Log
# Analytics workspace that already exists, and the two are separate objects
# with separate lifecycles. That distinction is the week's first fact and it
# has a teardown consequence Microsoft states plainly:
#
#     "Removing Microsoft Sentinel doesn't remove the Log Analytics workspace
#      Microsoft Sentinel was deployed on, or any separate charges that
#      workspace might be incurring."
#
# So offboarding Sentinel is not cleanup. cleanup.sh destroys the workspace,
# and the teardown check asserts the WORKSPACE is gone rather than trusting
# that Sentinel was switched off.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  tags = {
    week       = "12"
    env        = "dev"
    managed-by = "terraform"
  }
}

resource "azurerm_resource_group" "detections" {
  name     = "rg-detections-lab-dev-scus-001"
  location = var.location
  tags     = local.tags
}

# The workspace. PerGB2018 is the pay-as-you-go SKU and it is named
# explicitly rather than left to default, because the alternative -- a
# commitment tier -- is the most expensive flat meter in this lab: the
# dearest Sentinel tier prices at $117,990 PER DAY. It cannot be reached by
# accident from here, and it is still written down. See meters.json.
resource "azurerm_log_analytics_workspace" "detections" {
  name                = "law-wk12-dev-scus-001"
  resource_group_name = azurerm_resource_group.detections.name
  location            = azurerm_resource_group.detections.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_days
  tags                = local.tags
}

# Enabling Sentinel. One resource, one argument, and it is what starts the
# 31-day / 10 GB-per-day free trial on this workspace.
#
# The trial is per workspace and capped at 20 workspaces per tenant, so
# destroying and recreating this workspace burns trials that do not come
# back. Deploy once. That is a real constraint on how this week is debugged:
# iterate on the RULES, which are free to replace, not on the workspace.
resource "azurerm_sentinel_log_analytics_workspace_onboarding" "detections" {
  workspace_id = azurerm_log_analytics_workspace.detections.id
}
