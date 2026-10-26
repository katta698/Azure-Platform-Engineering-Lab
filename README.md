# Azure Platform Engineering Lab

Production-grade Azure patterns, one per week, built and deployed for real —
then torn down, with the cost and the evidence written up.

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

## Standards applied every week

- **Terraform only.** No click-ops. State in HCP Terraform, one workspace per
  week, never local, never committed.
- **No static credentials.** CI authenticates through OIDC federated
  credentials. There is no client secret anywhere in this repository, and no
  week is allowed to introduce one.
- **A cost note before anything else.** What runs continuously, what teardown
  removes, and the monthly figure if left up. A budget with alerts exists before
  anything with a per-hour price is deployed.
- **A cleanup script that has actually been run.** Not written and assumed —
  executed, verified empty, before the week is called done.
- **Screenshots captured live during the deploy.** Evidence of the thing
  happening, not a page that happened to still be open afterwards.
- **Every number measured.** Latencies, costs and limits come from a real
  deployment in this lab, not from a documentation page.

---

## Layout

```
terraform/bootstrap/          management groups, CI identity, subscriptions — runs once
scripts/                      inventory, secret sweep, legacy credential cleanup
week-NN-topic/
├── README.md                 cost note, architecture, what was measured
├── docs/blog/screenshots/    committed — the blog embeds these directly
├── scripts/                  deploy.sh, validate.sh, cleanup.sh
└── terraform/
```

Markdown is gitignored apart from `README.md`. Working notes and study material
stay on the machine that made them.

A week is one resource group: `rg-wkNN-topic-dev-scus-001`. Teardown is a
resource group delete — atomic, complete, nothing retained.

---

## Week tracker

A week is one deployable pattern in one resource group — built for real, measured,
then torn down. Ordered by dependency, not by difficulty: the hub network and its
private DNS estate come early because most later weeks need them, and policy comes
before the things it governs.

**Each finished week links to its code.** The week number opens the
folder &mdash; `README.md` for the design and the cost note,
`LAB.md` for the runbook that reproduces it. *Complete* opens the
write-up.

| Week | Pattern | Status |
| --- | --- | --- |
| Bootstrap | Management group tree, OIDC identity, subscriptions | Complete |
| **Foundation** | | |
| [01](week-01-landing-zone) | The landing zone, deployed — policy that denies something | [Complete](https://jayanthkatta.com/blog/week-01-azure-landing-zone/) |
| [02](week-02-policy-as-code) | Policy as code — initiatives and `deployIfNotExists` remediation | [Complete](https://jayanthkatta.com/blog/week-02-policy-as-code/) |
| [03](week-03-module-factory) | A module factory on Azure Verified Modules | [Complete](https://jayanthkatta.com/blog/week-03-module-factory/) |
| [04](week-04-subscription-vending) | Subscription vending through the MCA alias API | [Complete](https://jayanthkatta.com/blog/week-04-subscription-vending/) |
| [05](week-05-hub-network) | Hub network — Azure Firewall and the private DNS estate | [Complete](https://jayanthkatta.com/blog/week-05-hub-network/) |
| [06](week-06-deployment-stacks) | Deployment Stacks and deny assignments | [Complete](https://jayanthkatta.com/blog/week-06-deployment-stacks/) |
| [07](week-07-workload-identity) | Workload identity end to end — zero secrets | [Complete](https://jayanthkatta.com/blog/week-07-workload-identity/) |
| **Observability** | | |
| [08](week-08-log-analytics) | Log Analytics designed for cost — DCRs and table plans | [Complete](https://jayanthkatta.com/blog/week-08-log-analytics/) |
| [09](week-09-container-apps) | Container Apps — a workload that scales to zero | [Complete](https://jayanthkatta.com/blog/week-09-container-apps/) |
| [10](week-10-opentelemetry) | OpenTelemetry — one trace across two services, and sampling that keeps it whole | [Complete](https://jayanthkatta.com/blog/week-10-opentelemetry/) |
| 11 | Managed Prometheus and Grafana, alerts as code | Planned |
| 12 | Detections as code in Microsoft Sentinel | Planned |
| 13 | Diagnostic settings enforced at scale | Planned |
| **Identity** — blocked on an Entra ID P1/P2 licence | | |
| 14 | PIM, access reviews and break-glass | Blocked |
| 15 | Conditional Access as code, staged with report-only | Blocked |
| 16 | Access packages for self-service access | Blocked |
| 17 | Lifecycle workflows — joiner, mover, leaver | Blocked |
| **Compute and containers** | | |
| 18 | An internal developer platform — Deployment Environments and Dev Box | Planned |
| 19 | Container Apps self-service — KEDA event-driven scaling, building on week 09 | Planned |
| 20 | AKS Automatic with workload identity | Planned |
| 21 | GitOps with Flux, guarded by Azure Policy for Kubernetes | Planned |
| 22 | Gateway API ingress with Application Gateway for Containers | Planned |
| 23 | The Istio add-on — mTLS, and what a mesh costs | Planned |
| **Data** | | |
| 24 | PostgreSQL Flexible Server — HA, private, Entra auth, no passwords | Planned |
| 25 | Azure SQL Hyperscale and a failover actually performed | Planned |
| 26 | Cosmos DB multi-region — consistency demonstrated, vector search | Planned |
| 27 | Azure Managed Redis | Planned |
| 28 | Storage that survives an auditor — immutability and replication | Planned |
| 29 | Real-time analytics on Fabric | Planned |
| **AI platform** | | |
| 30 | An AI landing zone — private, and governed like everything else | Planned |
| 31 | RAG on the hub network — retrieval quality and private endpoints | Planned |
| 32 | Agents with tools, under a managed identity | Planned |
| 33 | Evaluation and content safety gating deploys | Planned |
| 34 | An AI gateway — token quotas and per-team chargeback | Planned |
| 35 | Model economics — provisioned throughput versus pay-as-you-go | Planned |
| **Security** | | |
| 36 | Defender for Cloud attack paths, closed | Planned |
| 37 | Customer-managed keys and the rotation that breaks things | Planned |
| 38 | Confidential computing and attestation | Planned |
| 39 | Private Link at scale — DNS Private Resolver, and a broken zone link | Planned |
| 40 | WAF tested with real payloads | Planned |
| 41 | Supply chain — signed images and admission control that rejects | Planned |
| **Resilience** | | |
| 42 | Zone redundancy, proven per service | Planned |
| 43 | Chaos Studio experiments in CI | Planned |
| 44 | Backup vaults, with a restore performed | Planned |
| 45 | Multi-region failover — and failing back | Planned |
| 46 | Load testing to the actual ceiling | Planned |
| 47 | A DR game day with measured RTO and RPO | Planned |
| **FinOps and operations** | | |
| 48 | FinOps toolkit — exports, anomaly alerts, real attribution | Planned |
| 49 | Reservations and savings plans modelled on real usage | Planned |
| 50 | Carbon optimization, with a workload changed because of it | Planned |
| 51 | Arc and Update Manager — a non-Azure machine, same policy set | Planned |
| 52 | Compute Fleet and spot, proven by forcing an eviction | Planned |
| 53 | The whole platform — every measured number, and what to redo | Planned |

Service names are checked against current Azure documentation at the start of each
week before any code is written. Azure moves; the commitment is to the problem,
not to the product name.

---

## Running anything here

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

Built by Jay Katta — 14 years as a DBA, moving into cloud architecture.
Write-ups at [blog.jayanthkatta.com](https://blog.jayanthkatta.com).
