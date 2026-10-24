# Week 09 — Container Apps: a workload that costs nothing until someone asks

**Goal:** deploy a workload that serves real HTTP traffic from the internet,
runs **no replicas at all** when nobody is using it, and reports to week 08's
Log Analytics workspace across a subscription boundary.

Weeks 01 to 08 built the place things run and the place they report to. Nothing
was actually running in any of them. This is the first week with a workload in
it, and the design question is not how to make it fast — it is what you are
willing to pay while nobody is using it.

## Cost note

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
`sub-lab-dev` shows no charges at all for the days this ran. The app used roughly
**600 vCPU-seconds** and **1,200 GiB-seconds** against monthly free grants of
180,000 and 360,000, on a handful of requests against a 2-million allowance. The
free grant absorbed the entire week.

Rates measured from the Azure retail price API for `southcentralus`, not quoted
from a marketing page:

| Meter | Rate |
| --- | --- |
| vCPU, active | $0.000024 per vCPU-second |
| vCPU, idle | $0.000003 per vCPU-second |
| Memory, active and idle | $0.000003 per GiB-second |
| Requests | $0.40 per million |

The idle rate is eight times cheaper than active — and it is **unreachable from
this week's design**, which is the most useful thing on the table. A replica
only qualifies for idle billing if the revision has a minimum replica count
*above zero* and is sitting at it. Scaling to zero removes the bill entirely;
keeping a floor of one and letting it go idle is a different, also-defensible
choice that trades a small standing cost for no cold starts.

## What it deploys

| Resource | Count | Job |
| --- | --- | --- |
| Resource group | 1 | what dies together at teardown |
| User-assigned managed identity | 1 | the seam a private registry or an Azure SDK call would authenticate through |
| Container Apps environment | 1 | the boundary — shared network and log destination |
| Container app | 1 | the workload, 0 to 3 replicas, HTTPS-only ingress |
| Diagnostic setting | 1 | routes two log categories into week 08's workspace |

## The decision that was forced

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

## Decisions worth copying

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

## What production does differently

- **A private registry.** This week pulls a Microsoft-published sample
  anonymously. Production builds its own image and pushes it to ACR, which adds
  a registry block pointing at the managed identity above — a change to *which
  identity pulls*, never a change that introduces a password.
- **Build in CI, not on a laptop.** Week 07's federated credential is the
  identity that would do it.
- **Ingress behind a front door.** External ingress straight to the app is
  right for a demonstration and rare in production, where WAF and custom
  domains sit in front.
- **A revision strategy.** Single revision mode is the cheap, honest default;
  anything with real users wants Multiple and a traffic split.

## How it was built and run

```bash
./scripts/deploy.sh      # registers Microsoft.App, waits for it, applies
./scripts/validate.sh    # 6 checks, 8 assertions, all measured
./scripts/cleanup.sh     # deletes the group, then verifies against Azure
```

State lives in HCP Terraform (`azure-week-09-dev`, **local** execution), so
there are no remote run logs to screenshot.

Provider registration is in `deploy.sh` and deliberately not in Terraform:
registration is subscription-wide shared state, and one week's destroy must not
unregister a provider another week still needs. `Microsoft.App` was
`NotRegistered` on `sub-lab-dev` before this week.

## What was measured

`./scripts/validate.sh` — **8 passed / 0 failed**, run 2026-10-14.

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

## Notes for anyone repeating this

- A Container Apps environment takes several minutes to create. That is normal,
  not a hang.
- Console log rows are not queryable immediately — Azure documents a delay of
  several minutes, so `validate.sh` polls rather than asking once and concluding
  the routing is broken.
- `cooldown_period_in_seconds` is set explicitly to 300. Leaving it out means
  the replica lingers for five minutes anyway, and a test that checks for zero
  one minute after the last request concludes scale-to-zero does not work.
