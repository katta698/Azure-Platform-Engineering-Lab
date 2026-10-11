output "workspace_id" {
  value       = azurerm_log_analytics_workspace.platform.workspace_id
  description = "The workspace GUID, used by every later week's diagnostic settings."
}

output "workspace_resource_id" {
  value = azurerm_log_analytics_workspace.platform.id
}

output "dce_endpoint" {
  value       = azurerm_monitor_data_collection_endpoint.platform.logs_ingestion_endpoint
  description = "Where validate.sh posts its test rows."
}

output "dcr_immutable_id" {
  value       = azurerm_monitor_data_collection_rule.filtered.immutable_id
  description = "Identifies the rule to the Logs Ingestion API."
}
