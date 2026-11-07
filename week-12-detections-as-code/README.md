# Week 12 — Detections as code

Microsoft Sentinel analytics rules declared in Terraform, deployed onto a Log
Analytics workspace, and then **tested against a real event** — because a
detection that has never fired and a detection that cannot fire look exactly
the same from the outside.

## Cost note

**Measured: pending the invoice.** Deployed and validated 2026-11-07; the
figure will be read from Cost Management, not from a rate card.

**What runs continuously:** nothing. The whole week is destroyed by
`scripts/cleanup.sh`.

**What this week can be charged for**, enumerated *before* deployment by
`python scripts/price_check.py week-12-detections-as-code` and recorded in
[`meters.json`](meters.json) — 43 flat recurring meters across Sentinel, Log
Analytics and Azure Monitor, collapsing to 13 decisions, every one
acknowledged with the reason it does not apply here.

The design is built to sit at zero, and each leg of that is a documented fact
rather than a hope:

| | |
| --- | --- |
| the only data source is **Azure Activity** | Microsoft lists `AzureActivity` as a free data type in both Log Analytics ingestion and Sentinel analysis |
| enabling Sentinel grants a **31-day / 10 GB-per-day trial** | waives ingestion *and* analysis up to the limit |
| retention stays at **90 days** | Sentinel includes the first 90 days at no charge; `variables.tf` has a validation block that refuses a higher value |
| **no playbook** | Logic Apps automation is explicitly *not* waived by the trial, so incident handling uses an automation rule, which costs nothing |
| **no data lake tier** | data lake meters are also *not* waived; every table stays on the Analytics plan |

**The teardown trap, in Microsoft's words:** *"Removing Microsoft Sentinel
doesn't remove the Log Analytics workspace Microsoft Sentinel was deployed
on, or any separate charges that workspace might be incurring."* Offboarding
Sentinel is not cleanup. `cleanup.sh` destroys the workspace and then asks
Azure whether it is gone, rather than trusting the destroy's exit code.

One more constraint worth knowing before you redeploy: the free trial is **per
workspace, capped at 20 per tenant**. Destroying and recreating the workspace
burns trials that do not come back. Iterate on the rules, which are free to
replace; not on the workspace.

## What it builds

Seven resources. A resource group, a Log Analytics workspace, Sentinel enabled
on it, a subscription-scope diagnostic setting, two scheduled analytics rules
and one automation rule.

```
terraform/
  main.tf         workspace + Sentinel onboarding (two separate objects)
  activity.tf     the signal: a subscription diagnostic setting
  detections.tf   the matched pair of rules
  automation.tf   incident labelling, with no Logic App
```

## The point: a matched pair

The two rules exist to test each other.

| | |
| --- | --- |
| **Role assignment created** (Medium) | the **positive control**. Deliberately triggered during validation. |
| **Policy assignment deleted** (High) | the **negative control**. Deliberately *not* triggered. |

A rule that fires on a true positive might fire on anything. A rule silent on
a true negative might simply be broken. Only the pair is evidence, so
`validate.sh` fails if the negative control is noisy even when the positive
one passes.

## Validated 2026-11-07 — 8 passed / 0 failed

| Test | Result |
| --- | --- |
| Log Analytics workspace exists | `law-wk12-dev-scus-001` |
| Sentinel enabled on the workspace | onboardingState present |
| Both detections deployed and enabled | enabled, enabled |
| Activity log reached the workspace | 3 role-assignment rows |
| **POSITIVE control fired** | **1 incident** |
| **NEGATIVE control stayed silent** | **0 incidents** |
| Automation rule labelled the incident | `auto-triaged, privilege-escalation, week-12` |

**One incident from three matching rows** is the grouping configuration
working. Without it, a one-hour query period running every five minutes files
about twelve incidents for one event.

## Four things that cost time

**`Microsoft.OperationsManagement` is the provider nobody expects.** Sentinel
onboarding fails with `MissingSubscriptionRegistration` naming it, after
`Microsoft.SecurityInsights`, `Microsoft.OperationalInsights` and
`Microsoft.Insights` are all registered and after the workspace is already
built.

**The rules raced the onboarding.** Every Sentinel resource references the
*workspace* id, so nothing in the dependency graph said Sentinel must be
enabled first. Terraform created the rules in parallel and they failed with
`Workspace ... is not onboarded to Microsoft Sentinel`, which reads like the
onboarding resource failed. It had not — it was still in flight. A semantic
dependency with no value flowing across it has to be declared with
`depends_on`, or it is not a dependency.

**The legacy Azure Activity connector was retired on 30 September 2026.** The
current path is an ordinary subscription-scope diagnostic setting, not a
Sentinel data connector — so the `azurerm_sentinel_data_connector_*` resources
are the wrong answer now even though the provider still ships them.

**`az role assignment` fails with `MissingSubscription` on CLI 2.86.0** on this
machine, for `list` as well as `create`, while the same calls through
`az rest` against the ARM API work normally. The trigger goes through
`az rest`.

## Run it

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in; gitignored
terraform init && terraform apply

bash ../scripts/validate.sh     # the matched pair
bash ../scripts/cleanup.sh      # destroy, then verify against Azure
```

`terraform init` creates the HCP workspace in **remote** execution mode, which
has no Azure credentials and no `az`, and fails during *plan* with what looks
like a broken local toolchain. Fix it once:

```bash
python ../../scripts/hcp_workspace_local.py azure-week-12-dev
```

## What production adds

A baseline. A real tenant writes role assignments constantly through
automation, and this rule as written would page someone hourly — production
excludes known automation principals by object id and narrows scope to
privileged roles. That is a watchlist, and it is this week's natural sequel
rather than part of it.
