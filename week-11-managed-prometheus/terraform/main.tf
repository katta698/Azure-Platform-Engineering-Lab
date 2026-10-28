# ─────────────────────────────────────────────────────────────────────────────
# Week 11 — the metrics destination, and the identity allowed to write to it.
#
# An Azure Monitor workspace is NOT a Log Analytics workspace. Week 08 built
# the second kind: logs, KQL, per-GB ingestion, table plans. This one stores
# Prometheus time series, is queried with PromQL, retains for 18 months at no
# storage cost, and is billed on ingestion and query rather than per GB.
# Confusing them is the most likely way to misread this week.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  tags = {
    week       = "11"
    env        = "dev"
    managed-by = "terraform"
  }
}

resource "azurerm_resource_group" "metrics" {
  name     = "rg-prometheus-lab-dev-scus-001"
  location = var.location
  tags     = local.tags
}

resource "azurerm_monitor_workspace" "metrics" {
  name                = "amw-wk11-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
  tags                = local.tags
}

# The workspace creates its own data collection rule and endpoint. They are
# what remote-write actually talks to, and neither is something this
# configuration declares - so they are read back rather than assumed.
#
# The DCR lives in a resource group Azure chooses, not this one, so its name
# and group are parsed out of the id rather than guessed.
locals {
  dcr_id_parts = split("/", azurerm_monitor_workspace.metrics.default_data_collection_rule_id)
  dcr_rg       = local.dcr_id_parts[4]
  dcr_name     = element(local.dcr_id_parts, length(local.dcr_id_parts) - 1)

  dce_id_parts = split("/", azurerm_monitor_workspace.metrics.default_data_collection_endpoint_id)
  dce_rg       = local.dce_id_parts[4]
  dce_name     = element(local.dce_id_parts, length(local.dce_id_parts) - 1)
}

data "azurerm_monitor_data_collection_rule" "metrics" {
  name                = local.dcr_name
  resource_group_name = local.dcr_rg
}

# The ENDPOINT comes from the data collection ENDPOINT, not the rule.
#
# Measured 2026-10-27, and it cost a rebuild: the DCR data source exposes a
# `metrics_ingestion_endpoint` attribute, and for a workspace-managed rule it
# is EMPTY. Terraform happily joined an empty host onto a path, rendered a
# config with a URL of "/dataCollectionRules/...", and Prometheus failed at
# runtime with `unsupported protocol scheme ""`. Nothing warned at plan or
# apply time, because an empty string is a valid string.
data "azurerm_monitor_data_collection_endpoint" "metrics" {
  name                = local.dce_name
  resource_group_name = local.dce_rg
}

# The remote-write URL is assembled, not pasted. Every part of it comes from
# the deployed resources, so a rebuild in another subscription produces a
# correct config file with no editing.
#
# The host is the DCE's metrics ingestion endpoint; the path names the DCR by
# its IMMUTABLE id, which is not the same as its resource name.
locals {
  remote_write_url = join("", [
    data.azurerm_monitor_data_collection_endpoint.metrics.metrics_ingestion_endpoint,
    "/dataCollectionRules/",
    data.azurerm_monitor_data_collection_rule.metrics.immutable_id,
    "/streams/Microsoft-PrometheusMetrics/api/v1/write?api-version=2023-04-24",
  ])
}

# A URL with no scheme is a configuration that applies cleanly and fails on
# the host hours later. Fail at plan time instead.
check "remote_write_url_is_absolute" {
  assert {
    condition     = startswith(local.remote_write_url, "https://")
    error_message = "The assembled remote_write URL has no scheme - the DCE's metrics_ingestion_endpoint came back empty."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# The identity Prometheus authenticates as.
#
# User-assigned rather than system-assigned for the same reason as week 09:
# it outlives the VM. Rebuild the host and the role assignment still points at
# something that exists.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "prometheus" {
  name                = "id-wk11-prometheus-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
  tags                = local.tags
}

# Monitoring Metrics Publisher ON THE DCR - not on the workspace, and not on
# the subscription. The DCR is the thing that accepts the write, so it is the
# narrowest scope that works. Week 08 granted the same role for the same
# reason on a different kind of rule.
#
# This assignment takes roughly THIRTY MINUTES to take effect. Until it does,
# remote-write returns HTTP 403 and the pipeline looks broken. See validate.sh.
resource "azurerm_role_assignment" "prometheus_publisher" {
  scope                = azurerm_monitor_workspace.metrics.default_data_collection_rule_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.prometheus.principal_id
}
