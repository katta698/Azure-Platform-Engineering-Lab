# Cost guardrails — standing, not a week

Four `deny` policies assigned at **`mg-katta`**, two levels above `sub-lab-dev`.
They refuse expensive resources at the API, before anything is created.

```
mg-katta          <- assigned here
 └── mg-landingzones
      └── mg-lz-dev
           └── sub-lab-dev
```

Assigned above the subscription on purpose: nothing running inside the
subscription can remove them, and any future subscription inherits them.

## Why this exists

Every other cost control in this lab is discipline, and discipline has failed
twice:

- **Week 11** — a flat $6/user/month Grafana meter was read in the price API,
  judged uncertain, and dropped. It was 83% of that week's invoice, and Jay
  found it on his own bill.
- **Week 14 briefing** — a 3-year reservation total was misread as an hourly
  rate and written into a committed file as "$1,883/hour". Jay questioned the
  number; no check caught it.

Both failures were someone reading a number. These policies do not depend on
anyone reading anything.

## What they deny

| Policy | Refuses |
| --- | --- |
| `lab-deny-large-vms` | any VM size outside a 1–2 vCPU allow-list |
| `lab-deny-large-postgres` | any PostgreSQL Flexible Server SKU above 2 vCores |
| `lab-deny-expensive-types` | Managed HSM, Dedicated HSM, API Management, ExpressRoute, AVS, SQL Managed Instance |
| `lab-deny-commit-tiers` | any Log Analytics SKU that is not pay-as-you-go |

## Proved, not assumed

Tested 2026-11-22 after deployment:

```
az postgres flexible-server create --sku-name Standard_E64ds_v5 --tier MemoryOptimized
  -> RequestDisallowedByPolicy

az apim create --sku-name Developer
  -> RequestDisallowedByPolicy
```

Neither attempt created anything. A guardrail nobody has watched refuse
something is not a guardrail.

**And that test was not enough.** Hours later the PostgreSQL rule refused a
deliberately small server — week 14's 2-vCore `GP_Standard_D2ds_v5`, which the
allowlist was written to permit:

```
RequestDisallowedByPolicy ... 'Lab guardrail: only small PostgreSQL SKUs'
```

The allowlist held `GP_Standard_D2ds_v5`, the composite form Terraform and the
CLI accept. ARM stores `sku.name = Standard_D2ds_v5` with the tier in a separate
field, so the list matched nothing and the policy denied **every** PostgreSQL
server, small ones included. Corrected 2026-11-22 to ARM `sku.name` values.

The denial above is exactly what a correct policy produces, which is why one
test could not tell the two apart. **A deny needs a pair, like a detection
rule does: something it refuses and something it must let through.**

## What it does NOT protect against

- **Many cheap things.** Nothing here caps a total, only a unit price.
- **Leaving something running.** Teardown is still the only thing that stops a
  per-hour meter.
- **Usage meters.** Log Analytics ingestion bills per GB at any SKU; week 13
  bounded that with `daily_quota_gb` instead.

The budget `budget-lab_dev-monthly` ($100/month, alerts at 50% actual and 90%
forecast) covers the total — but budgets alert, they do not block.

## Run it

```bash
cd terraform/guardrails
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
```

Leave it up. It is the only thing in this repository that is not torn down.
