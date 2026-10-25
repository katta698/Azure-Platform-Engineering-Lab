# Week 10 — OpenTelemetry: a trace that crosses a process boundary

**Goal:** one request to a public frontend produces **one trace spanning two
services**, with the elapsed time attributed to the service that spent it —
and both images pulled from a private registry with no password anywhere.

Week 09 measured a 16.94-second cold start. That number says *how long*, and
nothing about *where*. A trace answers the second question, and it only becomes
interesting once more than one service is involved.

---

**Reproduce it:** [LAB.md](LAB.md) — prerequisites, variables, commands, expected outputs, validation and cleanup.
**Write-up:** [jayanthkatta.com/blog/week-10-opentelemetry](https://jayanthkatta.com/blog/week-10-opentelemetry/)

---

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

## 2. The agent routes; it does not instrument

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

## 3. Design decisions

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
