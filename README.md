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

| Week | Pattern | Status |
| --- | --- | --- |
| Bootstrap | Management group tree, OIDC identity, subscriptions | Complete |
| **Foundation** | | |
| 01 | The landing zone, deployed — policy that denies something | Complete |
| 02 | Policy as code — initiatives and `deployIfNotExists` remediation | Complete |
| 03 | A module factory on Azure Verified Modules | Planned |
| 04 | Subscription vending through the MCA alias API | Planned |
| 05 | Hub network — Azure Firewall and the private DNS estate | Planned |
| 06 | Deployment Stacks and deny assignments | Planned |
| **Identity** | | |
| 07 | Workload identity end to end — zero secrets | Planned |
| 08 | PIM, access reviews and break-glass | Planned |
| 09 | Conditional Access as code, staged with report-only | Planned |
| 10 | Access packages for self-service access | Planned |
| 11 | Lifecycle workflows — joiner, mover, leaver | Planned |
| **Observability** | | |
| 12 | Log Analytics designed for cost — DCRs and table plans | Planned |
| 13 | Managed Prometheus and Grafana, alerts as code | Planned |
| 14 | OpenTelemetry tracing and sampling that keeps the signal | Planned |
| 15 | Detections as code in Microsoft Sentinel | Planned |
| 16 | Diagnostic settings enforced at scale | Planned |
| **Compute and containers** | | |
| 17 | An internal developer platform — Deployment Environments and Dev Box | Planned |
| 18 | Container Apps self-service — KEDA and scale to zero | Planned |
| 19 | AKS Automatic with workload identity | Planned |
| 20 | GitOps with Flux, guarded by Azure Policy for Kubernetes | Planned |
| 21 | Gateway API ingress with Application Gateway for Containers | Planned |
| 22 | The Istio add-on — mTLS, and what a mesh costs | Planned |
| **Data** | | |
| 23 | PostgreSQL Flexible Server — HA, private, Entra auth, no passwords | Planned |
| 24 | Azure SQL Hyperscale and a failover actually performed | Planned |
| 25 | Cosmos DB multi-region — consistency demonstrated, vector search | Planned |
| 26 | Azure Managed Redis | Planned |
| 27 | Storage that survives an auditor — immutability and replication | Planned |
| 28 | Real-time analytics on Fabric | Planned |
| **AI platform** | | |
| 29 | An AI landing zone — private, and governed like everything else | Planned |
| 30 | RAG on the hub network — retrieval quality and private endpoints | Planned |
| 31 | Agents with tools, under a managed identity | Planned |
| 32 | Evaluation and content safety gating deploys | Planned |
| 33 | An AI gateway — token quotas and per-team chargeback | Planned |
| 34 | Model economics — provisioned throughput versus pay-as-you-go | Planned |
| **Security** | | |
| 35 | Defender for Cloud attack paths, closed | Planned |
| 36 | Customer-managed keys and the rotation that breaks things | Planned |
| 37 | Confidential computing and attestation | Planned |
| 38 | Private Link at scale — DNS Private Resolver, and a broken zone link | Planned |
| 39 | WAF tested with real payloads | Planned |
| 40 | Supply chain — signed images and admission control that rejects | Planned |
| **Resilience** | | |
| 41 | Zone redundancy, proven per service | Planned |
| 42 | Chaos Studio experiments in CI | Planned |
| 43 | Backup vaults, with a restore performed | Planned |
| 44 | Multi-region failover — and failing back | Planned |
| 45 | Load testing to the actual ceiling | Planned |
| 46 | A DR game day with measured RTO and RPO | Planned |
| **FinOps and operations** | | |
| 47 | FinOps toolkit — exports, anomaly alerts, real attribution | Planned |
| 48 | Reservations and savings plans modelled on real usage | Planned |
| 49 | Carbon optimization, with a workload changed because of it | Planned |
| 50 | Arc and Update Manager — a non-Azure machine, same policy set | Planned |
| 51 | Compute Fleet and spot, proven by forcing an eviction | Planned |
| 52 | The whole platform — every measured number, and what to redo | Planned |

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
