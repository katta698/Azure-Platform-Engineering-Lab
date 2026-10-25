# Lab Guide — Week 08: Log Analytics

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-08-log-analytics/) explains what it does and why; this guide is the runbook. The [README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated 2026-10-05. This week is designed to stay up, so it has not been torn down.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| An Azure subscription (`sub-management` here) | `HIERARCHY.md` puts Log Analytics in the management subscription |
| **Contributor** on it | creates the workspace, the endpoint, the rule and the alert |
| **User Access Administrator** (or Owner) on it | the lab grants `Monitoring Metrics Publisher` on the data collection rule, and Contributor cannot create role assignments |
| A mailbox you can receive at | `alert_email` has no default: a daily cap that trips silently is data loss |
| HCP Terraform account, organization and project | remote state, **local execution** mode |

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | 5.x requires an explicit `subscription_id` on the provider block |
| `Azure/azapi` | **~> 2.0** | **not optional** — `azurerm_log_analytics_workspace_table` has nowhere to put a schema, so the two custom tables are created through ARM directly |
| Azure CLI | 2.60+ | provider registration, and the ingestion test in `validate.sh` |

### Resource providers

`deploy.sh` registers these on the subscription before applying:

```
Microsoft.OperationalInsights   Microsoft.Insights
```

### Prior weeks

**None.** This is the week every later one depends on, not the other way
round. Weeks 09 and 10 both send their telemetry to this workspace.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform.tfvars` is gitignored, which is also where `alert_email` stays.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | `sub-management` |
| `alert_email` | **yes** | — | where the daily-cap alert goes |
| `location` | no | `southcentralus` | region for the workspace and its endpoint |
| `daily_cap_gb` | no | `1` | the backstop, not the strategy — see below |

Point `versions.tf`'s `cloud {}` block at your own HCP organization, project
and workspace name.

---

## 3. Deploy

The HCP workspace is created **first, deliberately**, with its execution mode
set — not left for `terraform init` to create as a side effect:

```bash
# 1. the HCP workspace, with execution-mode local
#    (week 07 learned this the hard way - see below)

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# fill in tenant_id, subscription_id (sub-management), alert_email

./scripts/deploy.sh      # registers two providers, then applies
./scripts/validate.sh    # 5 checks; #4 sends 100 rows and counts survivors
./scripts/cleanup.sh     # refuses - this week stays up. --force to mean it
```

**9 resources** on a clean apply. What `validate.sh` prints when it passes:

```
1. The workspace exists, pay-as-you-go, with a cap
   RESULT: pay-as-you-go with a cap set
2. The table plans are what was asked for
   RESULT: both tables on their intended plans
3. The collection rule and its endpoint are live
   RESULT: endpoint and rule both resolved
4. The transformation drops rows BEFORE they are billed
   sending 100 rows, 20 of them Warning or above
   ingestion API returned HTTP 204
   rows stored: 20 of 100 sent
   RESULT: 20 stored, 80 dropped at ingest and never billed
5. The cap has an alarm that actually fires
   RESULT: a query rule is enabled AND wired to an action group

── 5 passed, 0 failed ──
```

**Check 4 is the one that matters, and it needs patience.** Posting to the
ingestion endpoint returns **403 until the role assignment propagates** —
measured at ten attempts over five minutes before the first 204. The script
retries; a single attempt would report a correct deployment as broken.

---

## 4. Validation

`scripts/validate.sh`, run 2026-10-05 against the live deployment:

```
1. The workspace exists, pay-as-you-go, with a cap
   sku=PerGB2018  daily cap=1.0GB  retention=30d
   RESULT: pay-as-you-go with a cap set

2. The table plans are what was asked for
   PlatformLogs_CL -> Analytics (wanted Analytics)
   PlatformVerbose_CL -> Basic (wanted Basic)
   RESULT: both tables on their intended plans

3. The collection rule and its endpoint are live
   RESULT: endpoint and rule both resolved

4. The transformation drops rows BEFORE they are billed
   sending 100 rows, 20 of them Warning or above
   ingestion API returned HTTP 204
   rows stored: 20 of 100 sent
   RESULT: 20 stored, 80 dropped at ingest and never billed

5. The cap has an alarm on it
   RESULT: an alert path exists

── 5 passed, 0 failed ──
```

Check 4 is the week. A transformation that filters nothing looks identical in
the portal to one that filters everything — the only way to know is to send
known data and count what survived.

---

## 5. Cleanup

```bash
./scripts/cleanup.sh --force
```

Refuses without the flag. The workspace is **soft-deleted for 14 days** and its
name stays reserved, so rebuilding inside that window fails on a name conflict
unless you recover rather than re-create:

```bash
az monitor log-analytics workspace recover -g rg-observability-prod-scus-001 \
  -n log-platform-prod-scus-001
```

### Verifying the teardown

This week's `cleanup.sh` does **not** count what is left afterwards, unlike the
later weeks. That is a real difference and not an oversight to paper over: the
script's whole purpose is to refuse, because the workspace is meant to stay up.
If you do force it, confirm by hand:

```bash
az monitor log-analytics workspace list --subscription "$SUB" \
  --query "length([?name=='log-platform-prod-scus-001'])" -o tsv   # expect 0
az monitor data-collection rule list --subscription "$SUB" \
  --query "length(@)" -o tsv                                       # expect 0
```

**What must be preserved while this week is up:** nothing from earlier weeks —
this is the base of the chain. **What breaks if you tear it down:** weeks 09
and 10 both write here, and their validation queries this workspace by name.

---

## 6. Troubleshooting

**A plan cannot be set on a table that does not exist.** Setting
`AzureDiagnostics` to Basic failed with `ResourceNotFound`. A new workspace has
no built-in tables — they materialise the first time data of that type arrives,
which is *after* the point you would want the cheap plan in place. Hence custom
tables, created with `azapi` because `azurerm_log_analytics_workspace_table`
takes a name and a plan and has nowhere to put a **schema**.

**The DCR failed with a bare `InvalidPayload`** naming nothing at all. Same root
cause: its destination tables did not exist yet. A `depends_on` fixed it.

**Ingestion returns 403 until RBAC propagates.** Measured: ten attempts over
**five minutes**, then 204. Nothing in the deploy hints that waiting is required.

**The Usage table updates hourly**, so billable volume cannot be verified
immediately after a test. The row counts are instant; the cost figures are not.

**An `az` extension prompt corrupted a check.** `az monitor log-analytics query`
lives in an extension; without it, az asks "Do you want to install it now?" and
in a non-interactive shell the *prompt text* lands in the variable. Week 05 lost
a teardown to the identical trap with `az network firewall list`.

---

## 7. Known limitations and what production adds

- **A 1 GB daily cap is a lab number.** It is a backstop against a runaway
  pipeline, not a capacity plan, and a cap that trips drops data for the rest
  of the day.
- **Two custom tables, not a real schema.** Production models tables per
  data source and revisits the plan per table as query patterns change.
- **The transformation is hand-written KQL.** It drops below Warning, which is
  right for this demonstration and far too blunt for a real estate — the point
  is that the lever exists and is applied at ingest.
- **Commitment tiers are out of reach.** The first one starts at 100 GB/day for
  a 20% discount; nothing this lab produces comes close, so pay-as-you-go is
  the correct choice here and would not be at scale.
- **Local execution.** State is in HCP but runs happen on a workstation.
  Production runs in CI under week 07's federated credential.
