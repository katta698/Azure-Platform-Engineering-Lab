output "stage" {
  description = "Which consumers are deployed."
  value       = var.enable_v2_consumer ? "V1 AND V2 — app_a on 1.0.0, app_b on 2.0.0" : "V1 ONLY — app_a on 1.0.0"
}

output "resource_group" {
  value = azurerm_resource_group.week.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.diagnostics.id
}

output "app_a" {
  description = "The consumer pinned to 1.0.0."
  value = {
    version        = "1.0.0"
    name           = module.app_a.name
    id             = module.app_a.id
    container_name = module.app_a.container_name
  }
}

output "app_b" {
  description = "The consumer on 2.0.0, or null in the first stage."
  value = var.enable_v2_consumer ? {
    version        = "2.0.0"
    name           = module.app_b[0].name
    id             = module.app_b[0].id
    container_name = module.app_b[0].container_name
  } : null
}
