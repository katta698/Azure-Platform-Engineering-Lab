output "frontend_url" {
  value       = "https://${azurerm_container_app.frontend.ingress[0].fqdn}"
  description = "The one public entry point. Calling it should produce a two-service trace."
}

output "registry_login_server" {
  value       = azurerm_container_registry.apps.login_server
  description = "Used by deploy.sh for az acr build."
}

output "registry_name" {
  value = azurerm_container_registry.apps.name
}

output "app_insights_name" {
  value = azurerm_application_insights.tracing.name
}

output "app_insights_id" {
  value       = azurerm_application_insights.tracing.id
  description = "Scope for the portal figures."
}

output "workspace_guid" {
  value       = data.azurerm_log_analytics_workspace.platform.workspace_id
  description = "Week 08's workspace, where the trace tables actually live."
}

output "resource_group" {
  value = azurerm_resource_group.workload.name
}

output "sampler_arg" {
  value       = var.trace_sampler_arg
  description = "What fraction of traces the SDK was told to keep."
}
