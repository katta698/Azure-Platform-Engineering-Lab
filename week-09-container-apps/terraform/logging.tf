# ═══════════════════════════════════════════════════════════════════════════
# Week 09 — where the logs go
#
# Week 08 built one workspace for the whole lab and said every later week
# would send its data there. This is the first week that does it, and it is
# the test of whether that was a real design or just a sentence.
#
# It crosses a subscription boundary (sub-lab-dev to sub-management), which is
# the normal shape in any organisation that separates applications from
# platform telemetry, and is the reason the workspace is read through an
# aliased provider rather than named in a string.
# ═══════════════════════════════════════════════════════════════════════════

data "azurerm_log_analytics_workspace" "platform" {
  provider = azurerm.management

  name                = var.log_analytics_workspace_name
  resource_group_name = var.log_analytics_resource_group
}

# The diagnostic setting lives at the ENVIRONMENT's scope, in sub-lab-dev, and
# merely names a workspace that happens to be elsewhere. So it is created by
# the default provider; only the lookup above needs the other subscription.
resource "azurerm_monitor_diagnostic_setting" "environment" {
  name                       = "diag-to-platform-workspace"
  target_resource_id         = azurerm_container_app_environment.workload.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.platform.id

  # NO log_analytics_destination_type HERE, and that is deliberate.
  #
  # The obvious thing to write is `log_analytics_destination_type =
  # "Dedicated"`, because resource-specific tables are what week 08's per-table
  # cost design needs. It was written that way first, and it produced a
  # configuration that never converges: ARM does not persist the field for a
  # Container Apps managed environment, so it comes back null, and every
  # subsequent plan reads
  #
  #     ~ azurerm_monitor_diagnostic_setting.environment
  #       + log_analytics_destination_type = "Dedicated"
  #
  # forever. A plan that is never empty is worse than useless - it trains
  # whoever reads it to ignore the diff that matters.
  #
  # Omitting it loses nothing, because these logs are resource-specific
  # whatever you ask for. Measured against the live workspace after the rows
  # arrived:
  #
  #     ContainerAppConsoleLogs | summarize count()   ->  2
  #     AzureDiagnostics        | summarize count()   ->  0
  #
  # and the columns come back as ContainerAppName, not ContainerAppName_s.
  # The _s suffix is the signature of the shared AzureDiagnostics table; its
  # absence is the proof that these are dedicated tables.

  # Named categories, not the allLogs category group.
  #
  # allLogs is defined by Azure and grows when Azure adds a category, so a
  # setting written once silently starts billing for data nobody asked for.
  # These two are what a Container Apps environment emits today:
  #
  #   ContainerAppConsoleLogs   what the container wrote to stdout/stderr
  #   ContainerAppSystemLogs    what the platform did TO the container -
  #                             including the scale events this week is about
  enabled_log {
    category = "ContainerAppConsoleLogs"
  }

  enabled_log {
    category = "ContainerAppSystemLogs"
  }

  # Metrics are deliberately NOT enabled here.
  #
  # Replica count and request count are platform metrics, already retained for
  # 93 days at no charge and queryable in the metrics explorer. Routing
  # AllMetrics into the workspace copies them into billable log rows to answer
  # questions the free path already answers.
}
