output "resource_group" {
  value       = azurerm_resource_group.metrics.name
  description = "What dies together at teardown."
}

output "monitor_workspace_id" {
  value       = azurerm_monitor_workspace.metrics.id
  description = "The Azure Monitor workspace. Not a Log Analytics workspace."
}

output "query_endpoint" {
  value       = azurerm_monitor_workspace.metrics.query_endpoint
  description = "Where PromQL queries go. Used by validate.sh."
}

output "remote_write_url" {
  value       = local.remote_write_url
  description = <<-EOT
    The URL Prometheus writes to, assembled from the workspace's own data
    collection rule. Not a secret - writing to it still requires a token from
    an identity holding Monitoring Metrics Publisher - but it is the exact
    string rendered into the VM's config, so it is here for debugging.
  EOT
}

output "dcr_id" {
  value       = azurerm_monitor_workspace.metrics.default_data_collection_rule_id
  description = "The scope of the Monitoring Metrics Publisher grant."
}

output "identity_client_id" {
  value       = azurerm_user_assigned_identity.prometheus.client_id
  description = "What prometheus.yml names. A client id is an identifier, not a credential."
}

output "vm_name" {
  value       = azurerm_linux_virtual_machine.prometheus.name
  description = "Used by validate.sh with `az vm run-command` - no SSH, no open port."
}

output "grafana_endpoint" {
  value       = azurerm_dashboard_grafana.metrics.endpoint
  description = "The Grafana instance. Figure 06 is captured here."
}

output "rule_group_name" {
  value       = azurerm_monitor_alert_prometheus_rule_group.metrics.name
  description = "Alerts as code. Figure 05 shows this in the portal."
}
