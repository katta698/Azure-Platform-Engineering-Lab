# Lab Guide — Week 04: Subscription vending

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-04-subscription-vending/)
explains what it does and why; this guide is the runbook. The
[README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated — **7 passed, 0 failed** after the `vend`
stage — then decommissioned. Every output below is real.

> ### ⚠ This week can create a subscription, and a subscription cannot be deleted
>
> Cancelling stops billing immediately, but the Delete option does not appear
> for **three days** and Azure removes it automatically only after **ninety**.
> `vend_new_subscription` defaults to **false**, and `./scripts/deploy.sh`
> defaults to the `config` stage, which vends onto a subscription that already
> exists. The destructive stage is the one you have to ask for.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| A **Microsoft Customer Agreement** billing account | the Subscription Alias API bills the new subscription to it |
| Its **billing profile** and **invoice section** names | required variables with no defaults |
| **Rights to create subscriptions on that invoice section** | a *billing* permission, separate from Entra and Azure RBAC — being tenant Owner does not grant it |
| **User Access Administrator** (or Owner) | the lab creates a role assignment at subscription scope |
| Write access to the management group hierarchy | the subscription has to be placed somewhere |
| HCP Terraform account, organization and project | remote state, **local execution** |

The three billing identifiers go in `terraform.tfvars`, which is gitignored,
and never into a `.tf` file.

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | **blocks Microsoft's own vending module** — see §7 |
| Azure CLI | 2.60+ | provider registration and the validation queries |

### Resource providers

```
Microsoft.Consumption   Microsoft.CostManagement
```

### A limit you cannot configure round

**DevTest is not available on an individual billing account.** The alias call
refuses it:

```
Code="NotAllowed" Message="Can't create DevTest Azure plans for individual
billing account. Please contact Azure Support."  code: "InvalidSku"
```

So `subscription_workload` is `Production` here whether or not that is what a
lab wants.

### Prior weeks

**Week 01** for the management group hierarchy — specifically
`mg-decommissioned`, which carries the enforcing deny-all this week finally
proves. Any equivalent hierarchy works.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | the existing subscription the `config` stage vends onto |
| `billing_account_name` | **yes** | — | MCA billing account |
| `billing_profile_name` | **yes** | — | MCA billing profile |
| `invoice_section_name` | **yes** | — | what the new subscription bills to |
| **`vend_new_subscription`** | no | **`false`** | **the one-way gate.** `true` creates a real subscription |
| `landing_zone_name` | no | `lz-vend-demo` | the vended subscription's display name |
| `location` | no | `southcentralus` | region for anything regional |

---

## 3. Deploy

```bash
./scripts/deploy.sh config    # vend onto an existing subscription — repeatable
./scripts/deploy.sh vend      # create a subscription too — one-way
```

**`config` is the default, and that default is deliberate: the destructive
stage should be the one you have to ask for.** It vends steps 2–4 onto a
subscription that already exists, which is both the safe rehearsal *and* the
realistic case — a mature estate vends onto existing subscriptions far more
often than it creates new ones.

The payload is defined once and shared by both stages, so "what does a landing
zone get" has a single answer that cannot drift between the rehearsal and the
real thing.

---

## 4. What it deploys

**Vending is four operations across three APIs**, and nothing does all four —
which is why the module market exists:

| Operation | API | Resource |
| --- | --- | --- |
| Create | Subscription Alias | `azurerm_subscription` |
| Place | Management Groups | `azurerm_management_group_subscription_association` |
| Grant | Azure RBAC | `azurerm_role_assignment` |
| Cap | Cost Management | `azurerm_consumption_budget_subscription` |

---

## 5. Validation

```bash
./scripts/validate.sh
```

**7 passed, 0 failed** after the `vend` stage.

A successful apply proves an alias call returned. It does not prove the
subscription landed in the right management group, that the budget attached,
or that the grant sits at the subscription rather than being inherited.

| # | Check | Expected | Actual |
| --- | --- | --- | --- |
| 1 | a budget on every vended target | a budget on each | **`25.0` on both** |
| 2 | the landing-zone grant at subscription scope | *at* the subscription, not inherited | **1 Reader on each, at the subscription itself** |
| 3 | placement, from the management group's side | the group lists it | **`mg-lz-dev` lists the vended subscription** |
| 4 | placement, from the subscription's own side | its parent is that group | **parent = `/providers/Microsoft.Management/managementGroups/mg-lz-dev`** |
| 5 | drift | none | **none** |

**Checks 3 and 4 ask the same question from both ends on purpose.** A
management group listing a child and a subscription naming its parent are
stored separately, and a vending run that half-finishes can satisfy one
without the other.

### The deny-all, finally proven

`mg-decommissioned` has carried an enforcing deny-all since the bootstrap and
had never denied anything — the scope held no subscription, so there was
nothing to attempt. It was the one control in this lab asserted rather than
demonstrated. With a subscription in scope:

```
(RequestDisallowedByPolicy) Resource 'rg-decomm-probe-001' was disallowed by
policy. Reasons: 'This subscription is decommissioned and is waiting out its
retention window. Nothing may be created in it. If you need these resources,
move the subscription out of the decommissioned management group first.'
```

The message is the one written into the policy at bootstrap, which is the
point.

---

## 6. Cleanup

**Two kinds of thing, and only one of them goes.**

- **The payload** — budgets and role assignments. Ordinary resources;
  `terraform destroy` removes them. **6 destroyed.**
- **The subscription** — cannot be deleted. Cancelling stops billing
  immediately; the Delete option does not appear for **three days**, and Azure
  removes it automatically only after **ninety**.

So cleanup here means *decommission*: move it out of the landing zone tree
into the group that refuses everything, prove that refusal, then cancel.

```bash
./scripts/cleanup.sh
```

### The order matters, and this script had it wrong first time

`terraform destroy` on `azurerm_subscription` **cancels the subscription** —
it does not merely drop it from state. The alias destroy took 1m39s, and
afterwards ARM refused every write:

```
(ReadOnlyDisabledSubscription) The subscription ... is disabled and therefore
marked as read only.
```

A deny-all probe run *after* that never reaches policy evaluation. It is
refused for being cancelled, which proves nothing about the policy — and the
explicit cancel then fails too, with
`NotAllowed — "Subscription is not in active state"`.

**`cleanup.sh` now moves and probes first, and destroys last.**

The probe's guard is worth keeping: it distinguishes a policy denial from any
other failure and refuses to claim success for the wrong error. **A check that
reports "denied" because the request failed for an unrelated reason is worse
than no check.**

**Still charging afterwards:** nothing. A cancelled subscription bills
nothing, but it remains visible in the tenant for up to ninety days.

---

## 7. Troubleshooting

### Microsoft's own vending module cannot be used

- **Problem:** `terraform init` refuses to resolve at all —
  `no available releases match the given constraints ~> 4.0, ~> 5.2`.
- **Root cause:** `Azure/lz-vending/azurerm`'s `role_definitions` and
  `cached_data` submodules require `azurerm ~> 4.0`; this lab standardised on
  `~> 5.2`. No overlap. Version 7.0.3, newest of its 37 releases, predates
  azurerm 5.
- **Resolution:** write the four resources directly.
- **Lesson learned:** a version pin is a compatibility claim about the whole
  dependency tree, not a preference.

### `Can't create DevTest Azure plans for individual billing account`

- **Problem:** the alias call refuses the cheaper DevTest rate.
- **Root cause:** DevTest is not offered on an individual billing account.
- **Resolution:** `subscription_workload = "Production"`, now a validated
  variable rather than a literal buried in the resource.
- **Lesson learned:** billing-account type constrains what the API will
  accept, independently of any permission you hold.

### The decommission probe proves nothing

- **Problem:** the deny-all probe is refused, but for the wrong reason.
- **Root cause:** the subscription was already cancelled, so ARM rejects every
  write before policy is evaluated.
- **Resolution:** move and probe **before** destroying.
- **Lesson learned:** a refusal is only evidence if you know which layer
  refused.

---

## 8. Known limitations and what production adds

- **The payload is one Reader grant and one budget.** A real landing zone
  vends networking, logging, policy exemptions and a tagging baseline.
- **No approval workflow.** Production puts vending behind a request and an
  approval, not a flag in a tfvars file.
- **Budgets alert; they do not stop spend.** $25 here is a tripwire, not a
  cap.
- **No naming or quota automation.** Subscription quotas are per billing
  account and are a real constraint at scale.
- **DevTest is unavailable on this billing account**, so the lab pays
  Production rates on everything it vends.

---

## 9. References

- [Subscription vending](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/subscription-vending)
- [Programmatically create Azure subscriptions (MCA)](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/programmatically-create-subscription-microsoft-customer-agreement)
- [Cancel an Azure subscription](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/cancel-azure-subscription)
- [`Azure/lz-vending/azurerm`](https://registry.terraform.io/modules/Azure/lz-vending/azurerm/latest) — the module this week could not use
- Write-up: [jayanthkatta.com/blog/week-04-subscription-vending](https://jayanthkatta.com/blog/week-04-subscription-vending/)
