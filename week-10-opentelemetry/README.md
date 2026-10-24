# Week 10 — OpenTelemetry: a trace that crosses a process boundary

**Goal:** one request to a public frontend produces **one trace spanning two
services**, with the time attributed to the service that spent it — and both
images pulled from a private registry with no password anywhere.

Week 09 measured a 16.94-second cold start. That number says *how long*, and
nothing about *where*. A trace is the thing that answers the second question,
and it only becomes interesting once more than one service is involved.

## Cost note

| | |
| --- | --- |
| Runs continuously | nothing — torn down at the end |
| Billed while up | ACR **Basic at $0.1666/day**, measured from the retail price API |
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

## What it deploys

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

## The agent routes; it does not instrument

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

## The week's uncomfortable line

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
apart, in the same lab. The post says so rather than pretending the estate is
uniformly locked down.

## Decisions worth copying

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

## What production does differently

- **Build in CI, not from a laptop.** Week 07's federated credential is the
  identity that would run `az acr build`.
- **A sampler below 100%.** This week measures at both; anything busy runs far
  below 1.0, and the right ratio is a cost decision made with the trace volume
  in front of you.
- **Premium ACR** for private endpoints and geo-replication. Basic has neither,
  and this week does not pretend to exercise them.
- **Alerting on the traces**, not just collecting them. Week 08 built the alert
  machinery; wiring it to trace-derived metrics is its own week.

## How it was built and run

```bash
./scripts/deploy.sh      # registry FIRST, then az acr build, then everything else
./scripts/validate.sh    # 6 checks, 9 assertions, all measured
./scripts/cleanup.sh     # deletes the group, then verifies week 08 survived
```

Three passes, because a container app cannot reference an image tag that does
not resolve yet: the registry must exist before a build can push to it, and the
images must exist before the apps can pull them.

## What was measured

`./scripts/validate.sh` — **9 passed / 0 failed**, 2026-10-23.

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

**The trace earns its keep in two rows.** Of the 256.4 ms a user waits, 250.8 ms
is the backend — the frontend's own work is about 5.6 ms. A log line can tell
you the request took 256 ms; only the trace tells you which service to go and
fix.

**Sampling keeps whole traces, not halves.** 100 requests at a 0.2 ratio kept
16 traces, and every one of them contained both services. That is
`parentbased` doing its job: the decision is taken once at the frontend and
respected downstream.

**Health probes had to be excluded to see any of this.** They were 78% of all
requests at 0.6 ms each, and including them dragged the p50 to 0.7 ms for a
service that deliberately sleeps 250. A latency number averaged over a liveness
probe is a number about the probe.

## Notes for anyone repeating this

- **`AppRoleName` is `<environment>.<service>`**, not the bare
  `OTEL_SERVICE_NAME`. Filtering on the service name alone returns zero rows
  against a table that is full — which reads exactly like "no telemetry
  arrived", and cost an hour here.
- **`az acr build` can crash after succeeding.** Streaming the log back dies
  with `UnicodeEncodeError` on a Windows console while the build completes
  normally in Azure. Use `--no-logs` and read the run status.
- **The agent cannot send metrics to Application Insights** — logs and traces
  only. That is an agent limitation, not a misconfiguration.
- **The agent is preview**, and its own health is not exposed in the portal or
  through monitoring APIs.
