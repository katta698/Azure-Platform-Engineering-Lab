# Lab Guide — Week 11: Managed Prometheus without a cluster

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-11-managed-prometheus/) explains what it does and why; this guide is the runbook. The [README](README.md) carries the cost note and the design reasoning.

**Status:** deployed 2026-10-27, validated **7 passed / 0 failed** on 2026-10-28, torn down 2026-10-28 — 16 resources destroyed, verified against Azure. Every output below is real.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| Azure subscription (`sub-lab-dev` here) | holds everything this week creates |
| **Contributor** on the subscription | creates the resource group, workspace, VM, Grafana and rule group |
| **User Access Administrator** (or Owner) | the lab creates **three role assignments** — `Monitoring Metrics Publisher`, `Monitoring Data Reader` and `Grafana Admin`. Contributor alone cannot do this |
| HCP Terraform account, organization and project | remote state; the workspace runs in **local execution** mode |

No Entra licence, no management group access and no cluster of any kind are
needed.

### Tools

| Tool | Version used | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf`; the `check` block needs 1.5+ |
| `hashicorp/azurerm` | **~> 5.2** | 5.x needs an explicit `subscription_id` on the provider block |
| Azure CLI | 2.60+ | provider registration, `az vm run-command`, validation |
| Prometheus | **3.5.0** | installed on the VM by cloud-init, pinned in `variables.tf` |
| SSH key | any existing ed25519/RSA **public** key | Azure requires a key or a password on a Linux VM. Nothing can use it — no inbound port is open |

### Existing infrastructure

**None.** This week stands alone. It does not read week 08's Log Analytics
workspace and does not write to it — see the README on why those two resources
are different things.

### Resource providers

`deploy.sh` registers these and waits for the first three:

```
Microsoft.Monitor        Microsoft.Dashboard      Microsoft.AlertsManagement
Microsoft.Insights       Microsoft.Compute        Microsoft.Network
Microsoft.ManagedIdentity
```

`Microsoft.AlertsManagement` is easy to forget because it owns *alert rules*
rather than metrics. Its absence failed the first apply with
`409 MissingSubscriptionRegistration` on the Prometheus rule group — after
every other resource had already been created.

### Region and quota

`location` defaults to **`southcentralus`**. The VM size is the constraint,
not the region, and three separate walls decided it:

| Wall | Symptom | Reality |
| --- | --- | --- |
| `Standard_B2s` (v1) | `SkuNotAvailable ... Capacity Restrictions` | reads like transient capacity; the SKU is simply **not offered** in the region |
| `Standard_B2als_v2`, `Basv2`, `Bsv2` | quota exceeded at create time | family vCPU quota is **zero**. `az vm list-skus` reports them *unrestricted*, because SKU restrictions and quota are different things and **quota is only checked at create time** |
| any size with a `p` | VM boots, Prometheus never starts | those are **ARM64**; cloud-init downloads the `linux-amd64` tarball |

`Standard_D2als_v7` clears all three: offered in the region, family quota 10,
AMD x64. Total Regional vCPUs on this subscription is 10, so 2 is comfortable.

**Check quota before assuming a size works:**

```bash
az vm list-usage --location southcentralus -o table | grep -i "Dalsv7\|Total Regional"
```

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform.tfvars` is gitignored.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | everything lands here |
| `location` | no | `southcentralus` | see the quota table above before changing |
| `ssh_public_key_path` | no | `~/.ssh/id_ed25519.pub` | an **existing** key. Terraform does not generate one on purpose — a generated key puts its private half in state |
| `vm_size` | no | `Standard_D2als_v7` | must be x64 and have non-zero family quota |
| `prometheus_version` | no | `3.5.0` | Microsoft documents **2.45+** for user-assigned managed-identity remote-write |
| `grafana_sku` | no | `Standard` | the only value `azurerm` accepts |
| `alert_up_threshold` | no | `0` | fires while `up` exceeds this. Deliberately trivial |

Point `versions.tf`'s `cloud {}` block at your own HCP organization, project
and workspace name. Create the workspace with **local execution** before
`terraform init` — a new HCP workspace defaults to *remote*, and the whole
week fails differently if that is wrong.

---

## 3. Deploy

```bash
./scripts/deploy.sh
```

One apply — no staging passes. Nothing here references something Terraform
cannot order for itself.

**The apply finishing does not mean the pipeline works.** `deploy.sh` says so
at the end, and it is the single most important thing about this week:

```
The apply is finished. The pipeline is probably not working yet.

Monitoring Metrics Publisher on the data collection rule takes about
THIRTY MINUTES to propagate. Until then Prometheus on the VM gets HTTP 403
from the ingestion endpoint, retries, and nothing appears in the workspace.
```

That is roughly **six times** longer than the same role took in week 08. It is
documented behaviour, not a fault, and it is why `validate.sh` polls instead of
asking once.

---

## 4. What it deploys

16 resources. The ones that matter:

| Resource | Name | Job |
| --- | --- | --- |
| `azurerm_monitor_workspace` | `amw-wk11-dev-scus-001` | the metrics store — `Microsoft.Monitor/accounts`, queried with PromQL |
| `azurerm_user_assigned_identity` | `id-wk11-prometheus-dev-scus-001` | what Prometheus authenticates as |
| `azurerm_role_assignment` | — | `Monitoring Metrics Publisher`, scoped to the **data collection rule** |
| `azurerm_linux_virtual_machine` | `vm-wk11-prometheus-...` | runs Prometheus 3.5.0; no inbound port |
| `azurerm_monitor_alert_prometheus_rule_group` | `prg-wk11-dev-scus-001` | one recording rule, one alert rule, **no cluster** |
| `azurerm_dashboard_grafana` | `amg-wk11-dev-scus-001` | draws the series back out |

### The remote-write URL, and the attribute that lies

The workspace creates its own data collection **rule** and **endpoint**.
Neither is declared by this configuration, so both are read back:

```hcl
locals {
  remote_write_url = join("", [
    data.azurerm_monitor_data_collection_endpoint.metrics.metrics_ingestion_endpoint,
    "/dataCollectionRules/",
    data.azurerm_monitor_data_collection_rule.metrics.immutable_id,
    "/streams/Microsoft-PrometheusMetrics/api/v1/write?api-version=2023-04-24",
  ])
}
```

The host comes from the **endpoint**. The DCR data source *also* exposes a
`metrics_ingestion_endpoint`, and for a workspace-managed rule it returns an
**empty string** — which joins into a URL with no scheme, applies cleanly,
boots cleanly, and fails hours later on the host. The `check` block in
`main.tf` fails the **plan** instead.

Note the path uses the DCR's **immutable id**, not its resource name.

### Repository layout

```
week-11-managed-prometheus/
├── terraform/      the deployment — workspace, identity, VM, Grafana, rules
├── scripts/        deploy / validate / cleanup, each runnable on its own
└── docs/           figure plan, diagram, and the screenshots the post embeds
```

---

## 5. Validation

```bash
./scripts/validate.sh
```

**Result on 2026-10-28: 7 passed, 0 failed.**

| # | Test | Expected | Actual | Status |
| --- | --- | --- | --- | --- |
| 1 | ARM type of the workspace | `microsoft.monitor/accounts` | `microsoft.monitor/accounts` | **PASS** |
| 2 | `Monitoring Metrics Publisher` scope | ≥1 on the DCR, **0** at subscription scope | 1 on the DCR, 0 at subscription | **PASS** |
| 3 | `prometheus.yml` on the running host | no password, client secret or private key | 0 matches | **PASS** |
| 4 | NSG inbound allow rules | none | none | **PASS** |
| 5 | A VM-written series queryable from the workspace | ≥1 series | `up{job="prometheus", instance="localhost:9090", source="self-managed-vm"}` = 1 | **PASS** |
| 6 | Rule group contents | ≥2 rules, no `clusterName` | 1 recording + 1 alert, no cluster | **PASS** |
| 7 | Grafana data source | points at this week's workspace | `Managed_Prometheus_amw-wk11-dev-scus-001` | **PASS** |

Check 3 reads the file **on the running host** through `az vm run-command`, not
from the template — the question is what is actually deployed, and no SSH port
is open.

Check 5 polls **40 times at 60-second intervals**, for the RBAC propagation
above.

### Querying the series by hand

```bash
TOKEN=$(az account get-access-token \
          --resource https://prometheus.monitor.azure.com \
          --query accessToken -o tsv)

curl -H "Authorization: Bearer $TOKEN" \
     --get "$(terraform output -raw query_endpoint)/api/v1/query" \
     --data-urlencode 'query=up{job="prometheus"}'
```

Observed response carried `instance: localhost:9090` (the VM talking about
itself), `source: self-managed-vm` (an `external_label` from `prometheus.yml`,
so provenance survives the whole journey), and
`microsoft.amwresourceid` — which Azure stamps onto every series it ingests.

Note that the **query** endpoint is a different host from the **write**
endpoint, so a successful query exercises both halves.

### Driving Grafana to a panel

The workspace integration creates a **second** data source, type
`grafana-azureprometheus-datasource`, named after the workspace. It is **not**
the default — the default is the `Azure Monitor` plugin, which does not speak
PromQL. Read the uid first:

```bash
az grafana data-source list -n amg-wk11-dev-scus-001 \
  --query "[].{name:name,uid:uid,type:type}" -o table
```

---

## 6. Cleanup

```bash
# teardown is the only irreversible step — check the figures first
python ../scripts/check_figures_before_destroy.py week-11-managed-prometheus
./scripts/cleanup.sh
```

**Three things bill by the hour and none stops on its own:** the Grafana
instance, the VM, and the public IP.

`cleanup.sh` does not trust the destroy's exit code. It counts what survives,
by ARM type, and says the number — because week 05 had a destroy report
success while an Azure Firewall kept billing.

Observed on 2026-10-28:

```
Destroy complete! Resources: 16 destroyed.

   resource groups named rg-prometheus-lab-dev-scus-001 : 0
   Grafana instances                  : 0
   virtual machines                   : 0
   public IP addresses                : 0
   Azure Monitor workspaces           : 0
   Prometheus rule groups             : 0
   orphaned Metrics Publisher grants  : 0

   Clean - nothing billable from this week survives.
```

**Grafana takes about ten minutes to delete** (measured: 10m12s). The destroy
is not stuck.

Nothing shared is touched — week 08's Log Analytics workspace is never
referenced by this week.

---

## 7. Troubleshooting

### `unsupported protocol scheme ""` on the host, hours after a clean apply

**Problem.** Terraform applied without error, the VM booted, Prometheus
started, and nothing ever reached the workspace. The log showed
`unsupported protocol scheme ""`.

**Root cause.** The remote-write URL was assembled using
`metrics_ingestion_endpoint` from the data collection **rule** data source.
For a workspace-managed rule that attribute is an **empty string**. The join
produced `/dataCollectionRules/...` — a path with no scheme and no host.
Nothing warned, because an empty string is a valid string.

**Resolution.** Read the host from the data collection **endpoint** data
source, and add a `check` block asserting the assembled URL starts with
`https://` so it fails at plan time.

**Lesson learned.** An attribute existing on a data source does not mean it is
populated for your resource. Where a value is composed from several lookups,
assert the shape of the result — a `check` block costs four lines and moves a
runtime failure to plan time.

### HTTP 403 from the ingestion endpoint for half an hour

**Problem.** After a successful apply, Prometheus retried remote-write and got
403 for roughly 30 minutes.

**Root cause.** `Monitoring Metrics Publisher` on the DCR had not propagated.
This is about six times slower than the equivalent grant in week 08.

**Resolution.** Wait. `validate.sh` polls 40 × 60s rather than asserting once.

**Lesson learned.** A validation that cannot distinguish *wrong* from *not
yet* teaches the wrong lesson. If a dependency is eventually consistent, the
check must be too.

### `SkuNotAvailable ... Capacity Restrictions`, which is not about capacity

**Problem.** Three VM sizes failed in three different ways before one worked.

**Root cause.** Three unrelated walls: `Standard_B2s` is not offered in the
region at all; every v2 B-series family has a vCPU quota of **zero** on this
subscription; `p`-suffixed sizes are ARM64 and cannot run the amd64 tarball.

**Resolution.** `Standard_D2als_v7` — in-region, quota 10, x64.

**Lesson learned.** `az vm list-skus` reporting a SKU as unrestricted says
nothing about quota. **SKU availability and quota are different systems, and
quota is only evaluated at create time.** Check both.

### cloud-init ran before the VM had internet

**Problem.** The first build's cloud-init failed after 132 seconds with
`Failed to connect to github.com port 443`. The network came up shortly
afterwards and worked fine.

**Root cause.** `runcmd` is documented as running late in boot. On Azure that
is still not late enough to assume egress.

**Resolution.** A wait-for-egress loop (40 × 15s probe) ahead of the download,
plus `curl --retry 8 --retry-delay 15 --retry-connrefused` on top of it.

**Lesson learned.** "Late in boot" is not a promise of connectivity. One
successful probe also does not promise the next request succeeds — wait *and*
retry.

### Grafana deployed, and nobody could open it

**Problem.** The instance was healthy and its own identity could read the
workspace, but `az role assignment list` on the instance returned nothing and
the endpoint would have refused a human after sign-in.

**Root cause.** The Azure RBAC that creates the resource and the Grafana RBAC
that authorises a login are separate systems. Creating Managed Grafana grants
the creator no access to it.

**Resolution.** An explicit `Grafana Admin` assignment on the instance for the
deploying principal.

**Lesson learned.** Easy to miss because every other resource in this lab is
usable by whoever deployed it. A resource with its own internal authorisation
model needs that model configured too.

### Grafana Explore showed "No data" against a correct deployment

**Problem.** A capture of Explore with a valid PromQL expression rendered an
empty resource picker and **No data**.

**Root cause.** The Explore URL pinned no data source, so Grafana used its
**default** — the `Azure Monitor` plugin in *Metrics* mode, which does not
speak PromQL. The workspace's Prometheus data source is a second, non-default
source named after the workspace.

**Resolution.** Read the uid with `az grafana data-source list` and set it on
both the pane and the query.

**Lesson learned.** Two data sources that both say "Azure Monitor" do
different jobs. A panel with no data is as likely to be pointed at the wrong
source as to be missing data.

---

## 8. Known limitations and what production adds

- **It scrapes itself.** One Prometheus, scraping its own `/metrics` every
  30s. The pipeline is proven; nothing about a workload is.
- **Local retention is 2 hours** — a buffer, not storage. The workspace is the
  store.
- **The action group has no receiver.** The alert rule is wired to a group
  that notifies nobody. This week proves a Terraform-defined rule becomes a
  rule Azure evaluates; it does **not** claim a notification was delivered.
- **The alert threshold is trivial** and built to fire.
- **One VM, no HA.** Production runs an agent per node, or the AKS add-on.
- **Egress is a public IP.** Production uses a NAT gateway or a private
  endpoint to the ingestion endpoint.
- **Grafana Standard, not Essential.** Essential has no hourly node charge but
  is Preview and `azurerm` cannot express it.

---

## 9. References

- [Azure Monitor workspace overview](https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/azure-monitor-workspace-overview)
- [Send Prometheus data to Azure Monitor using remote write](https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-remote-write)
- [Prometheus rule groups in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/prometheus-rule-groups)
- [Azure Managed Grafana — Grafana roles](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-share-grafana-workspace)
- [Prometheus `remote_write` configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write)
- [`azurerm_monitor_workspace`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_workspace)
- [`azurerm_monitor_alert_prometheus_rule_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_alert_prometheus_rule_group)
- [Terraform `check` blocks](https://developer.hashicorp.com/terraform/language/checks)
- Source: [`week-11-managed-prometheus/`](https://github.com/katta698/Azure-Platform-Engineering-Lab/tree/main/week-11-managed-prometheus)
