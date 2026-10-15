output "app_fqdn" {
  value       = azurerm_container_app.hello.ingress[0].fqdn
  description = "Where validate.sh sends its requests. HTTPS only."
}

output "app_url" {
  value = "https://${azurerm_container_app.hello.ingress[0].fqdn}"
}

output "environment_id" {
  value       = azurerm_container_app_environment.workload.id
  description = "The scope the diagnostic setting is attached to."
}

output "app_name" {
  value = azurerm_container_app.hello.name
}

output "resource_group" {
  value = azurerm_resource_group.workload.name
}

output "identity_client_id" {
  value       = azurerm_user_assigned_identity.app.client_id
  description = "The identity a private registry pull or an Azure SDK call would use."
}

output "workspace_resource_id" {
  value       = data.azurerm_log_analytics_workspace.platform.id
  description = "Week 08's workspace, resolved across the subscription boundary rather than pasted in."
}

output "workspace_guid" {
  value       = data.azurerm_log_analytics_workspace.platform.workspace_id
  description = "Used by validate.sh to query for this week's log rows."
}
