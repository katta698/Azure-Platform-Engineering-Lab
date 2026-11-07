output "workspace_id" {
  value       = azurerm_log_analytics_workspace.detections.id
  description = "The Log Analytics workspace Sentinel is enabled on. validate.sh queries it by this id."
}

output "workspace_name" {
  value       = azurerm_log_analytics_workspace.detections.name
  description = "Used by cleanup verification, which asserts the WORKSPACE is gone -- offboarding Sentinel does not remove it."
}

output "resource_group" {
  value       = azurerm_resource_group.detections.name
  description = "Everything this week creates, except the subscription diagnostic setting, which is scoped to the subscription and has no resource group."
}

output "customer_id" {
  value       = azurerm_log_analytics_workspace.detections.workspace_id
  description = "The workspace GUID, which is what `az monitor log-analytics query` wants rather than the ARM id."
}

output "detection_rule_names" {
  value = [
    azurerm_sentinel_alert_rule_scheduled.escalation.display_name,
    azurerm_sentinel_alert_rule_scheduled.tampering.display_name,
  ]
  description = "The matched pair: one to be triggered, one to stay silent."
}
