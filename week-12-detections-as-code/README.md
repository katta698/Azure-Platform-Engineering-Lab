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
| **POSITIVE control fired** | **1 incident** at first measurement, **2** after 18 minutes |
| **NEGATIVE control stayed silent** | **0 incidents** |
| Automation rule labelled both incidents | `auto-triaged, privilege-escalation, week-12` |

### What grouping actually did, measured rather than assumed

I wrote "one incident from three rows, grouping working" after the first
validation run. Eighteen minutes later there were two, and seven hours later
three — so that sentence was true when measured and wrong as a conclusion,
twice. The right number is not the incident count at all. It is the ratio:

| | |
| --- | --- |
| alerts raised by the rule | **13** |
| incidents created | **3** |
| largest single grouping | incident #2, **11 alerts** |

```
incident #1  Medium  New  alerts=1   Role assignment created
incident #2  Medium  New  alerts=11  Role assignment created
incident #3  Medium  New  alerts=1   Role assignment created
```

The rule runs every five minutes against a one-hour window, so it re-finds the
same Activity rows on every pass and raises an alert each time. Thirteen of
those collapsed into three incidents, one of which absorbed eleven on its own.
Without `grouping`, this would be thirteen separate incidents for what is, to
an analyst, one thing that happened.

**Counting incidents was the wrong measurement.** The count moves as the
window slides; the alerts-per-incident ratio is what the configuration
controls. Three measurements had to disagree before that was obvious.

## Five things that cost time

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

**The Azure portal retired the Sentinel Incidents page mid-session, and the
Overview tile lags its own API.** Both matter because both will happily
produce a screenshot that says the opposite of the truth:

* the Overview tile read `Incidents (0) — No incidents found` while the ARM
  API returned two incidents created twenty minutes earlier. It caught up
  later, reading 2 when the API said 3. It is an aggregate with its own
  refresh, not a view of the data.
* the Incidents page rendered a full grid at 22:51Z and, on three consecutive
  attempts twenty minutes later, served
  `This page has been moved to the Defender portal` instead.

So the evidence for this week is the API and the table, not the portal, and
`validate.sh` queries both directly. Sentinel loses Azure portal support after
**31 March 2027**; on this tenant, the incident views went first.

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
