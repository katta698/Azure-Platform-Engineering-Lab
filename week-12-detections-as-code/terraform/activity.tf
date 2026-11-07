# ─────────────────────────────────────────────────────────────────────────────
# The signal: Azure Activity, delivered by a subscription-scope diagnostic
# setting.
#
# THIS IS NOT THE WAY THE DOCUMENTATION USED TO SAY. Sentinel had a dedicated
# "Azure Activity" data connector, and the azurerm provider still ships
# resources of that family -- azurerm_sentinel_data_connector_azure_security_
# center and friends. The legacy Activity-log forwarding solution was RETIRED
# ON 30 SEPTEMBER 2026, five weeks before this was written, and replaced by
# exactly what is below: an ordinary diagnostic setting on the subscription,
# pointed at the workspace.
#
# The practical effect is better than the thing it replaced. There is no
# connector object to click, nothing that reports "Connected" or not, and no
# Sentinel-specific resource at all -- the signal arrives through the same
# Azure Monitor plumbing as every other diagnostic setting in this lab. A
# week-02 reader already knows how to read it.
#
# Two things to know before waiting on this:
#
#   * the Data connectors page can take 45-60 MINUTES to show "Connected".
#     That is the PAGE catching up, not the data. Rows land in AzureActivity
#     well before the tile agrees, so validate against the table, never
#     against the tile. Week 11 made the opposite mistake and trusted a
#     screenshot of a UI over a query.
#   * AzureActivity is a FREE data type -- excluded from both Log Analytics
#     ingestion and Sentinel analysis billing. It is the entire reason this
#     week can run a SIEM for nothing.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "activity" {
  name = "diag-activity-to-wk12"

  # The subscription itself. The Activity log is a subscription-level log, so
  # there is no resource id to point at other than the subscription's own.
  target_resource_id         = "/subscriptions/${var.subscription_id}"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.detections.id

  # Only the categories the detections actually read.
  #
  # Every category here is free, so this is not a cost decision -- it is a
  # signal-to-noise one. Sending all ten categories would bury the two
  # operations this week detects under autoscale and recommendation events,
  # and "collect everything in case" is how a workspace becomes unreadable.
  #
  # Administrative carries every control-plane write, which is where a role
  # assignment and a policy assignment deletion both appear.
  enabled_log {
    category = "Administrative"
  }

  # Policy carries policy evaluation effects. Not read by the detections
  # below, but it is the category a week-02 guardrail reports into, and
  # having it in the same workspace is what makes the next week's work
  # possible without redeploying this one.
  enabled_log {
    category = "Policy"
  }

  # Security carries Defender for Cloud signals. Empty on this subscription
  # today -- Defender is not enabled -- and included deliberately so that the
  # week's claim is testable: a detection reading an empty category must
  # report nothing rather than error.
  enabled_log {
    category = "Security"
  }
}
