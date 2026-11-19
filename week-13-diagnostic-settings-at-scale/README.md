# Week 13 — Diagnostic settings at scale

One built-in Azure Policy initiative, assigned at subscription scope, turning
resource logging on automatically. Four target resources, **three different
outcomes** — and only one of them is "it worked".

## Cost note

**Measured: $0.0053.** Read from Cost Management (ActualCost, 14 November
2026): $0.0053 for the public IP, $0.00 for the key vault and storage, and
**no Log Analytics line at all**. The meter this week was built around —
Analytics ingestion at $2.76/GB — billed nothing.

The prediction written into [`meters.json`](meters.json) *before* deploying was
under 0.05 GB/day against a 0.5 GB cap. It held.

**What runs continuously:** nothing. `scripts/cleanup.sh` destroys the week.

**This week's risk is a USAGE meter, and the gate does not cover it.**
`scripts/price_check.py` enumerates flat recurring meters — the ones that bill
while a thing merely exists. It found 30, all acknowledged in
[`meters.json`](meters.json). But the meter that actually applies here is
**Analytics Logs Data Ingestion at $2.76/GB**, because the entire point of the
week is turning logging *on*. Week 12 ingested one free data type and landed at
$0.00; this week has nothing to hide behind.

So the bound is in the code rather than in good intentions:

| | |
| --- | --- |
| `daily_quota_gb = 0.5` on the workspace | ingestion **stops** at the cap rather than billing past it |
| `category_group = "audit"` | the smaller of the two initiatives — 69 policies, not 139 |
| blast radius enumerated *before* assigning | 1 virtual network, 1 route table, 1 network watcher; only the VNet is covered by any built-in policy, and not under `audit` |
| a **predicted** volume written into `meters.json` before deploying | under 0.05 GB/day, so the measurement can contradict it |

One Key Vault meter was worth chasing. The price API shows **$4.85/hour** and
**$3.20/hour** under the Key Vault service, which would be $3,500/month. Both
belong to *Azure Dedicated HSM* and *Key Vault HSM Pool* — different products.
A standard vault bills per 10,000 operations. Checked, not assumed.

## What it builds

Nine resources. A workspace with a daily cap, four deliberately chosen targets,
and the initiative assigned at subscription scope with a system-assigned
identity.

```
terraform/
  main.tf      resource group + capped workspace
  targets.tf   four resources chosen to produce three outcomes
  policy.tf    the built-in initiative, looked up by display name
```

**Two of the nine live outside the resource group.** The policy assignment and
its role assignment are at subscription scope, so deleting the resource group
would leave both behind — still trying to remediate into a workspace that no
longer exists. `cleanup.sh` asserts all three separately.

## The point: one initiative, three outcomes

| Resource | Outcome | Why |
| --- | --- | --- |
| **Key Vault** | remediated | `audit` covers it |
| **Public IP** | remediated | `audit` covers it |
| **Log Analytics workspace** | remediated | covered, and now logs itself |
| **Network security group** | **untouched** | supports `allLogs`, not `audit` |
| **Storage account** | **untouched** | **no built-in policy for the type at any category group** |

The last two matter more than the first three. Both look like failures on a
compliance dashboard and neither is: one needs a different category group, the
other has nothing to be compliant *with*. A write-up showing only the Key Vault
would be true and useless.

Azure produced this split itself — policy evaluation returned exactly three
findings, and the NSG and storage account never appeared.

## Remediation is per POLICY, not per initiative

Assigning the initiative changes nothing for resources that already exist.
`deployIfNotExists` applies to resources created *after* the assignment; for
everything already there, a remediation task is required — **one per policy**,
named by its `policyDefinitionReferenceId`:

```
rem-keyvault-vaults                  Succeeded   1 deployment
rem-network-publicipaddresses        Succeeded   1 deployment
rem-operationalinsights-workspaces   Succeeded   1 deployment
```

The `audit` initiative holds **69 policies**; `allLogs` holds **139**. In a lab
with four resources that is three tasks. In an estate it is the operational
cost of the pattern, and it is the part that gets skipped.

## Validated 2026-11-14 — 7 passed / 0 failed

| Test | Result |
| --- | --- |
| Workspace exists | `law-wk13-dev-scus-001` |
| Daily ingestion cap set | **0.5 GB/day** |
| Diagnostic setting on key vault | 1 setting |
| Diagnostic setting on public IP | 1 setting |
| No setting on NSG under `audit` | 0, **by design** |
| No setting on storage | 0, **by design** |
| **Logs actually arrived in the workspace** | **14 Key Vault audit rows** |

Only the last row proves anything. Everything above it proves *configuration* —
a diagnostic setting object exists. The last one asks the workspace whether a
log was ever written, which is a different question, and the one week 12 learned
to ask after the Sentinel portal disagreed with its own API twice in an
afternoon.

```
2026-11-14T13:35:54Z   SecretGet        OK
2026-11-14T13:35:50Z   SecretSet        OK
2026-11-14T13:34:53Z   Authentication   Unauthorized
```

## Four things that cost time

**The documented `categoryGroup` parameter does not exist on these
initiatives.** The apply failed with `UndefinedPolicyParameter`. Microsoft's
"common parameters" table lists `categoryGroup`, but that applies to the
individual *policies*; the initiatives accept only `effect`,
`diagnosticSettingName`, `resourceLocationList`, `logAnalytics` and
`resourceTypeList`. The category group is chosen by **which initiative you
assign**, not by a parameter.

**A diagnostic setting only collects what happens after it is active.** The
first validation run wrote its probe secret in the same minute the setting was
being created, and the event was never captured — the workspace stayed empty
and it looked like the pipeline was broken. It was not. Operations issued once
the setting was live appeared within about four minutes.

**Compliance lags reality.** The public IP read `NonCompliant` for several
minutes after its diagnostic setting demonstrably existed. `validate.sh` asks
each resource directly rather than reading the compliance dashboard, for the
same reason the log check exists.

**`az monitor diagnostic-settings list --resource` fails with a usage error on
CLI 2.86.0** given a valid resource ID, while the ARM API answers normally —
the same class of CLI breakage as `az role assignment` in week 12. The
validation goes through `az rest`.

## Run it

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in; gitignored
terraform init && terraform apply

# remediation is per policy — one task per policyDefinitionReferenceId
az policy remediation create -g rg-diagnostics-lab-dev-scus-001 \
  --policy-assignment wk13-diag-to-law --name rem-keyvault-vaults \
  --definition-reference-id keyvault-vaults --resource-discovery-mode ReEvaluateCompliance

bash ../scripts/validate.sh
bash ../scripts/cleanup.sh
```

`terraform init` creates the HCP workspace in **remote** execution mode, which
has no Azure credentials. Fix it once:

```bash
python ../../scripts/hcp_workspace_local.py azure-week-13-dev
```

## What production adds

A category group chosen per resource type rather than one for the estate.
`allLogs` on a chatty resource is the single fastest way to a surprise Log
Analytics bill, and `audit` leaves whole resource types uncovered. The real
answer is `resourceTypeList` — the initiative parameter this lab left at its
default — scoping each assignment to the types whose logs someone has agreed to
pay for.
