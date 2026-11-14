# Azure ships this initiative. Writing per-resource-type policy definitions by
# hand would reinvent 139 of them.
#
# Looked up by display name rather than by GUID: a bare GUID in a .tf file is
# indistinguishable from a leaked identifier to secret-sweep.sh, and the name
# says what it is.
data "azurerm_policy_set_definition" "diag_to_law" {
  display_name = "Enable ${var.category_group} category group resource logging for supported resources to Log Analytics"
}

resource "azurerm_subscription_policy_assignment" "diag" {
  name                 = "wk13-diag-to-law"
  display_name         = "Week 13 — resource logs to Log Analytics (${var.category_group})"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = data.azurerm_policy_set_definition.diag_to_law.id
  location             = var.location

  # deployIfNotExists needs an identity to deploy AS.
  identity {
    type = "SystemAssigned"
  }

  # categoryGroup is NOT a parameter here. The documented "common parameters"
  # table lists it, but that applies to the individual policies; these
  # initiatives accept only effect, diagnosticSettingName, resourceLocationList,
  # logAnalytics and resourceTypeList. The category group is chosen by WHICH
  # initiative is assigned, which is what var.category_group selects above.
  parameters = jsonencode({
    logAnalytics = { value = azurerm_log_analytics_workspace.diag.id }
  })
}

# Log Analytics Contributor is the role named in the policies'
# roleDefinitionIds. Scoped to the subscription because that is the assignment
# scope; a narrower grant cannot remediate resources outside it.
resource "azurerm_role_assignment" "remediation" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_subscription_policy_assignment.diag.identity[0].principal_id
}
