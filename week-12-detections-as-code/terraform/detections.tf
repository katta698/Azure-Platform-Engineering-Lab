# ─────────────────────────────────────────────────────────────────────────────
# The detections.
#
# A detection is code, so the question this week exists to answer is the one
# nobody asks of a SIEM rule: HOW DO YOU KNOW IT WORKS?
#
# "It deployed" is not an answer. A scheduled analytics rule with a typo in a
# column name, or a query period shorter than the ingestion delay, deploys
# perfectly and reports healthy forever. A rule that never fires is
# indistinguishable from an environment nobody is attacking, and both look
# like green.
#
# So the two rules below are a matched pair, and the pairing is the point:
#
#   escalation   deliberately TRIGGERED during validation. Proves the pipeline
#                carries a real event all the way to an incident.
#   tampering    deliberately NOT triggered. Proves the first rule fired
#                because of what it matched, not because everything fires.
#
# One without the other proves nothing. A rule that fires on a true positive
# might fire on anything; a rule silent on a true negative might be broken.
# Only the pair is evidence.
# ─────────────────────────────────────────────────────────────────────────────

# ── Detection A — the positive control ──────────────────────────────────────
#
# Someone granted someone else access. This is the first move after a
# credential is stolen and the last move before persistence, and at
# subscription scope it is rarely routine.
resource "azurerm_sentinel_alert_rule_scheduled" "escalation" {
  name                       = "wk12-role-assignment-created"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.detections.id
  # Terraform cannot infer this one, and the failure it causes is worth
  # understanding rather than just fixing.
  #
  # Every resource here references the WORKSPACE id, so the only dependency
  # in the data flow is on the workspace. Nothing in the configuration says
  # that Sentinel must be ENABLED on that workspace first -- that is a fact
  # about the service, not about the values. So Terraform did what the graph
  # permitted and created the rules in parallel with the onboarding:
  #
  #     Workspace 'law-wk12-dev-scus-001' is not onboarded to Microsoft
  #     Sentinel. Please onboard through the portal...
  #
  # which reads like the onboarding resource failed. It had not; it was still
  # in flight. A semantic dependency with no value flowing across it has to be
  # declared, or it is not a dependency at all.
  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.detections]

  display_name = "Role assignment created"
  severity     = "Medium"

  description = <<-EOT
    A role assignment was written successfully. Fires on the control-plane
    write itself, not on its effect, so it catches the grant whether or not
    the grantee ever uses it.

    Tuned for a lab, not for production: a real tenant writes role
    assignments constantly through automation, and shipping this as-is would
    page someone every hour. What production adds is a baseline -- known
    automation principals excluded by object id, and scope narrowed to
    privileged roles. That is a watchlist, and it is week 12's natural
    sequel rather than part of it.
  EOT

  query_frequency = var.query_frequency
  query_period    = var.query_period

  # Fire on the first match. The threshold is not where tuning belongs here:
  # one unexpected role assignment is the event.
  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  tactics = ["PrivilegeEscalation", "Persistence"]

  query = <<-KQL
    AzureActivity
    | where OperationNameValue =~ "MICROSOFT.AUTHORIZATION/ROLEASSIGNMENTS/WRITE"
    | where ActivityStatusValue =~ "Success"
    | project
        TimeGenerated,
        Caller,
        CallerIpAddress,
        OperationNameValue,
        ResourceGroup,
        _ResourceId
  KQL

  # Entities are what turn a row into something investigable. Without a
  # mapping an incident is a timestamp and a text blob; with one, the caller
  # and the address they came from become pivots that join to every other
  # incident touching the same account.
  entity_mapping {
    entity_type = "Account"
    field_mapping {
      identifier  = "FullName"
      column_name = "Caller"
    }
  }

  entity_mapping {
    entity_type = "IP"
    field_mapping {
      identifier  = "Address"
      column_name = "CallerIpAddress"
    }
  }

  incident {
    create_incident_enabled = true

    # Without this, a one-hour query period running every five minutes files
    # TWELVE incidents for one role assignment -- the same event seen by
    # twelve overlapping windows. Grouping is not tidiness; it is what makes
    # the wide period in variables.tf affordable.
    grouping {
      enabled                 = true
      lookback_duration       = "PT1H"
      reopen_closed_incidents = false
      entity_matching_method  = "AllEntities"
    }
  }
}

# ── Detection B — the negative control ──────────────────────────────────────
#
# Someone deleted a policy assignment. Week 02 built guardrails by policy
# assignment; deleting one is how you turn a guardrail off without touching
# the thing it guards, and it is quieter than violating it.
#
# NOT triggered during validation, on purpose. Its job is to be silent while
# Detection A fires.
resource "azurerm_sentinel_alert_rule_scheduled" "tampering" {
  name                       = "wk12-policy-assignment-deleted"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.detections.id
  # Same unexpressed dependency as the rule above.
  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.detections]

  display_name = "Policy assignment deleted"
  severity     = "High"

  description = <<-EOT
    A policy assignment was deleted successfully. Higher severity than the
    role assignment rule because removing a guardrail is almost never
    routine, and because week 02's remediation identities depend on
    assignments continuing to exist.

    This rule is the week's NEGATIVE CONTROL. During validation it must stay
    silent while a role assignment is deliberately created. A detection suite
    where every rule fires is not a detection suite.
  EOT

  query_frequency = var.query_frequency
  query_period    = var.query_period

  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  tactics = ["DefenseEvasion", "Impact"]

  query = <<-KQL
    AzureActivity
    | where OperationNameValue =~ "MICROSOFT.AUTHORIZATION/POLICYASSIGNMENTS/DELETE"
    | where ActivityStatusValue =~ "Success"
    | project
        TimeGenerated,
        Caller,
        CallerIpAddress,
        OperationNameValue,
        _ResourceId
  KQL

  entity_mapping {
    entity_type = "Account"
    field_mapping {
      identifier  = "FullName"
      column_name = "Caller"
    }
  }

  incident {
    create_incident_enabled = true

    grouping {
      enabled                 = true
      lookback_duration       = "PT1H"
      reopen_closed_incidents = false
      entity_matching_method  = "AllEntities"
    }
  }
}
