# Week 10 — OpenTelemetry: a trace that crosses a process boundary

**Lab guide.** This is the reproducible half: exact prerequisites, variables,
commands, expected outputs, validation and cleanup. The concepts, architecture
and results are written up at
[jayanthkatta.com/blog/week-10-opentelemetry](https://jayanthkatta.com/blog/week-10-opentelemetry/).

**Goal:** one request to a public frontend produces **one trace spanning two
services**, with the elapsed time attributed to the service that spent it —
and both images pulled from a private registry with no password anywhere.

Week 09 measured a 16.94-second cold start. That number says *how long*, and
nothing about *where*. A trace answers the second question, and it only becomes
interesting once more than one service is involved.

---

## 1. Cost note

| | |
| --- | --- |
| Runs continuously | nothing — torn down at the end |
| Billed while up | ACR **Basic at $0.1666/day**, read from the retail price API |
| OpenTelemetry agent | **$0.00** — Microsoft provisions 0.5 vCPU / 1.5 GB inside the environment at no compute cost |
| Traces and logs | ingested into week 08's workspace at its Analytics rate; sampling is the control |
| Measured for this week | **$0.0142** — read from Cost Management on 2026-10-24, after teardown |
| Teardown | `./scripts/cleanup.sh`. Deletes the registry **and the images in it** — rebuildable from `app/` with one command |

**Measured: $0.0142**, read from Cost Management after teardown. All of it is
Container Registry; the Container Apps sat inside the monthly free grant and
the OpenTelemetry agent carries no compute charge. ACR Basic bills
$0.1666/day, so about two hours of registry is what this week actually cost.

Application Insights is **workspace-based**, pointing at week 08's workspace.
Classic Application Insights kept its own store with its own retention and its
own bill; workspace-based means every decision week 08 made — table plans,
retention, the daily cap — applies to this data too.

---

## 2. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| Azure subscription for the workload (`sub-lab-dev` here) | holds the resource group, registry, environment and apps |
| A second subscription holding a Log Analytics workspace (`sub-management` here) | Application Insights stores its data there; a single-subscription setup works too — point both variables at it |
| **Contributor** on the workload subscription | creates everything in the resource group |
| **User Access Administrator** (or Owner) on the workload subscription | the lab creates an **AcrPull role assignment**, which Contributor alone cannot do |
| **Reader** on the resource group holding the Log Analytics workspace | the workspace is read through a data source, never modified |
| HCP Terraform account, organization and project | remote state; the workspace runs in **local execution** mode |

### Tools

| Tool | Version used | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | 5.x needs an explicit `subscription_id` on every provider block |
| `Azure/azapi` | **~> 2.0** | required: `azurerm` cannot express `openTelemetryConfiguration` |
| Azure CLI | 2.60+ | used for provider registration and `az acr build` |
| **Docker** | **not required** | images build on an ACR Tasks agent in Azure |

### Existing infrastructure

- **Week 08's Log Analytics workspace.** Defaults point at
  `log-platform-prod-scus-001` in `rg-observability-prod-scus-001`. Override
  `log_analytics_workspace_name` and `log_analytics_resource_group` to use your
  own. The lab does **not** create a workspace.
- **Week 09's pattern** for the Container Apps environment and its diagnostic
  setting is reused here, but nothing from week 09 needs to still be deployed.

### Resource providers

`deploy.sh` registers these on the workload subscription before anything else,
and waits for `Microsoft.ContainerRegistry` to reach `Registered`:

```
Microsoft.App   Microsoft.ContainerRegistry   Microsoft.Insights
Microsoft.OperationalInsights   Microsoft.ManagedIdentity
```

### Region and quota

`location` defaults to **`southcentralus`**. The managed OpenTelemetry agent is
in **preview** and is not available in every region — check availability before
changing it. No quota increase is needed: the apps run on the Consumption
profile inside the monthly free grant, and ACR Basic has no quota gate.

---

## 3. Configuration

Copy the example and fill it in. `terraform.tfvars` is gitignored.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | the workload subscription |
| `management_subscription_id` | **yes** | — | the subscription holding the Log Analytics workspace |
| `location` | no | `southcentralus` | must be a region where the agent is available |
| `log_analytics_resource_group` | no | `rg-observability-prod-scus-001` | week 08's resource group |
| `log_analytics_workspace_name` | no | `log-platform-prod-scus-001` | week 08's workspace |
| `image_tag` | no | `v1` | set by `deploy.sh` from the ACR build, so the apps always reference an image that exists |
| `trace_sampler_arg` | no | `1.0` | fraction of traces kept, passed to the SDK as `OTEL_TRACES_SAMPLER_ARG` |
| `backend_work_ms` | no | `250` | how long the backend deliberately takes, so the trace has something to attribute |

Point `versions.tf`'s `cloud {}` block at your own HCP organization, project and
workspace name.

---

## 4. Deploy

```bash
./scripts/deploy.sh
```

**Three passes, and the ordering is the point.** A container app references its
image by tag, and Container Apps fails the revision if the tag does not
resolve. So: the registry must exist before a build can push to it, and the
images must exist before the apps can pull them.

| Pass | What runs | Why it cannot be merged |
| --- | --- | --- |
| 1 | `terraform apply -target` the registry and its identity | nothing to push to yet |
| 2 | `az acr build` both images in Azure | the apps need a resolvable tag |
| 3 | full untargeted `terraform apply` | `-target` leaves a half-built object that looks finished (week 04) |

Expected sequence:

```
══ 1. resource providers on sub-lab-dev ══
   Microsoft.App already Registered
   ...
══ 2. terraform init ══
══ 3. the registry first, so there is somewhere to push ══
══ 4. build both images IN AZURE ══
══ 5. everything else ══
```

**11 resources** on a clean apply. To deploy by hand instead, run the same three
passes — a single `terraform apply` from empty will fail on the image tag.

### Override the sampler

```bash
terraform apply -var 'trace_sampler_arg=0.2' -var "image_tag=$TAG"
```

---

## 5. What it deploys

| Resource | Count | Job |
| --- | --- | --- |
| Resource group | 1 | what dies together at teardown |
| Container registry (Basic) | 1 | holds the two images we build |
| User-assigned managed identity | 1 | pulls from the registry — no password exists |
| AcrPull role assignment | 1 | scoped to the registry, not the subscription |
| Application Insights | 1 | the trace destination, stored in week 08's workspace |
| Container Apps environment | 1 | the boundary, and where the agent lives |
| OpenTelemetry agent config | 1 | `azapi` — azurerm cannot express it |
| Container apps | 2 | frontend (external) and backend (internal only) |
| Diagnostic setting | 1 | console logs to week 08's workspace, as week 09 established |

### Repository layout

| Path | Responsibility |
| --- | --- |
| [`app/`](app) | the only code that knows what a span is |
| [`app/otel_setup.py`](app/otel_setup.py) | tracer, sampler, OTLP exporter — shared by both services |
| [`app/frontend/`](app/frontend) | public; calls the backend |
| [`app/backend/`](app/backend) | internal; deliberately slow |
| [`terraform/registry.tf`](terraform/registry.tf) | ACR, the identity, and AcrPull |
| [`terraform/observability.tf`](terraform/observability.tf) | Application Insights and the managed agent |
| [`terraform/apps.tf`](terraform/apps.tf) | the environment and the two container apps |
| [`scripts/`](scripts) | `deploy.sh`, `validate.sh`, `cleanup.sh` — each runs end to end |

---

## 6. Validation

```bash
./scripts/validate.sh
```

**6 checks, 9 assertions. Measured 9 passed / 0 failed on 2026-10-23.**

A successful `terraform apply` proves the resources exist. It does **not**
prove a trace crosses the process boundary — that is what these checks are for.

| # | Check | Expected output |
| --- | --- | --- |
| 1 | one request, two services | `GET / -> 200`, body carries the backend's payload |
| 2 | the backend is internal only | `ingress.external = false`; from the internet, **404** |
| 3 | the image is pulled with an identity, not a secret | `adminUserEnabled = false`, `passwordRef = <none>`, AcrPull assignments on the registry = 1 |
| 4 | traces reach week 08's workspace | request span count > 0 (**663** measured) |
| 5 | one operation spans both services | operations containing BOTH > 0 (**74** measured) |
| 6 | the trace says where the time went | frontend p50 **256.4 ms**, backend p50 **250.8 ms** |

Measured results:

| What | Measured |
| --- | --- |
| Frontend `GET /` | **200**, carrying the backend's payload |
| Backend reachable from the internet | **no** — 404, `ingress.external=false` |
| Registry admin user | **disabled** |
| App's registry credential | **none** — identity only, no `passwordSecretRef` |
| Request spans in week 08's workspace | **663** |
| Operations containing **both** services | **74** |
| Frontend `GET /` p50 | **256.4 ms** |
| Backend `GET /api/items` p50 | **250.8 ms** |
| Traces kept at sampler 1.0 | all |
| Traces kept at sampler 0.2 | **16 of 100** |
| Half-traces at sampler 0.2 | **0** |

**Two rows carry the week.** Of the 256.4 ms a user waits, 250.8 ms is the
backend — the frontend's own work is about 5.6 ms. A log line can tell you the
request took 256 ms; only the trace tells you which service to go and fix.

**Sampling keeps whole traces, not halves.** 100 requests at a 0.2 ratio kept
16 traces, and every one contained both services. That is `parentbased` doing
its job: the decision is taken once at the frontend and respected downstream.

### Querying the traces by hand

```kql
AppRequests
| extend svc = tostring(split(AppRoleName, '.')[-1])
| where Name !contains 'health'
| summarize p50 = percentile(DurationMs, 50) by svc
```

`AppRoleName` is **`<environment>.<service>`**, not the bare
`OTEL_SERVICE_NAME` — see Troubleshooting. Health probes must be excluded or
they dominate the percentile.

---

## 7. The agent routes; it does not instrument

Container Apps has a **managed OpenTelemetry agent**. It costs nothing, runs
inside the environment, and injects its own endpoint into every container:

```
OTEL_EXPORTER_OTLP_ENDPOINT   http://k8se-otel.k8se-apps.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL   grpc
OTEL_RESOURCE_ATTRIBUTES      service.instance.id=frontend--0000001-…
```

It is a **router**. Microsoft's own FAQ: *"Do I need to reference the
OpenTelemetry SDK in my code? **Yes.** The SDK creates telemetry data, and the
managed agent is only responsible to route data."*

Enable the agent against an uninstrumented app and you get a correctly
configured pipeline carrying nothing — every component healthy, no data.

Do **not** set `OTEL_EXPORTER_OTLP_ENDPOINT` yourself; it overrides the
agent's address and sends spans nowhere.

---

## 8. Design decisions

| Choice | Taken | Why not the alternative |
| --- | --- | --- |
| Registry admin user | **off** | It is one shared username and password that cannot be scoped or attributed, and it ends up in CI variables for years |
| Image pull | user-assigned identity | The app holds no `passwordSecretRef` at all |
| AcrPull scope | the registry | Not the subscription — the apps only ever read images |
| Build location | `az acr build` | Builds in Azure; no Docker daemon locally, and the build does not depend on what a laptop has installed |
| Base image | `mcr.microsoft.com/azurelinux/base/python` | Same reasoning as week 09: Docker Hub rate limits anonymous pulls by egress IP |
| Backend ingress | internal | A public backend would make the "distributed" claim meaningless |
| Sampler | `parentbased_traceidratio` | Independent samplers keep half a trace, which looks complete and is worse than keeping none |
| Agent config | `azapi` | azurerm has no argument for `openTelemetryConfiguration` |

### The week's uncomfortable line

```hcl
resource "azurerm_application_insights" "tracing" {
  local_authentication_enabled = true
}
```

Week 08 set **that same argument to `false`** on the workspace, and that single
word is what forced week 09's entire logging design. Here it has to be `true`:
the managed agent authenticates with a connection string, and Microsoft
documents no ARM-authenticated alternative — *"the Application Insights
resource must allow local authentication to receive data from the
OpenTelemetry data agent."*

Two Microsoft-recommended controls pulling in opposite directions, three weeks
apart, in the same lab. Recorded rather than smoothed over.

---

## 9. Troubleshooting

### A full table that read as empty

- **Problem:** validation reported zero traces for twenty minutes while 663
  spans sat in the workspace.
- **Root cause:** the managed agent writes `AppRoleName` as
  `<environment>.<service>`, not the bare `OTEL_SERVICE_NAME`, so a filter on
  `'frontend'` matched nothing.
- **Resolution:** match on the suffix — `split(AppRoleName, '.')[-1]`.
- **Lesson learned:** an empty result from a correct-looking query is
  indistinguishable from no telemetry. Run `AppRequests | summarize count()`
  with no filter **first**. Count the rows before explaining why there are
  none.

### `az acr build` crashes after succeeding

- **Problem:** the command exits 1 with `UnicodeEncodeError` and the image is
  in the registry anyway.
- **Root cause:** the CLI streams the build agent's log back through colorama
  to a Windows console; pip's progress bar is not encodable in cp1252. The
  crash is in the client's output handling, after the remote build has finished
  and pushed.
- **Resolution:** `--no-logs`, then read `az acr task list-runs`.
- **Lesson learned:** when the work happens remotely, the server's recorded
  status is the result. The local exit code only describes the local process.

### A latency number that was really about the health probe

- **Problem:** the first p50 came out at 0.7 ms for a service that sleeps
  250 ms on purpose.
- **Root cause:** liveness probes were 78% of all requests at 0.6 ms each.
- **Resolution:** `where Name !contains 'health'`.
- **Lesson learned:** excluding them is not tidying the data. Including them
  was measuring a different thing and calling it application latency.

### Other things worth knowing

- **An unknown KQL column fails the whole query**, even inside an `or`. A
  column that exists in one table's schema and not another's will not
  silently evaluate false.
- **The agent cannot send metrics to Application Insights** — logs and traces
  only. That is a documented agent limitation, not a misconfiguration.
- **The agent is preview**, and its own health is not exposed in the portal or
  through monitoring APIs. There is nothing to check; you verify it by whether
  data arrives.

---

## 10. Cleanup

```bash
# teardown is the only irreversible step — check the figures first
python ../scripts/check_figures_before_destroy.py week-10-opentelemetry

./scripts/cleanup.sh
```

The script destroys the resource group and then **counts what is left**, which
is the difference between tearing down and believing you did:

```
   resource groups named rg-tracing-lab-dev-scus-001 : 0
   Microsoft.ContainerRegistry/registries            0
   Microsoft.App/managedEnvironments                 0
   Microsoft.Insights/components                     0
   week 08's workspace still there                   log-platform-prod-scus-001
```

**Preserved on purpose:** week 08's Log Analytics workspace, in the other
subscription. It is read through a data source and never owned here — the last
line exists to prove the teardown did not reach it.

**Still charging afterwards:** nothing from this week. The traces and logs
already ingested sit in week 08's workspace until its retention expires.

**Deleting the registry deletes the images.** That is intended — they rebuild
from `app/` with one command — but a registry is the one resource here that can
hold something a teardown cannot reconstruct if the source is lost.

---

## 11. Known limitations and what production adds

- **The managed OpenTelemetry agent is in preview.** No health signal, no
  metrics path to Application Insights, limited regional availability.
- **Local authentication is enabled on Application Insights.** Required by the
  agent; it is a knowing trade, not an oversight.
- **Build runs from a workstation.** In production this runs in CI under week
  07's federated credential. No client secret, OIDC only.
- **ACR Basic** has no private endpoints and no geo-replication. Premium does;
  this week does not pretend to exercise them.
- **Sampler at 1.0.** Right for a lab, wrong for anything busy. The right ratio
  is a cost decision made with the trace volume in front of you — this week
  measures both 1.0 and 0.2 so the behaviour is known before the decision.
- **No alerting on the traces.** Week 08 built the alert machinery; wiring it
  to trace-derived metrics is its own week.

---

## 12. References

- [Collect and read OpenTelemetry data in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/opentelemetry-agents)
- [Enable Azure Monitor OpenTelemetry](https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable)
- [ACR Tasks overview](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-tasks-overview)
- [Terraform `azapi_update_resource`](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/update_resource)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- Write-up: [jayanthkatta.com/blog/week-10-opentelemetry](https://jayanthkatta.com/blog/week-10-opentelemetry/)
