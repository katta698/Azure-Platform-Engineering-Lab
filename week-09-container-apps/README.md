# Week 09 — Container Apps: a workload that costs nothing until someone asks

**Lab guide.** This is the reproducible half: exact prerequisites, variables,
commands, expected outputs, validation and cleanup. The concepts, architecture
and results are written up at
[jayanthkatta.com/blog/week-09-container-apps](https://jayanthkatta.com/blog/week-09-container-apps/).

**Goal:** deploy a workload that serves real HTTP traffic from the internet,
runs **no replicas at all** when nobody is using it, and reports to week 08's
Log Analytics workspace across a subscription boundary.

Weeks 01 to 08 built the place things run and the place they report to. Nothing
was actually running in any of them. This is the first week with a workload in
it, and the design question is not how to make it fast — it is what you are
willing to pay while nobody is using it.

---

## 1. Cost note

| | |
| --- | --- |
| Runs continuously | nothing. The app sits at **0 replicas** when idle |
| Billed while idle | **$0.00** — "when a revision is scaled to zero replicas, no resource consumption charges are incurred" |
| Billed while serving | 0.25 vCPU-s and 0.5 GiB-s per second of running replica, plus requests |
| Free each month, per subscription | 180,000 vCPU-seconds, 360,000 GiB-seconds, 2 million requests |
| Fixed environment fee | **none** — a plan management charge applies only if you use a *Dedicated* workload profile |
| Measured for this week | **$0.00** — read from Cost Management after teardown |
| Teardown | `./scripts/cleanup.sh` removes everything in `sub-lab-dev`. Week 08's workspace is read, never owned, so it survives |

**Measured: $0.00.** Read from Cost Management on 2026-10-15, after teardown —
`sub-lab-dev` shows no charges at all for the days this ran. The app used
roughly **600 vCPU-seconds** and **1,200 GiB-seconds** against monthly free
grants of 180,000 and 360,000, on a handful of requests against a 2-million
allowance. The free grant absorbed the entire week.

Rates measured from the Azure retail price API for `southcentralus`, not quoted
from a marketing page:

| Meter | Rate |
| --- | --- |
| vCPU, active | $0.000024 per vCPU-second |
| vCPU, idle | $0.000003 per vCPU-second |
| Memory, active and idle | $0.000003 per GiB-second |
| Requests | $0.40 per million |

The idle rate is eight times cheaper than active — and it is **unreachable from
a floor of zero**, because at zero there is no replica to bill at either rate.
It only applies to a replica that exists and is doing nothing.

---

## 2. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| Azure subscription for the workload (`sub-lab-dev` here) | holds the resource group, environment and app |
| A subscription holding a Log Analytics workspace (`sub-management` here) | the diagnostic setting writes there; one subscription works too — point both variables at it |
| **Contributor** on the workload subscription | creates everything in the resource group |
| **Reader** on the resource group holding the workspace | the workspace is read through a data source, never modified |
| HCP Terraform account, organization and project | remote state; the workspace runs in **local execution** mode |

**Contributor is enough.** This week declares no `azurerm_role_assignment`, so
it does not need User Access Administrator. Week 10 does — worth knowing before
you grant more than the lab needs.

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf`; **1.16.6** is what actually ran here |
| `hashicorp/azurerm` | **~> 5.2** | 5.x requires an explicit `subscription_id` on every provider block |
| Azure CLI | 2.60+ | provider registration and the validation queries |
| Docker | **not required** | the image is pulled from `mcr.microsoft.com`, never built |

### Existing infrastructure

- **Week 08's Log Analytics workspace.** Defaults point at
  `log-platform-prod-scus-001` in `rg-observability-prod-scus-001`. Override
  `log_analytics_workspace_name` and `log_analytics_resource_group` to use your
  own. This week does **not** create a workspace.
- Week 08 does not need to still be deployed, only to exist.

### Resource providers

`deploy.sh` registers these on the workload subscription and then **waits for
`Microsoft.App` to reach `Registered`** before applying:

```
Microsoft.App   Microsoft.Insights   Microsoft.ManagedIdentity
Microsoft.OperationalInsights
```

Registration is deliberately in `deploy.sh` and not in Terraform: it is
subscription-wide shared state, and one week's destroy must not unregister a
provider another week still needs. `Microsoft.App` was `NotRegistered` on
`sub-lab-dev` before this week.

### Region and quota

`location` defaults to **`southcentralus`**. No quota increase is needed: the
app runs on the Consumption profile inside the monthly free grant.

---

## 3. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform.tfvars` is gitignored.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | the workload subscription |
| `management_subscription_id` | **yes** | — | the subscription holding the Log Analytics workspace |
| `location` | no | `southcentralus` | region for everything this week creates |
| `log_analytics_resource_group` | no | `rg-observability-prod-scus-001` | week 08's resource group |
| `log_analytics_workspace_name` | no | `log-platform-prod-scus-001` | week 08's workspace |
| `container_image` | no | `mcr.microsoft.com/k8se/quickstart:latest` | the sample app; see the registry note in §8 |
| `min_replicas` | no | `0` | **the whole point of the week**; 1 buys away the cold start with a container that runs all night |
| `max_replicas` | no | `3` | scale-to-zero removes the floor on cost, so something has to cap the ceiling |

Point `versions.tf`'s `cloud {}` block at your own HCP organization, project
and workspace name.

---

## 4. Deploy

```bash
./scripts/deploy.sh
```

Expected sequence:

```
══ 1. resource providers on sub-lab-dev ══
══ 2. waiting for Microsoft.App to reach Registered ══
══ 3. terraform ══
══ 4. what was deployed ══
```

**A Container Apps environment takes several minutes to create** — it took
**14 m 55 s** here. That is normal, not a hang.

**5 resources** on a clean apply. HCP reports **6 objects**, because it counts
the data source that reads week 08's workspace alongside them.

---

## 5. What it deploys

| Resource | Count | Job |
| --- | --- | --- |
| Resource group | 1 | what dies together at teardown |
| User-assigned managed identity | 1 | the seam a private registry or an Azure SDK call would authenticate through |
| Container Apps environment | 1 | the boundary — shared network and log destination |
| Container app | 1 | the workload, 0 to 3 replicas, HTTPS-only ingress |
| Diagnostic setting | 1 | routes two log categories into week 08's workspace |

### Repository layout

| Path | Responsibility |
| --- | --- |
| [`terraform/`](terraform) | the infrastructure, split by decision |
| [`scripts/deploy.sh`](scripts/deploy.sh) | registers providers, waits, applies |
| [`scripts/validate.sh`](scripts/validate.sh) | 6 checks, 8 assertions, all measured |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | deletes the group, then verifies against Azure |

---

## 6. Validation

```bash
./scripts/validate.sh
```

**6 checks, 8 assertions. Measured 8 passed / 0 failed on 2026-10-14.**

A successful `terraform apply` proves the resources exist. It does **not**
prove the app refuses plain HTTP, that replicas reach zero, or that the logs
land in resource-specific tables. That is what these checks are for.

| # | Check | Expected |
| --- | --- | --- |
| 1 | the app serves traffic, and only over HTTPS | `200` on HTTPS; plain HTTP redirected or refused, **never** `200` |
| 2 | latency while a replica is already running | warm average **under 5 s** |
| 3 | replicas drop to zero when idle | `0` replicas within the cooldown |
| 4 | the first request after idle pays for the start | still a `200`, however slow |
| 5 | logs are routed to week 08's workspace, correctly | both named categories enabled, target workspace matches |
| 6 | this week's log rows are queryable in week 08's workspace | rows **> 0** in the dedicated table, **0** in `AzureDiagnostics` |

Measured results:

| What | Measured |
| --- | --- |
| HTTPS `GET /` | **200** |
| Plain HTTP on port 80 | **301** to HTTPS — never served in the clear |
| Warm request, average of 3 | **0.13 s** |
| Idle before replicas reached 0 | **602 s** from the last request |
| First request after idle (cold start) | **16.94 s**, still a 200 |
| The penalty scale-to-zero actually costs | **16.81 s** on one request |
| Console log rows in week 08's workspace | **3** |
| Rows in the shared `AzureDiagnostics` table | **0** — so the tables really are resource-specific |
| Container Apps environment creation time | **14 m 55 s** |

**The cooldown is not the whole wait.** `cooldown_period_in_seconds` is set to
300, and replicas did not reach zero until **602 s** after the last request —
roughly twice the configured value. The setting governs when the scaler starts
counting down, not when the last replica disappears. A test that checks for
zero at the 300-second mark concludes, wrongly, that scale-to-zero is broken.

**16.8 seconds is the real price of the design.** It is paid by one user, the
unlucky one who arrives first after an idle period, and it is invisible in any
average. Whether that is acceptable is a product decision, not an
infrastructure one — and it is the number to put in front of whoever makes it.

---

## 7. The decision that was forced

Container Apps offers three log destinations: `log-analytics`, `azure-monitor`
and `none`. The default, `log-analytics`, wires the environment to a workspace
using **that workspace's shared key**.

Week 08 built its workspace with local authentication disabled. Measured
against the live workspace:

```console
$ az monitor log-analytics workspace show ... --query features.disableLocalAuth
true
```

So there is no key to hand over, and the default path cannot work here at all.
`azure-monitor` sends through a **diagnostic setting** instead, which
authenticates as Azure Resource Manager. It is also the only destination
Microsoft supports when the workspace is reached over Private Link.

What it costs: the portal's **Logs** blade on the app is disabled under this
destination. Queries run against the workspace instead.

---

## 8. Design decisions

| Choice | Taken | Why not the alternative |
| --- | --- | --- |
| Image source | `mcr.microsoft.com` | Docker Hub rate limits anonymous pulls by IP, and a scaling environment shares one egress address — so it fails under exactly the load that caused the scale-out |
| Replica floor | 0 | A floor of 1 buys away the cold start with a container that runs all night |
| Replica ceiling | 3 | Scale-to-zero removes the floor on cost; without a ceiling the same autoscaler removes the limit on it |
| Scale trigger | concurrent requests | CPU is a lagging proxy — an app waiting on a database is busy with an idle CPU |
| Revision mode | Single | Multiple keeps old revisions alive to split traffic across, and alive means billable |
| Ingress | external, HTTPS only | With insecure connections allowed, port 80 answers in the clear and a client that gets a 200 never upgrades |
| Log categories | named, not `allLogs` | `allLogs` is defined by Azure and grows when Azure adds a category — a setting written once silently starts billing for new data |
| Metrics to logs | not enabled | Replica and request counts are platform metrics, already retained 93 days free |
| Workspace | week 08's, read as a data source | A data source cannot be destroyed by this week's teardown |

---

## 9. Troubleshooting

### A test that concludes scale-to-zero is broken

- **Problem:** replicas were still above zero five minutes after the last
  request, with `cooldown_period_in_seconds = 300`.
- **Root cause:** the cooldown governs when the scaler *starts counting down*,
  not when the last replica disappears. Actual time to zero was **602 s**.
- **Resolution:** poll for zero with a generous ceiling rather than asserting
  at the configured value.
- **Lesson learned:** a timing setting names the start of a process, not its
  completion. Asserting at the configured number tests the documentation, not
  the system.

### No log rows, immediately after deploy

- **Problem:** querying for console log rows right after the app served
  traffic returned nothing.
- **Root cause:** Azure documents a delay of several minutes before console
  logs are queryable.
- **Resolution:** `validate.sh` polls instead of asking once.
- **Lesson learned:** an empty result from a correct query is
  indistinguishable from a broken pipeline. Poll before concluding.

### Other things worth knowing

- A Container Apps environment takes several minutes to create (**14 m 55 s**
  here). That is normal, not a hang.
- The portal's **Logs** blade on the app is disabled under the `azure-monitor`
  destination. Query the workspace instead.

---

## 10. Cleanup

```bash
# teardown is the only irreversible step — check the figures first
python ../scripts/check_figures_before_destroy.py week-09-container-apps

./scripts/cleanup.sh
```

The script runs in four stages, and the fourth is the one that matters — it
**counts what is left in Azure** rather than trusting the exit codes above it:

```
══ 4. verify against Azure, not against the exit codes above ══
   resource groups named rg-containerapps-lab-dev-scus-001 : 0
   Container Apps environments     : 0
   container apps                  : 0
   wk09 managed identities         : 0
   week 08's workspace still there : log-platform-prod-scus-001
```

Every count must read `0` and the last line must name the workspace. A missing
workspace on that line is the real failure mode: it would mean the teardown
reached across the subscription boundary into the lab's shared log sink, which
other weeks depend on.

**Preserved on purpose:** week 08's Log Analytics workspace, in
`rg-observability-prod-scus-001` in the other subscription. It is read through
a data source and never owned here, so a destroy cannot reach it.

**Still charging afterwards:** nothing from this week. The 3 log rows already
ingested sit in week 08's workspace until its retention expires.

---

## 11. Known limitations and what production adds

- **A private registry.** This week pulls a Microsoft-published sample
  anonymously. Production builds its own image and pushes it to ACR, which adds
  a registry block pointing at the managed identity above — a change to *which
  identity pulls*, never a change that introduces a password. Week 10 does
  exactly this.
- **Build in CI, not on a laptop.** Week 07's federated credential is the
  identity that would do it.
- **Ingress behind a front door.** External ingress straight to the app is
  right for a demonstration and rare in production, where WAF and custom
  domains sit in front.
- **A revision strategy.** Single revision mode is the cheap, honest default;
  anything with real users wants Multiple and a traffic split.
- **The cold start is not solved, it is accepted.** 16.8 s on one request is
  the trade this design makes. A floor of 1 replica removes it and removes the
  $0.00 idle bill with it.

---

## 12. References

- [Azure Container Apps documentation](https://learn.microsoft.com/en-us/azure/container-apps/)
- [Scaling in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/scale-app)
- [Log storage and monitoring options](https://learn.microsoft.com/en-us/azure/container-apps/log-options)
- [Container Apps billing](https://learn.microsoft.com/en-us/azure/container-apps/billing)
- Write-up: [jayanthkatta.com/blog/week-09-container-apps](https://jayanthkatta.com/blog/week-09-container-apps/)
