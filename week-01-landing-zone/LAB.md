# Lab Guide — Week 01: The landing zone

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-01-azure-landing-zone/)
explains what it does and why; this guide is the runbook. The
[README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated across both stages, then torn down and
verified. Every output below is real.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| **Permission to create management groups in the tenant** | by default only the Global Administrator can, and the tenant root has to be **elevated once** before Azure RBAC applies there at all — this is the step that stops most people, and it is not a subscription permission |
| **Resource Policy Contributor or Owner** at the target management groups | writing policy at a scope is not granted by Contributor on the subscription beneath it |
| **Contributor** on a subscription for the test bed | where the deny attempts are made |
| HCP Terraform account, organization and project | remote state |

**The workspace must be set to local execution.** A new workspace defaults to
*remote*, and the plan then fails with no Azure credentials. Federated
credentials are only needed once runs move to remote execution — they are not
a prerequisite for this week. (Week 07 builds them.)

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | — |
| Azure CLI | 2.60+ | the deny/allow attempts and forcing compliance scans |

### Resource providers

```
Microsoft.PolicyInsights   Microsoft.Resources
Microsoft.Network          Microsoft.Storage
```

**`Microsoft.PolicyInsights` in particular, and forgetting it is silent** —
compliance data simply never appears, which reads like "nothing is
non-compliant".

### Patience, and a way to force a scan

A **deny is instant**, because policy evaluates on resource write. The
compliance **scan** of resources that already exist is scheduled: roughly
**15 minutes** after a resource changes, **30** after a subscription moves,
and every **24 hours** otherwise.

**An empty compliance report means "not scanned yet", not "compliant".**

```bash
az policy state trigger-scan --resource-group <rg> --subscription <sub>
```

### Prior weeks

**None.** This is the first.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | where the test bed deploys |
| `root_management_group_id` | no | tenant root | where the definition and initiative live |
| `lz_dev_management_group_id` | no | `mg-lz-dev` | the dev assignment's target |
| `platform_management_group_id` | no | `mg-platform` | the platform assignment's target |
| `allowed_locations` | no | two US regions | the allowed-locations rule's parameter |
| **`enforce_policy`** | no | **`false`** | `false` is `DoNotEnforce` — report only |
| `location` | no | `southcentralus` | region for the test bed |

---

## 3. Deploy — in two stages, on purpose

```bash
./scripts/deploy.sh report      # enforce = false — Azure's DoNotEnforce mode
./scripts/validate.sh
./scripts/deploy.sh enforce     # enforce = true
./scripts/validate.sh
```

**Report mode is how a guardrail is introduced to an environment that already
has resources in it:** the assignment evaluates and reports compliance but
blocks nothing, so you find out what *would* have been blocked before anything
actually is.

`validate.sh` **adjusts what it expects to the stage that is deployed**, so a
pass means the policy is behaving correctly *for that stage* — not that
everything was blocked.

---

## 4. What it deploys

| Resource | Count | Where | Job |
| --- | --- | --- | --- |
| Policy definition | 1 | the tree | the custom rule |
| Policy set (initiative) | 1 | the tree | groups the rules |
| Policy assignment | **2** | `mg-lz-dev`, `mg-platform` | where the effect takes hold |
| Resource group | 1 | the subscription | the test bed |
| Virtual network + subnet | 1 + 1 | the subscription | something for a NIC to attach to |

---

## 5. Validation

```bash
./scripts/validate.sh
```

Three real creation attempts, each with its expectation stated before it runs:

| Attempt | Expected (enforce) | Actual |
| --- | --- | --- |
| A NIC carrying a public IP | **denied** | **denied by policy** |
| A storage account in `westeurope` | **denied** | **denied by policy** |
| A NIC with no public IP, in an allowed region | **allowed** | **created** |

In **report** mode all three succeed and the first two show as non-compliant.
In **enforce** mode the first two are rejected with
`RequestDisallowedByPolicy` — and the third still deploys.

**That third case is not padding.** A rule that only ever blocks has been
shown to be *on*, not to be *correct*. Proving the compliant path still works
is the difference between a guardrail and an outage.

### What compliance reported, and the row that lies

After a forced scan:

| Scope | Reported | What it means |
| --- | --- | --- |
| dev | **15% (3 of 20), 17 non-compliant** across 3 policies | real — every violation was created while the assignment was in report mode, and switching to enforcing removed **none** of them |
| platform | **100% (0 of 0)** | an **empty** scope, not a clean one |

Same green tick, opposite meanings. **Enforcement stops the next violation; it
does not fix the last one.**

---

## 6. Cleanup

```bash
./scripts/cleanup.sh
```

**Deleting the resource group is not enough this week.** The assignments, the
initiative and the definition all live at **management group scope** — outside
every resource group, in a part of the hierarchy that resource-group deletion
cannot reach.

Delete the group by hand and the guardrails remain, still evaluating and still
denying, with nothing left in the subscription to explain where they came
from. **An orphaned deny whose source nobody can find is a genuinely nasty
thing to inherit.**

`terraform destroy` removes both because Terraform tracks both, and
`cleanup.sh` **verifies afterwards that the assignment is actually gone**
rather than assuming it.

**Still charging afterwards:** nothing. Management groups, policy and an empty
VNet are all free.

---

## 7. Troubleshooting

### The deny that did not deny

- **Problem:** enforcing mode was on, `enforcementMode: Default`, effect
  `Deny`, allowed-locations list correct — and a storage account in a banned
  region deployed anyway.
- **Root cause:** **the subscription was not underneath the assignment.**
  Created but never placed, it still sat at the Tenant Root Group on a
  different branch. Policy flows downward to whatever is beneath it, and
  nothing was.
- **Resolution:** place the subscription. Creating one and placing it are two
  separate operations — the Subscription Alias API creates it at the tenant
  root, and moving it is a second call.
- **Lesson learned:** **check placement first.** Every field can be right
  while the policy governs an empty branch. The tell was in the portal all
  along — the management group list showed **0 subscriptions** against the
  target. I was reading the assignment instead, because an assignment is easy
  to inspect and looks convincing.

### Thirty-four minutes for one subscription

- **Problem:** three subscriptions requested concurrently produced an apply
  that sat for an hour and committed nothing to state.
- **Root cause:** subscription creation is slow and does not parallelise.
  Requested one at a time, the first took about ten minutes; the second failed
  with `AliasCreate: StatusCode=0 — context deadline exceeded`.
- **Resolution:** request them serially, and expect tens of minutes.
- **Lesson learned:** an apply that commits nothing after an hour is worse
  than one that fails fast.

### `Microsoft.PolicyInsights` is not registered, and nothing says so

- **Problem:** compliance data never appears.
- **Root cause:** the provider is not registered on the subscription.
- **Resolution:** register it; `deploy.sh` does.
- **Lesson learned:** the failure is **silent** and presents as "nothing is
  non-compliant", which is the most reassuring possible way to be wrong.

### The rejection that explained the wrong thing

- **Problem:** a denial names the *initiative*, not the rule inside it that
  actually refused.
- **Root cause:** `RequestDisallowedByPolicy` reports the assignment, and an
  assignment can carry many rules.
- **Resolution:** read the policy definition ID in the error body rather than
  the assignment name in the summary.
- **Lesson learned:** the summary line sends you to the wrong file.

---

## 8. Known limitations and what production adds

- **Two assignments and one custom rule** is a starting hierarchy, not a
  governance baseline. Production starts from a published initiative and adds
  to it.
- **No exemption process.** Policy without a documented, expiring exemption
  route becomes something people route around.
- **Report mode is used once, manually.** Production keeps a soak period per
  assignment and a compliance baseline taken before enforcing.
- **The 17 pre-existing violations were left.** Enforcement does not
  remediate; week 02 is where remediation is built.
- **Local execution.** State is in HCP; runs happen on a workstation.

---

## 9. References

- [Azure landing zone design areas](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-areas)
- [Management group hierarchy](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview)
- [Elevate access to manage all subscriptions and management groups](https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin)
- [Policy evaluation triggers and timing](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data)
- [Policy assignment enforcement mode](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure)
- Write-up: [jayanthkatta.com/blog/week-01-azure-landing-zone](https://jayanthkatta.com/blog/week-01-azure-landing-zone/)
