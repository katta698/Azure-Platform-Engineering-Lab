# Week 09 — Container Apps: a workload that costs nothing until someone asks

**Goal:** deploy a workload that serves real HTTP traffic from the internet,
runs **no replicas at all** when nobody is using it, and reports to week 08's
Log Analytics workspace across a subscription boundary.

Weeks 01 to 08 built the place things run and the place they report to. Nothing
was actually running in any of them. This is the first week with a workload in
it, and the design question is not how to make it fast — it is what you are
willing to pay while nobody is using it.

---

**Reproduce it:** [LAB.md](LAB.md) — prerequisites, variables, commands, expected outputs, validation and cleanup.
**Write-up:** [jayanthkatta.com/blog/week-09-container-apps](https://jayanthkatta.com/blog/week-09-container-apps/)

---

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

## 2. The decision that was forced

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

## 3. Design decisions

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
