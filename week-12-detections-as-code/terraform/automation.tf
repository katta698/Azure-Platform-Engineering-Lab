# ─────────────────────────────────────────────────────────────────────────────
# What happens to an incident the moment it is created.
#
# The obvious way to automate a Sentinel incident is a playbook, which is a
# Logic App. This week deliberately does not use one, and the reason is a
# billing fact rather than a design preference:
#
#     "Charges related to extra capabilities for automation and bring your
#      own machine learning are still applicable during the free trial."
#
# The 31-day Sentinel trial waives ingestion and analysis. It does NOT waive
# Logic Apps. A playbook here would be the only billed thing in a week whose
# cost note says zero -- which is precisely the shape of the week 11 mistake,
# where the one component nobody priced turned out to be 83% of the invoice.
#
# An automation rule needs no Logic App. It is evaluated by Sentinel itself,
# costs nothing, and can set severity, status, owner and labels. That covers
# the whole of what this week needs to demonstrate: that incident handling is
# declared in the repository alongside the detection that produces it.
#
# If a playbook is ever added here, Logic Apps must go into meters.json and
# price_check.py must be re-run. That is written down because "it is only a
# small Logic App" is exactly the reasoning that cost $6.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_sentinel_automation_rule" "tag_escalation" {
  # Sentinel names automation rules with a GUID rather than a slug, which
  # leaves three options and only one of them is good.
  #
  #   uuid()    regenerates on every plan, so the rule is destroyed and
  #             recreated each run and no plan can be trusted.
  #   a literal is stable, but it puts a bare GUID in a .tf file -- and
  #             secret-sweep.sh is right to refuse that. The sweep cannot
  #             tell an invented constant from a leaked tenant id, and a
  #             gate that has to be taught exceptions stops being a gate.
  #   uuidv5()  is a pure function of its inputs: same name in, same GUID
  #             out, forever, with no GUID written down anywhere.
  #
  # So the id is DERIVED from something human-readable. The source stays
  # greppable, the sweep stays strict, and the plan stays empty on re-run.
  name                       = uuidv5("dns", "wk12-triage-privilege-escalation")
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

  display_name = "Triage: label privilege-escalation incidents"

  # Evaluation order among automation rules. First and only one here.
  order = 1

  # Fire when an incident is CREATED. The alternative, on update, would
  # re-apply the labels every time an analyst touched the incident.
  triggers_on   = "Incidents"
  triggers_when = "Created"

  action_incident {
    order  = 1
    labels = ["week-12", "privilege-escalation", "auto-triaged"]

    # Deliberately NOT setting status or owner. An automation rule that
    # closes or assigns an incident is making a decision about an alert it
    # has not investigated, and a rule that auto-closes is how a real
    # detection gets silently discarded. Labelling is reversible and additive;
    # closing is neither.
  }
}
