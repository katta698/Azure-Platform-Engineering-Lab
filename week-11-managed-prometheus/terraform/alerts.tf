# ─────────────────────────────────────────────────────────────────────────────
# Alerts as code.
#
# This is the half of the week that has nothing to do with Kubernetes, and the
# provider agrees: `cluster_name` is optional, and it is deliberately not set
# here. `scopes` takes the Azure Monitor workspace, so the rules evaluate
# against whatever wrote to it - in this week, a Prometheus on a VM.
#
# Both rule types are here on purpose. A recording rule precomputes and
# stores; an alert rule evaluates and fires. They are different things that
# people conflate, and one of each costs nothing extra to demonstrate.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_monitor_action_group" "metrics" {
  name                = "ag-wk11-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  short_name          = "wk11"
  tags                = local.tags

  # No receiver. The action group exists so the alert rule has somewhere to
  # point and so the wiring is visible, but this week does not claim to have
  # delivered a notification - it has not. Week 08 proved an alert that
  # actually fires to a mailbox; repeating that here would be a second copy
  # of someone else's week.
}

resource "azurerm_monitor_alert_prometheus_rule_group" "metrics" {
  name                = "prg-wk11-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
  description         = "Week 11 — one recording rule, one alert rule, no cluster"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.metrics.id]
  tags                = local.tags

  # A recording rule. Precomputes how long Prometheus takes to scrape itself
  # and stores it under a new name. Nothing alerts on this; it exists so the
  # difference between recording and alerting is visible in one resource.
  rule {
    enabled    = true
    record     = "instance:scrape_duration_seconds:mean5m"
    expression = "avg by (instance) (rate(scrape_duration_seconds_sum[5m]))"

    labels = {
      source = "self-managed-vm"
    }
  }

  # An alert rule, deliberately trivial to trip. The claim this week makes is
  # that a rule written in Terraform becomes a rule Azure evaluates against
  # remote-written data - not that the threshold is a sensible SLO.
  rule {
    alert      = "Wk11_Prometheus_Is_Reporting"
    enabled    = true
    expression = "up{job=\"prometheus\"} > ${var.alert_up_threshold}"
    for        = "PT1M"
    severity   = 4

    action {
      action_group_id = azurerm_monitor_action_group.metrics.id
    }

    alert_resolution {
      auto_resolved   = true
      time_to_resolve = "PT10M"
    }

    annotations = {
      summary = "Prometheus on the week 11 VM is reporting up, which is the point"
    }

    labels = {
      source = "self-managed-vm"
    }
  }
}
