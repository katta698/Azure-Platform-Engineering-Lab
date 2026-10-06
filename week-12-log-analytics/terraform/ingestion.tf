# ═══════════════════════════════════════════════════════════════════════════
# The actual cost control: drop rows before they are billed
#
# A daily cap stops collection once the money is already spent. A transformation
# runs at ingest, so filtered rows are never charged for at all. This is the
# difference between a budget and a circuit breaker.
# ═══════════════════════════════════════════════════════════════════════════

# A DCE is required for any DCR that accepts data over the Logs Ingestion API.
# It is the endpoint the sender posts to.
resource "azurerm_monitor_data_collection_endpoint" "platform" {
  name                = "dce-platform-prod-scus-001"
  resource_group_name = azurerm_resource_group.observability.name
  location            = azurerm_resource_group.observability.location

  # Public for the lab. In a landing zone this is where a private endpoint goes,
  # resolving through the private DNS estate built in week 05 -
  # privatelink.monitor.azure.com already exists in the hub for exactly this.
  public_network_access_enabled = true

  tags = local.common_tags
}

resource "azurerm_monitor_data_collection_rule" "filtered" {
  name                        = "dcr-platform-filtered-prod-scus-001"
  resource_group_name         = azurerm_resource_group.observability.name
  location                    = azurerm_resource_group.observability.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.platform.id

  # Without this the DCR can be created before its destination tables exist,
  # and the API rejects the whole rule with a bare "InvalidPayload: Data
  # collection rule is invalid" that names no table.
  depends_on = [
    azapi_resource.alerts_table,
    azapi_resource.verbose_table,
  ]

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.platform.id
      name                  = "platform-workspace"
    }
  }

  data_flow {
    streams       = ["Custom-PlatformLogs_CL"]
    destinations  = ["platform-workspace"]
    output_stream = "Custom-PlatformLogs_CL"

    # THE WEEK IN ONE LINE.
    #
    # Everything below Warning is dropped at ingest. It is never written, never
    # stored and never billed - the daily cap never sees it, because as far as
    # the bill is concerned it did not arrive.
    #
    # Measured in validate.sh: rows sent vs rows stored.
    transform_kql = "source | where Level in ('Warning','Error','Critical') | project TimeGenerated, Level, Message, Component"
  }

  stream_declaration {
    stream_name = "Custom-PlatformLogs_CL"

    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "Level"
      type = "string"
    }
    column {
      name = "Message"
      type = "string"
    }
    column {
      name = "Component"
      type = "string"
    }
  }

  tags = local.common_tags
}

# ── The backstop's alarm ────────────────────────────────────────────────────
#
# A cap that trips silently is a data-loss incident nobody noticed. The alert
# is what makes the cap safe to rely on.
resource "azurerm_monitor_action_group" "observability" {
  name                = "ag-observability-prod-scus-001"
  resource_group_name = azurerm_resource_group.observability.name
  short_name          = "obsalert"

  email_receiver {
    name          = "platform-owner"
    email_address = var.alert_email
  }

  tags = local.common_tags
}

# ── Who may write into the rule ─────────────────────────────────────────────
#
# Posting to the Logs Ingestion API needs Monitoring Metrics Publisher ON THE
# DCR. Without it the endpoint answers 403 with "the authentication token
# provided does not have access to ingest data for the data collection rule" -
# clear once you read it, and nothing in the deploy hints that it is coming.
#
# Scoped to the rule, not the resource group and not the subscription. The role
# permits writing telemetry, and the blast radius of getting that wrong is
# someone forging logs - so it is granted exactly where it is used.
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "ingest" {
  scope                = azurerm_monitor_data_collection_rule.filtered.id
  role_definition_name = "Monitoring Metrics Publisher"

  # The identity running validate.sh. In a real pipeline this is the workload's
  # managed identity - week 07's, for instance - never a person.
  principal_id = data.azurerm_client_config.current.object_id
}
