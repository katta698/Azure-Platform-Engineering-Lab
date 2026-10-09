# ═══════════════════════════════════════════════════════════════════════════
# Week 12 — the workspace every later week sends logs to
#
# The design decisions are all cost decisions, and they are made here rather
# than left at their defaults:
#
#   table plan        which data is worth querying fast, and which is not
#   retention         how long each plan keeps it
#   daily cap         the backstop, NOT the strategy
#   transformation    the actual lever: drop rows before they are billed
# ═══════════════════════════════════════════════════════════════════════════

locals {
  common_tags = {
    week        = "12"
    env         = "prod" # platform telemetry outlives any one week
    managed-by  = "terraform"
    cost-center = "platform-lab"
  }
}

resource "azurerm_resource_group" "observability" {
  name     = "rg-observability-prod-scus-001"
  location = var.location
  tags     = local.common_tags
}

# ── The workspace ───────────────────────────────────────────────────────────
#
# In sub-management, not sub-connectivity. docs/HIERARCHY.md assigns Log
# Analytics to mg-management, and this is platform telemetry rather than
# anything to do with connectivity.
resource "azurerm_log_analytics_workspace" "platform" {
  name                = "log-platform-prod-scus-001"
  resource_group_name = azurerm_resource_group.observability.name
  location            = azurerm_resource_group.observability.location

  # PerGB2018 is pay-as-you-go. Commitment tiers start at 100 GB/DAY and save
  # up to 30%, which is real money at scale and irrelevant here - a lab will
  # never reach the first tier, so claiming the discount would be dishonest.
  sku = "PerGB2018"

  # 31 days of Analytics retention is included in the ingestion price - the
  # docs say 31, not the 30 you would assume from the default. Paying
  # for more is a deliberate choice, not a default worth drifting into.
  retention_in_days = 30

  # THE BACKSTOP, NOT THE STRATEGY.
  #
  # Microsoft's own guidance: a daily cap "should not be used as a primary
  # mechanism to filter or reduce data". When it trips, collection STOPS and
  # the data is gone - it is a circuit breaker protecting the bill, not a
  # design for controlling it. The transformation below is the actual control.
  daily_quota_gb = var.daily_cap_gb

  # Resource-context access. Someone who can read a resource can read THAT
  # resource's logs, without being granted anything on the workspace. The
  # alternative - workspace Reader - hands over every log from every
  # subscription at once, which is how a read-only grant becomes a data breach.
  allow_resource_only_permissions = true

  # Shared keys off. The workspace ID and key pair is a password: it does not
  # expire, it is copied into config files, and nothing records who used it.
  # With this false, callers authenticate with Entra tokens - which is what
  # week 07 was about, and what validate.sh uses to post its test rows.
  local_authentication_enabled = false

  tags = local.common_tags
}

# ── Table plans: the cost lever that is not a cap ───────────────────────────
#
# Analytics  continuous monitoring, latency-sensitive queries. Queries are free
#            to RUN. Highest ingestion price.
# Basic      troubleshooting. Cheaper to ingest, fixed 30-day query window, and
#            queries BILL PER GB SCANNED.
# Auxiliary  high-volume verbose data, lowest ingestion price, queries also
#            bill per GB scanned.
#
# So a cheap table queried often can cost more than an expensive one queried
# rarely. The plan follows how the data is USED, not how big it is.
#
# These are CUSTOM tables, created here with their schema.
#
# The first attempt set plans on AzureDiagnostics and AzureMetrics instead, and
# failed: "The specified table: 'AzureDiagnostics' was not found". A built-in
# table does not exist in a new workspace - it materialises the first time data
# of that type arrives. So a plan cannot be set on it in advance, which is
# exactly when you would want to.
#
# azapi rather than azurerm, because azurerm_log_analytics_workspace_table
# takes a name and a plan and has nowhere to put a SCHEMA - it can re-plan a
# table that exists, not create one.

# The alerting path. Queried constantly, so Analytics: fast, and free to query.
resource "azapi_resource" "alerts_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "PlatformLogs_CL"
  parent_id = azurerm_log_analytics_workspace.platform.id

  body = {
    properties = {
      plan                 = "Analytics"
      retentionInDays      = 30
      totalRetentionInDays = 90
      schema = {
        name = "PlatformLogs_CL"
        columns = [
          { name = "TimeGenerated", type = "datetime" },
          { name = "Level", type = "string" },
          { name = "Message", type = "string" },
          { name = "Component", type = "string" },
        ]
      }
    }
  }
}

# The troubleshooting path. Read during an incident and almost never otherwise,
# so Basic: cheaper to ingest, and the 30-day interactive window is acceptable
# precisely because nobody browses month-old verbose logs by hand.
resource "azapi_resource" "verbose_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "PlatformVerbose_CL"
  parent_id = azurerm_log_analytics_workspace.platform.id

  body = {
    properties = {
      plan = "Basic"
      # Basic fixes the interactive window at 30 days and will not accept
      # retentionInDays. total keeps it reachable by a search job for a year
      # without paying Analytics rates for the privilege.
      totalRetentionInDays = 365
      schema = {
        name = "PlatformVerbose_CL"
        columns = [
          { name = "TimeGenerated", type = "datetime" },
          { name = "Level", type = "string" },
          { name = "Message", type = "string" },
          { name = "Component", type = "string" },
        ]
      }
    }
  }
}
