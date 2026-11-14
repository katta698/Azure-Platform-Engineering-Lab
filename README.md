# Azure Platform Engineering Lab

**52-week hands-on Azure lab series — one deployable platform pattern a week, built for real and torn down.**

> 14 years as a DBA → transitioning to Cloud Architecture.
> Every week: real code, real bugs, real measurements. No tutorials. No sandboxes.

---

## Roadmap — 52 weeks planned

**Each finished week links to its code.** The week number opens the folder —
`README.md` for the design and the cost note, `LAB.md` for the runbook that
reproduces it. *Complete* opens the write-up.

Ordered by dependency, not by difficulty: the hub network and its private DNS
estate come early because most later weeks need them, and policy comes before
the things it governs.

### Phase 1 — Foundation (Weeks 01–07)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Bootstrap | Management group tree, OIDC identity, subscriptions | Management Groups, Entra ID, Subscriptions | ✅ Complete |
| [Week 01](./week-01-landing-zone) | The landing zone, deployed — policy that denies something | Management Groups, Azure Policy, Virtual Network | [✅ Complete](https://jayanthkatta.com/blog/week-01-azure-landing-zone/) |
| [Week 02](./week-02-policy-as-code) | Policy as code — initiatives and `deployIfNotExists` remediation | Azure Policy, Log Analytics, Storage, RBAC, Managed Identity | [✅ Complete](https://jayanthkatta.com/blog/week-02-policy-as-code/) |
| [Week 03](./week-03-module-factory) | A module factory on Azure Verified Modules | HCP private module registry, Log Analytics, Storage | [✅ Complete](https://jayanthkatta.com/blog/week-03-module-factory/) |
| [Week 04](./week-04-subscription-vending) | Subscription vending through the MCA alias API | Subscriptions (MCA alias), Management Groups, Cost Budgets, RBAC | [✅ Complete](https://jayanthkatta.com/blog/week-04-subscription-vending/) |
| [Week 05](./week-05-hub-network) | Hub network — Azure Firewall and the private DNS estate | Azure Firewall + Policy, Private DNS Zones, VNet Peering, Route Tables | [✅ Complete](https://jayanthkatta.com/blog/week-05-hub-network/) |
| [Week 06](./week-06-deployment-stacks) | Deployment Stacks and deny assignments | Deployment Stacks, Deny Assignments, Storage | [✅ Complete](https://jayanthkatta.com/blog/week-06-deployment-stacks/) |
| [Week 07](./week-07-workload-identity) | Workload identity end to end — zero secrets | User-Assigned Managed Identity, Federated Credentials, RBAC | [✅ Complete](https://jayanthkatta.com/blog/week-07-workload-identity/) |

### Phase 2 — Observability (Weeks 08–13)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| [Week 08](./week-08-log-analytics) | Log Analytics designed for cost — DCRs and table plans | Log Analytics, Data Collection Rules + Endpoints, Scheduled Query Rules | [✅ Complete](https://jayanthkatta.com/blog/week-08-log-analytics/) |
| [Week 09](./week-09-container-apps) | Container Apps — a workload that scales to zero | Container Apps + Environment, Managed Identity, Diagnostic Settings | [✅ Complete](https://jayanthkatta.com/blog/week-09-container-apps/) |
| [Week 10](./week-10-opentelemetry) | OpenTelemetry — one trace across two services, and sampling that keeps it whole | Application Insights, Container Apps, Container Registry, OpenTelemetry | [✅ Complete](https://jayanthkatta.com/blog/week-10-opentelemetry/) |
| [Week 11](./week-11-managed-prometheus) | Managed Prometheus and Grafana, alerts as code — no cluster, no secret | Azure Monitor Workspace, Managed Grafana, Linux VM, Prometheus Rule Groups | [✅ Complete](https://jayanthkatta.com/blog/week-11-managed-prometheus/) |
| [Week 12](./week-12-detections-as-code) | Detections as code — a matched pair, one that fires and one that must not | Microsoft Sentinel, Log Analytics, Analytics Rules, Automation Rules | [✅ Complete](https://jayanthkatta.com/blog/week-12-detections-as-code/) |
| Week 13 | Diagnostic settings enforced at scale | Azure Policy `deployIfNotExists`, Diagnostic Settings, Log Analytics | 📅 Planned |

### Phase 3 — Identity (Weeks 14–17)

**Blocked on an Entra ID P1/P2 licence.** Measured twice: `GET /v1.0/subscribedSkus`
returns an empty array, so the tenant holds none. Queued, not abandoned — a P2
trial covers all four and they run back to back once one is started.

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Week 14 | PIM, access reviews and break-glass | Entra ID P2, PIM, Access Reviews | 🔒 Blocked |
| Week 15 | Conditional Access as code, staged with report-only | Entra ID P1, Conditional Access, Named Locations | 🔒 Blocked |
| Week 16 | Access packages for self-service access | Entra ID P2, Entitlement Management | 🔒 Blocked |
| Week 17 | Lifecycle workflows — joiner, mover, leaver | Entra ID Governance, Lifecycle Workflows | 🔒 Blocked |

### Phase 4 — Compute and containers (Weeks 18–23)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Week 18 | An internal developer platform — Deployment Environments and Dev Box | Deployment Environments, Dev Box, Azure Policy | 📅 Planned |
| Week 19 | Container Apps self-service — KEDA event-driven scaling, building on week 09 | Container Apps, KEDA, Service Bus | 📅 Planned |
| Week 20 | AKS Automatic with workload identity | AKS Automatic, Workload Identity, Managed Identity | 📅 Planned |
| Week 21 | GitOps with Flux, guarded by Azure Policy for Kubernetes | AKS, Flux, Azure Policy for Kubernetes | 📅 Planned |
| Week 22 | Gateway API ingress with Application Gateway for Containers | Application Gateway for Containers, Gateway API | 📅 Planned |
| Week 23 | The Istio add-on — mTLS, and what a mesh costs | AKS Istio add-on, mTLS | 📅 Planned |

### Phase 5 — Data (Weeks 24–29)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Week 24 | PostgreSQL Flexible Server — HA, private, Entra auth, no passwords | PostgreSQL Flexible Server, Private Endpoints, Entra auth | 📅 Planned |
| Week 25 | Azure SQL Hyperscale and a failover actually performed | Azure SQL Hyperscale, Failover Groups | 📅 Planned |
| Week 26 | Cosmos DB multi-region — consistency demonstrated, vector search | Cosmos DB, Vector Search | 📅 Planned |
| Week 27 | Azure Managed Redis | Azure Managed Redis | 📅 Planned |
| Week 28 | Storage that survives an auditor — immutability and replication | Storage, Immutable Blob, Object Replication | 📅 Planned |
| Week 29 | Real-time analytics on Fabric | Microsoft Fabric, Eventstream, KQL Database | 📅 Planned |

### Phase 6 — AI platform (Weeks 30–35)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Week 30 | An AI landing zone — private, and governed like everything else | Azure AI Foundry, Private Endpoints, Azure Policy | 📅 Planned |
| Week 31 | RAG on the hub network — retrieval quality and private endpoints | Azure AI Search, Azure OpenAI, Private Link | 📅 Planned |
| Week 32 | Agents with tools, under a managed identity | Azure AI Agent Service, Managed Identity | 📅 Planned |
| Week 33 | Evaluation and content safety gating deploys | Azure AI Evaluation, Content Safety | 📅 Planned |
| Week 34 | An AI gateway — token quotas and per-team chargeback | API Management, Azure OpenAI | 📅 Planned |
| Week 35 | Model economics — provisioned throughput versus pay-as-you-go | Azure OpenAI PTU, Cost Management | 📅 Planned |

### Phase 7 — Security (Weeks 36–41)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Week 36 | Defender for Cloud attack paths, closed | Defender for Cloud, Attack Path Analysis | 📅 Planned |
| Week 37 | Customer-managed keys and the rotation that breaks things | Key Vault, CMK, Managed HSM | 📅 Planned |
| Week 38 | Confidential computing and attestation | Confidential VMs, Microsoft Azure Attestation | 📅 Planned |
| Week 39 | Private Link at scale — DNS Private Resolver, and a broken zone link | Private Link, DNS Private Resolver, Private DNS Zones | 📅 Planned |
| Week 40 | WAF tested with real payloads | Application Gateway WAF, Front Door WAF | 📅 Planned |
| Week 41 | Supply chain — signed images and admission control that rejects | Container Registry, Notation, Azure Policy for Kubernetes | 📅 Planned |

### Phase 8 — Resilience (Weeks 42–47)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Week 42 | Zone redundancy, proven per service | Availability Zones | 📅 Planned |
| Week 43 | Chaos Studio experiments in CI | Azure Chaos Studio | 📅 Planned |
| Week 44 | Backup vaults, with a restore performed | Backup Vault, Azure Backup | 📅 Planned |
| Week 45 | Multi-region failover — and failing back | Traffic Manager, Front Door, Site Recovery | 📅 Planned |
| Week 46 | Load testing to the actual ceiling | Azure Load Testing | 📅 Planned |
| Week 47 | A DR game day with measured RTO and RPO | Site Recovery, Backup Vault | 📅 Planned |

### Phase 9 — FinOps and operations (Weeks 48–52)

| Week | Pattern | Key Azure Services | Status |
|------|---------|-------------------|--------|
| Week 48 | FinOps toolkit — exports, anomaly alerts, real attribution | Cost Management, FinOps Toolkit, Data Factory | 📅 Planned |
| Week 49 | Reservations and savings plans modelled on real usage | Reservations, Savings Plans, Cost Management | 📅 Planned |
| Week 50 | Carbon optimization, with a workload changed because of it | Carbon Optimization, Azure Monitor | 📅 Planned |
| Week 51 | Arc and Update Manager — a non-Azure machine, same policy set | Azure Arc, Update Manager, Azure Policy | 📅 Planned |
| Week 52 | Compute Fleet and spot, proven by forcing an eviction | Azure Compute Fleet, Spot VMs | 📅 Planned |

---

## Beyond week 52 — optional, not committed

The 52 weeks are planned week by week. **Anything past them deliberately is
not** — and is not a commitment. The series is 52 weeks; carrying on afterwards
is a decision to take at the time, not a promise made now.

That is a lesson, not laziness. This roadmap was drafted in August 2026, and by
week 12 two of its assumptions had already moved: the identity phase was
blocked on an Entra licence the tenant does not hold, and Sentinel's Azure
portal experience was given a retirement date. Phase 6 — the AI platform — was
drafted seven months before it will be built, in the fastest-moving area in the
product. **A fixed two-year plan would rot twice as fast as a one-year plan.**

So year 2 is a set of themes. **Actual topics are fixed 4–8 weeks out**, against
live Azure documentation and the real subscription, in each week's Pre-Build
Briefing.

### Carried forward — displaced from Year 1, not dropped on merit

| Week | Project | Key Azure Services |
|------|---------|-------------------|
| Week 53 | The whole platform reviewed — every measured number, and what to redo | All of the above |

One row, because only one topic was displaced: the roadmap drafted 53 topics
for 52 slots and the capstone is the overflow. The identity weeks were delayed
inside Year 1 rather than pushed out of it — they moved from the 12–15 range to
14–17 when the licence turned out to be missing, and the observability phase
moved up to fill the gap.

### Candidate themes for Weeks 56+

| Theme | Candidate topics |
|---|---|
| **Scale to a second team** | Multi-tenancy, chargeback, quota arbitration between teams — everything in Year 1 assumes one consumer |
| **The migration year** | Azure Migrate, database migration with measured downtime, a real legacy workload moved |
| **Regulated workloads** | Data residency, sovereign cloud constraints, customer-managed everything, evidence for an actual audit framework |
| **Hybrid and edge** | Azure Local, IoT Operations, edge inference |
| **Deep networking** | ExpressRoute, Virtual WAN routing intent at scale, network virtual appliances |
| **Whatever AI infrastructure has become** | The fastest-moving area, and the one where a year-out plan is worth least |

Service names are checked against current Azure documentation at the start of
each week before any code is written. **Azure moves; the commitment is to the
problem, not to the product name.** A topic that cannot be built — a licence
missing, a service withdrawn — moves the topics behind it up, and the week
number follows what was actually built.

---

## How this lab reads Azure

Azure is explained here on its own terms, from its own primitives. Nothing in
this repo is framed as an equivalent of anything.

That is not a stylistic preference. Azure gives you three nested scopes —
management group, subscription, resource group — and the fastest way to build a
design that fights the platform for a year is to decide one of them is "really"
the important one and treat the other two as decoration. They are not three
sizes of the same box:

| Scope | The question it answers |
| --- | --- |
| **Management group** | *What is allowed here?* Policy and RBAC inheritance. Holds no resources. |
| **Subscription** | *Who pays, and what is the ceiling?* Billing, quota, provider registration. |
| **Resource group** | *What dies together?* The only scope where deletion is atomic and complete. |

Every structural decision in this lab follows from those three answers. The
hierarchy is documented in the Week 01 write-up.

---

## What Gets Built Each Week

Every week produces three things: a **lab** in this repository — Terraform,
a validation script and a cleanup script that has been run — a **write-up** on
the blog explaining what the problem was and what the evidence showed, and a
**reproduction guide** in the week's `LAB.md` with the exact commands and their
expected output. The lab is the implementation, the post is the argument, the
guide is how someone else gets the same result.

Every week follows the same pattern:

- **Terraform only.** No click-ops. State in HCP Terraform, one workspace per
  week, never local, never committed.
- **No static credentials.** CI authenticates through OIDC federated
  credentials. There is no client secret anywhere in this repository, and no
  week is allowed to introduce one.
- **A cost note before anything else.** What runs continuously, what teardown
  removes, and the monthly figure if left up. Every meter a week can bill on is
  enumerated *before* deployment by `scripts/price_check.py`, which refuses to
  pass until each flat recurring meter is acknowledged in writing.
- **A cleanup script that has actually been run.** Not written and assumed —
  executed, then verified against Azure rather than against the destroy's exit
  code.
- **Screenshots captured live during the deploy.** Evidence of the thing
  happening, not a page that happened to still be open afterwards.
- **Every number measured.** Latencies, costs and limits come from a real
  deployment in this lab, not from a documentation page. Cost is read from the
  invoice after teardown, never from a rate card.

---

## Week 01 — The landing zone, deployed

**The story:** A management group tree is a diagram until something is assigned to it. This week makes it govern, and proves it by getting a deployment denied.

**What it builds:**
- Two policy definitions and an initiative at the root management group
- An assignment at the landing-zone management group
- A virtual network that deliberately violates the policy, and is refused

**Resources:** 7 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-01-azure-landing-zone/

---

## Week 02 — Policy as code

**The story:** Week 01 proved a `deny`. A deny governs the next deployment and nothing else — it is a gate, and gates do not fix what is already inside. This week is the other half: policy that reaches into an estate that already exists and changes it.

**What it builds:**
- Two policy definitions — `deployIfNotExists` and `modify` — bundled into one initiative
- A user-assigned managed identity carrying three role assignments, granted *before* the assignment exists
- Two deliberately non-compliant storage accounts, remediated into compliance

**Resources:** 9 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-02-policy-as-code/

---

## Week 03 — A module factory on Azure Verified Modules

**The story:** A private module registry, a golden module published by git tag, and two consumers pinned to two different majors of that module in one state file. The claim: a private registry is not a convenience, it is what makes a version a contract.

**What it builds:**
- A private module registry in HCP Terraform
- A golden module published by git tag, versioned semantically
- Two consumers pinned to different majors, proving the pin is real

**Resources:** 2 Terraform resources — the factory; consumers pull the module from the registry | **Blog:** https://jayanthkatta.com/blog/week-03-module-factory/

---

## Week 04 — Subscription vending

**The story:** The bootstrap created three subscriptions by hand, one at a time, watching each one. This turns that into a pipeline: a request goes in, and a landing zone comes out created, placed, budgeted and granted, with no portal step.

**What it builds:**
- A subscription created through the MCA alias API
- Automatic placement into the management group tree
- A Cost Management budget with alerts, and RBAC granted at creation

**Resources:** 4 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-04-subscription-vending/

---

## Week 05 — The hub network

**The story:** Everything later in this lab attaches to what is built here: spokes peer into this hub, private endpoints resolve through this DNS estate, and egress leaves through this firewall. That makes the interesting decision the lifecycle, not the topology.

**What it builds:**
- Azure Firewall with a policy hierarchy and rule collection groups
- The private DNS zone estate, linked to the hub
- Spoke peering and route tables forcing egress through the firewall

**Resources:** 22 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-05-hub-network/

---

## Week 06 — Deployment stacks, and a deny that outranks the owner

**The story:** Every protection this lab has built so far can be removed by whoever it protects. An Owner deletes the lock, then deletes the thing. A deployment stack's deny assignment is a different guarantee.

**What it builds:**
- A deployment stack at management group scope with `denyWriteAndDelete`
- Two identical storage accounts — one managed by the stack, one not
- The same delete, by the same Owner: one succeeds, one is refused

**Resources:** 2 Terraform resources, plus the deployment stack | **Blog:** https://jayanthkatta.com/blog/week-06-deployment-stacks/

---

## Week 07 — A CI identity with no secret to steal

**The story:** GitHub Actions deploys to Azure. Nothing in the repository is a credential. GitHub mints a short-lived token describing the run, and Azure checks it against a trust configured once.

**What it builds:**
- A user-assigned managed identity — an object that cannot hold a password
- A federated credential trusting one repository on one branch
- Reader at subscription scope, and nothing wider

**Resources:** 4 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-07-workload-identity/

---

## Week 08 — Log Analytics, designed around what it costs

**The story:** The workspace every later week sends logs to. Ingestion is the largest surprise bill in Azure, so the design decisions here are cost decisions, made on purpose rather than left at their defaults.

**What it builds:**
- A workspace with two custom tables on deliberately different plans — Analytics and Basic
- A data collection endpoint and rule, with a transform that drops rows before they are billed
- Scheduled query rules and an action group on top

**Resources:** 9 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-08-log-analytics/

---

## Week 09 — Container Apps: a workload that costs nothing idle

**The story:** Deploy a workload that serves real HTTP traffic from the internet, runs no replicas at all when nobody is using it, and reports across a subscription boundary. Eight weeks built the place things run; nothing was running in any of them.

**What it builds:**
- A Container Apps environment and an app scaled to zero
- A user-assigned managed identity for registry pull
- Diagnostic settings reporting into week 08's workspace, across subscriptions

**Resources:** 5 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-09-container-apps/

---

## Week 10 — OpenTelemetry: a trace that crosses a process boundary

**The story:** One request to a public frontend produces one trace spanning two services, with the elapsed time attributed to the service that spent it — and both images pulled from a private registry with no password anywhere.

**What it builds:**
- Two Container Apps instrumented with OpenTelemetry, frontend and backend
- Application Insights receiving a single distributed trace
- A private container registry, pulled with a managed identity

**Resources:** 10 Terraform resources | **Blog:** https://jayanthkatta.com/blog/week-10-opentelemetry/

---

## Week 11 — Managed Prometheus: a metric with no cluster and no password

**The story:** A Prometheus running on a plain Linux VM writes its own metrics into an Azure Monitor workspace, authenticated by a managed identity, with no secret anywhere in the configuration — and the same series reads back through PromQL. No Kubernetes anywhere.

**What it builds:**
- An Azure Monitor workspace — `Microsoft.Monitor/accounts`, not Log Analytics
- A Linux VM running self-managed Prometheus with `remote_write` over a managed identity
- Managed Grafana, and a Prometheus rule group evaluating a recording rule and an alert

**Resources:** 16 Terraform resources | **Measured:** 796,849 samples shipped, $7.19 billed | **Blog:** https://jayanthkatta.com/blog/week-11-managed-prometheus/

---

## Week 12 — Detections as code

**The story:** Microsoft Sentinel analytics rules declared in Terraform and then tested against a real event — because a detection that has never fired and a detection that cannot fire look exactly the same from the outside.

**What it builds:**
- A Log Analytics workspace with Sentinel enabled on it, and a subscription-scope diagnostic setting
- A matched pair of analytics rules: one deliberately triggered, one that must stay silent
- An automation rule labelling incidents, with no Logic App

**Resources:** 7 Terraform resources | **Measured:** 13 alerts grouped into 3 incidents, $0.00 billed | **Blog:** https://jayanthkatta.com/blog/week-12-detections-as-code/

---

## Layout

```
terraform/bootstrap/          management groups, CI identity, subscriptions — runs once
scripts/                      inventory, secret sweep, meter enumeration, legacy credential cleanup
week-NN-topic/
├── README.md                 cost note, architecture, what was measured
├── meters.json               every flat meter the week can bill on, each acknowledged
├── docs/blog/screenshots/    committed — the blog embeds these directly
├── scripts/                  deploy.sh, validate.sh, cleanup.sh
└── terraform/
```

Markdown is gitignored apart from `README.md`. Working notes and study material
stay on the machine that made them.

A week is one resource group: `rg-wkNN-topic-dev-scus-001`. Teardown is a
resource group delete — atomic, complete, nothing retained.

---

## Prerequisites (one-time setup)

```bash
az login
terraform login
```

Then see `terraform/bootstrap/README.md`. Every week has its own README with its
own prerequisites and its own cost note.

`terraform.tfvars` is gitignored in every directory. Tenant IDs, subscription
IDs, billing account identifiers and object IDs are never committed —
`scripts/secret-sweep.sh` enforces that and exits non-zero on a hit.

---

## Cost Philosophy

**Every week is designed to cost $0 between sessions.** Nothing is left running
unless the week says so explicitly and says why.

```bash
bash week-NN-topic/scripts/cleanup.sh   # destroys, then verifies against Azure
```

Three rules make that more than an intention:

- **Meters are enumerated before deployment, not after.**
  `python scripts/price_check.py week-NN-topic` lists every meter the week's
  services can bill on, separates the flat recurring ones — those that charge
  while a thing merely exists — and exits non-zero until each is acknowledged
  in a committed `meters.json` with a reason.
- **Cost is read from the invoice, never from a rate card.** A week publishes
  "pending" rather than an estimate, and is updated when the charges post.
- **Teardown is verified against Azure**, not inferred from a successful
  destroy. The check asks whether the resource group and the billable objects
  inside it are actually gone.

This exists because week 11 shipped a cost note that never mentioned Managed
Grafana's flat $6.00/user/month meter. It was $6 of a $7.19 invoice, in the one
component the write-up implied was free.

| Week | Measured |
|------|----------|
| Week 09 | $0 |
| Week 10 | $0 |
| Week 11 | $7.19 — $6.00 of it a Grafana per-user meter that should have been caught |
| Week 12 | $0.00 |

---

## About

Jay Katta — 14 years as a DBA, moving into cloud architecture.
Building one production-grade Azure pattern every week for 52 weeks.

- GitHub: [@katta698](https://github.com/katta698)
- Blog: https://jayanthkatta.com/blog/
