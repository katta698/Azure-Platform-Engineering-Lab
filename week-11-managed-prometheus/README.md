# Week 11 — Managed Prometheus: a metric with no cluster and no password

**Goal:** a Prometheus running on a plain Linux VM writes its own metrics into
an **Azure Monitor workspace**, authenticated by a **managed identity**, with
no secret anywhere in the configuration — and the same series comes back out
through PromQL and renders in Grafana.

Almost everything written about Azure Managed Prometheus assumes Kubernetes.
The add-on, the documentation, the rule groups, the sample dashboards. This
week deliberately has **no cluster**, because the interesting question is what
the managed service actually requires — and the answer is a data collection
rule and an identity, not AKS.

---

**Reproduce it:** [LAB.md](LAB.md) — prerequisites, variables, commands, expected outputs, validation and cleanup.
**Write-up:** [jayanthkatta.com/blog/week-11-managed-prometheus](https://jayanthkatta.com/blog/week-11-managed-prometheus/)

---

## 1. Cost note

| | |
| --- | --- |
| Runs continuously | nothing — torn down at the end |
| VM `Standard_D2als_v7` | **$0.0962/hour** (Linux), retail price API, southcentralus |
| Managed Grafana Standard | **$0.0411 per node-hour × 2 nodes = $0.0822/hour** — *unless* the 30-day free trial applies |
| Standard static public IP | **$0.005/hour** |
| Metrics ingestion | **$0.16 per 10M samples** |
| PromQL queries | **$0.001 per 10M samples** |
| Workspace storage | **$0.00** — 18 months retention at no storage charge |
| Measured for this week | **not yet posted** — read from Cost Management once the charges land, see below |
| Teardown | `./scripts/cleanup.sh`, run 2026-10-28. Resource group confirmed gone |

All rates above were read from the **Azure retail price API** for
`southcentralus` on 2026-10-28, not quoted from a pricing page. The measured
total is deliberately absent: Azure posts usage on a delay, and a number
invented before the bill arrives is not a measurement.

### What this week actually cost is not what it is about

Prometheus shipped **796,849 samples** over the life of the deployment —
counted from `prometheus_remote_storage_samples_total`, not estimated. At
$0.16 per 10M samples that is about **$0.013**. One and a third cents.

The two machines that produced and displayed those samples bill at
**$0.1784/hour** combined.

So the metrics pipeline — the entire subject of the week — costs on the order
of **one percent** of the compute standing around it. That inverts the
intuition this lab started with. The expensive part of observability here is
not the observability.

The caveat that makes it honest: this is **one** Prometheus scraping **itself**
every 30 seconds. A real fleet multiplies the sample count and not the VM
count, and the ratio moves. The lesson is to measure where the money is before
optimising, not that ingestion is free.

**Grafana's 30-day free trial** is one instance per subscription and this
subscription had not used it. Whether it applied here is a question for the
bill, and the cost figure states it rather than assuming either way.

---

## 2. An Azure Monitor workspace is not a Log Analytics workspace

Week 08 built the other kind. They are different resources with different
query languages and different bills, and the names do not help.

| | Log Analytics workspace (week 08) | Azure Monitor workspace (this week) |
| --- | --- | --- |
| ARM type | `Microsoft.OperationalInsights/workspaces` | `Microsoft.Monitor/accounts` |
| Holds | logs and events | Prometheus time series |
| Queried with | KQL | **PromQL** |
| Retention | configurable, billed per GB beyond the grant | **18 months, no storage charge** |
| Billed on | ingestion per GB | **samples ingested and samples queried** |

`validate.sh` asserts the ARM type explicitly for this reason — the check
exists because the two are easy to confuse, not because the deploy is in
doubt.

---

## 3. Design decisions

| Choice | Taken | Why not the alternative |
| --- | --- | --- |
| Auth to the ingestion endpoint | **user-assigned managed identity** | The documented Entra ID alternative needs a **client secret**, which this lab forbids outright |
| Identity lifetime | user-assigned | It outlives the VM; rebuild the host and the role assignment still resolves |
| `Monitoring Metrics Publisher` scope | the **data collection rule** | The DCR is what accepts the write — the workspace and the subscription are both wider than necessary |
| Prometheus install | pinned 3.5.0 tarball, not the distro package | Microsoft documents 2.45+ for user-assigned managed-identity remote-write; the version is load-bearing and worth stating |
| Egress | public IP | Default outbound access is retired, so a VM needs an explicit path. A NAT gateway is **nine times the price** for the same outbound, and nothing inbound is permitted anyway |
| Inbound | explicit `deny-all-inbound` at priority 4096 | Azure already denies by default; writing it down states the intent instead of inheriting it |
| Host access | `az vm run-command` | No SSH port is open at all, so validation goes through the control plane |
| Rule group `cluster_name` | **not set** | It is optional, and the point of the week is that managed Prometheus does not require a cluster |
| Grafana SKU | Standard | Essential is cheaper and has no hourly node charge, but it is Preview and `azurerm` cannot express it — reaching it means `azapi` for a preview SKU |

### The remote-write URL is assembled, and one field lies

The host comes from the data collection **endpoint**; the path names the data
collection **rule** by its *immutable* id, which is not its resource name.
Both are read back from the deployed workspace, so a rebuild in another
subscription renders a correct config with nothing to hand-edit.

The trap: the DCR data source **also** exposes a `metrics_ingestion_endpoint`
attribute, and for a workspace-managed rule it comes back **empty**. Terraform
joins an empty host onto a path without complaint, applies cleanly, boots
cleanly, and Prometheus fails hours later with
`unsupported protocol scheme ""`. An empty string is a valid string, so
nothing warns.

The guard is a **precondition on the VM** — the resource that bakes this URL
into its cloud-init — so the VM is never created carrying a config that
cannot work:

```hcl
lifecycle {
  precondition {
    condition     = startswith(local.remote_write_url, "https://")
    error_message = "The assembled remote_write URL has no scheme, ..."
  }
}
```

**It is deliberately not a `check` block, and the first version of this week
got that wrong.** HashiCorp documents that a failed `check` assertion makes
Terraform *"report a warning and continue executing the current operation"*,
and that the block runs *"as the last step of plan or apply operation, after
Terraform has planned or provisioned your infrastructure"*. So a check would
have warned about the broken URL once the VM carrying it already existed —
the precise failure it was written to prevent. Measured: with an empty host,
a `check` plans `1 to add` and exits **0**; the precondition errors and exits
**1**.

A precondition *"throws an error ... and stops the current operation"*. When
the endpoint is already known — any run against existing state — it fails at
**plan**. On a first apply the workspace does not exist yet, so the value is
unknown at plan time and Terraform defers the check to the **apply** phase,
still before the VM is created. Either way the broken VM is never built.

### Deploying Grafana grants you no access to Grafana

With the instance deployed and its own identity able to read the workspace,
`az role assignment list` on the instance returned **nothing**, and opening the
endpoint would have bounced to Entra and refused after sign-in.

The Azure RBAC that **creates** the resource and the Grafana RBAC that lets a
human **log in** are separate systems. The deployer needs an explicit
`Grafana Admin` (or `Grafana Viewer`) assignment on the instance. This is
easy to miss because every other resource in the lab is usable by whoever
deployed it.

---

## 4. The role assignment takes about thirty minutes

`Monitoring Metrics Publisher` on the DCR is roughly **six times** slower to
propagate than week 08's equivalent grant. Until it lands, remote-write
returns HTTP 403 and the whole pipeline looks broken while being correctly
configured.

`validate.sh` therefore polls — 40 attempts at 60-second intervals — rather
than asserting once and failing. A check that cannot distinguish "wrong" from
"not yet" is a check that teaches the wrong lesson.

---

## 5. What was verified

`./scripts/validate.sh` — **7 passed, 0 failed**:

1. The workspace is `Microsoft.Monitor/accounts`, not a Log Analytics workspace
2. `Monitoring Metrics Publisher` is on the DCR and **not** at subscription scope
3. `prometheus.yml` on the running host contains nothing resembling a credential
4. No inbound allow rule exists on the NSG at all
5. A series written by the VM is queryable from the workspace
6. One recording rule and one alert rule exist, scoped to the workspace, with no cluster named
7. Grafana's data source points at this week's workspace

Screenshots in [`docs/blog/screenshots/`](docs/blog/screenshots/); what each
one has to prove is declared in `docs/FIGURE_PLAN.md` **before** capture.

---

## 6. What production does differently

- **Scrapes something other than itself.** This Prometheus scrapes its own
  `/metrics`, which proves the pipeline and nothing about a workload.
- **No local retention worth the name.** `--storage.tsdb.retention.time=2h`
  is a buffer, not storage; the workspace is the store.
- **The action group has no receiver.** The alert rule is wired to a group
  that notifies nobody. This week proves a rule written in Terraform becomes a
  rule Azure evaluates — it does **not** claim a notification was delivered.
- **The alert threshold is trivial.** It is built to fire, not to be a
  sensible SLO.
- **One VM, no high availability.** The host is a single point of failure for
  collection; production runs an agent per node or the AKS add-on.
- **The public IP is an egress convenience.** Production routes through a NAT
  gateway or a private endpoint to the ingestion endpoint.
