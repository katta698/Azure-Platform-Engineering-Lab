output "workspace_name" {
  value = azurerm_log_analytics_workspace.diag.name
}

output "workspace_customer_id" {
  value       = azurerm_log_analytics_workspace.diag.workspace_id
  description = "GUID form, which is what `az monitor log-analytics query` wants."
}

output "resource_group" {
  value = azurerm_resource_group.diag.name
}

output "assignment_id" {
  value       = azurerm_subscription_policy_assignment.diag.id
  description = "Remediation tasks are created per policy against this assignment."
}

output "category_group" {
  value = var.category_group
}
