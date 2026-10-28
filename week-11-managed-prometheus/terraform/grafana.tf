# ─────────────────────────────────────────────────────────────────────────────
# Grafana — the half of this week that draws the data.
#
# SKU: Standard is the only value azurerm accepts. Azure also sells an
# Essential tier with no hourly node charge, which would be cheaper, but it is
# Preview and the provider cannot express it - reaching it would mean dropping
# to azapi for a preview SKU. Standard is GA, and a new instance is free for
# its first 30 days, one per subscription.
#
# Cost if the trial does not apply: $0.0411 per node-hour, two nodes minimum,
# so about $0.082/hour. Measured from the retail price API for southcentralus,
# not quoted from a pricing page.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_dashboard_grafana" "metrics" {
  name                  = "amg-wk11-dev-scus-001"
  resource_group_name   = azurerm_resource_group.metrics.name
  location              = azurerm_resource_group.metrics.location
  sku                   = var.grafana_sku
  grafana_major_version = 13
  tags                  = local.tags

  # System-assigned: this identity has no reason to outlive the instance, and
  # the grant below is the only thing it is ever used for. Week 09's reasoning
  # for user-assigned does not apply here.
  identity {
    type = "SystemAssigned"
  }

  # Wires the workspace in as a data source. Without this the instance comes
  # up empty and someone has to point it at the workspace by hand, which is
  # the opposite of dashboards as code.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.metrics.id
  }
}

# Integration declares the link; it does not grant the read. Grafana's own
# identity needs Monitoring Data Reader ON THE WORKSPACE or every panel
# renders an authorization error against a data source that looks correctly
# configured.
resource "azurerm_role_assignment" "grafana_reader" {
  scope                = azurerm_monitor_workspace.metrics.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.metrics.identity[0].principal_id
}


# A HUMAN CANNOT OPEN GRAFANA WITHOUT A GRAFANA ROLE.
#
# Measured 2026-10-28: with the instance deployed and its own identity able to
# read the workspace, `az role assignment list` on the instance returned
# NOTHING, and opening the endpoint bounced to Entra and would have refused
# after sign-in. Deploying Managed Grafana does not grant its deployer access
# to it - the Azure RBAC that creates the resource and the Grafana RBAC that
# lets you log in are separate systems.
#
# Grafana Admin rather than Viewer because this identity is the one that
# builds the dashboards; a reader who only needs to look wants Grafana Viewer.
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "grafana_admin" {
  scope                = azurerm_dashboard_grafana.metrics.id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
