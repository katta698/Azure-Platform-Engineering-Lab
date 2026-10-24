# ═══════════════════════════════════════════════════════════════════════════
# Week 10 — where the traces go, and the security trade that gets them there
#
# Week 08 disabled local authentication on its workspace. Week 09 discovered
# that this made Container Apps' default logging path impossible, and routed
# logs through a diagnostic setting instead, which authenticates as ARM.
#
# This week hits the same wall from the other side, and loses.
#
# The managed OpenTelemetry agent sends to Application Insights using a
# CONNECTION STRING, and Microsoft's own documentation is explicit: the
# Application Insights resource "must allow local authentication to receive
# data from the OpenTelemetry data agent". There is no ARM-authenticated path
# for the agent. So local auth stays ON here, deliberately, and the post says
# so rather than pretending the lab is uniformly locked down.
# ═══════════════════════════════════════════════════════════════════════════

data "azurerm_log_analytics_workspace" "platform" {
  provider = azurerm.management

  name                = var.log_analytics_workspace_name
  resource_group_name = var.log_analytics_resource_group
}

# ── Application Insights ────────────────────────────────────────────────────
#
# Workspace-based, pointing at week 08's workspace in another subscription.
# Classic Application Insights had its own hidden store with its own retention
# and its own bill; workspace-based keeps every decision week 08 made - the
# table plans, the retention, the daily cap - applying to this data too.
resource "azurerm_application_insights" "tracing" {
  name                = "appi-wk10-dev-scus-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  application_type    = "web"
  workspace_id        = data.azurerm_log_analytics_workspace.platform.id

  # TRUE, and this is the week's uncomfortable line.
  #
  # Week 08 set exactly this argument to FALSE on the workspace, and that one
  # word is what forced week 09's entire logging design. Here it has to be
  # true: the managed agent authenticates with a connection string and
  # Microsoft documents no ARM-authenticated alternative.
  local_authentication_enabled = true

  # Sampling is handled in the SDK, where it can be reasoned about per service.
  # Leaving ingestion sampling on as well means two samplers multiplying each
  # other, and a trace count nobody can explain.
  sampling_percentage = 100

  tags = local.common_tags
}

# ── The Container Apps environment ──────────────────────────────────────────
resource "azurerm_container_app_environment" "workload" {
  name                = "cae-wk10-dev-scus-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  # Same reasoning as week 09: the shared-key path is unavailable because week
  # 08 disabled local auth on the workspace, so console logs go through a
  # diagnostic setting instead.
  logs_destination = "azure-monitor"

  tags = local.common_tags
}

# ── The managed OpenTelemetry agent ─────────────────────────────────────────
#
# azurerm has no argument for this, so it is set on the environment through
# ARM directly. The agent is Microsoft-provisioned inside the environment at
# 0.5 vCPU and 1.5 GB, and runs at NO extra compute cost - you pay only the
# destination's ingestion.
#
# It is a ROUTER, not an instrumenter. Microsoft's FAQ: "Do I need to
# reference the OpenTelemetry SDK in my code? Yes." Enabling this without an
# instrumented app produces exactly nothing, which is the trap worth naming.
#
# Traces and logs only - the agent cannot send METRICS to Application
# Insights. That is an agent limitation, not a configuration mistake.
resource "azapi_update_resource" "otel_agent" {
  type        = "Microsoft.App/managedEnvironments@2024-10-02-preview"
  resource_id = azurerm_container_app_environment.workload.id

  body = {
    properties = {
      appInsightsConfiguration = {
        connectionString = azurerm_application_insights.tracing.connection_string
      }
      openTelemetryConfiguration = {
        tracesConfiguration = {
          destinations = ["appInsights"]
        }
        logsConfiguration = {
          destinations = ["appInsights"]
        }
      }
    }
  }
}

# ── Console logs, as week 09 established ────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "environment" {
  name                       = "diag-to-platform-workspace"
  target_resource_id         = azurerm_container_app_environment.workload.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.platform.id

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }

  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}
