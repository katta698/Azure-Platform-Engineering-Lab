# Lab Guide — Week 02: Policy as code

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-02-policy-as-code/)
explains what it does and why; this guide is the runbook. The
[README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated 2026-08-25 across all three stages, then
torn down and verified. Every output below is real.

> ### The middle stage is supposed to fail
>
> `./scripts/deploy.sh no-grants` runs `deployIfNotExists` with an identity
> that holds **no role assignments**, and is expected to fail. It is the most
> common real failure of `deployIfNotExists`, and the error it produces does
> not mention the missing role assignment. Skipping it makes stages 1 and 3
> prove much less.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| A management group hierarchy | policy is assigned at a dev landing-zone group |
| **Resource Policy Contributor or Owner on that management group** | writing policy at a scope is not granted by Contributor on the subscription beneath it |
| **User Access Administrator** (or Owner) | stage 3 grants three roles to the remediation identity — **those grants are the experiment** |
| **Contributor** on the subscription holding the test bed | the workspace, storage accounts and identity live there |
| HCP Terraform account, organization and project | remote state, **local execution** |

**The root management group is a deliberate non-default.** A mistake assigned
there reaches everything in the tenant.

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | — |
| Azure CLI | 2.60+ | forcing compliance scans and reading remediation tasks |

### Resource providers

```
Microsoft.PolicyInsights   Microsoft.Storage   Microsoft.OperationalInsights
Microsoft.Insights         Microsoft.ManagedIdentity
```

### Patience is a prerequisite

Policy evaluation is **asynchronous**. The scripts force a scan and wait. A
single query straight after an apply will tell you the policy does not work.

### Prior weeks

**Week 01** for the management group hierarchy. Any equivalent works.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | where the test bed deploys |
| `root_management_group_id` | no | tenant root | where definitions live |
| `lz_dev_management_group_id` | no | `mg-lz-dev` | where the initiative is **assigned** |
| `enable_remediation` | no | `false` | switches the effects from audit to `deployIfNotExists`/`modify` |
| `grant_remediation_roles` | no | `true` | **set false to reproduce stage 2** |
| `inherited_tag_name` | no | `cost-center` | the tag `modify` inherits |
| `cost_center` | no | `platform-lab` | its value, set on the resource group only |
| `log_retention_days` | no | `30` | the free floor |

---

## 3. Deploy — three stages

```bash
./scripts/deploy.sh audit       # auditIfNotExists, tag rule Disabled, no grants
./scripts/deploy.sh no-grants   # deployIfNotExists — identity holding nothing
./scripts/deploy.sh remediate   # the same, with the three grants in place
```

**Nothing changes between stages 2 and 3 except three role assignments.** Same
definitions, same initiative, same assignment, same identity.

---

## 4. What it deploys

| Resource | Count | Where | Job |
| --- | --- | --- | --- |
| Policy definition | 2 | the tree | `storage-diagnostics`, `inherit-tag` |
| Policy set (initiative) | 1 | the tree | groups the two |
| Policy assignment | 1 | `mg-lz-dev` | where the effect takes hold |
| User-assigned identity | 1 | the group | what remediation acts as |
| Role assignment | 3 | the tree | **stage 3 only** |
| Resource group, workspace, storage account | 1, 1, 2 | the group | the test bed |

### Three roles, and why one of them is not Contributor

| Role | For |
| --- | --- |
| Monitoring Contributor | writing the diagnostic setting **on** the storage account |
| Log Analytics Contributor | writing **to** the workspace that setting points at |
| Tag Contributor | writing the inherited tag |

The first two are **not interchangeable**: one grants the write on the source,
the other on the destination, and dropping either produces a remediation that
fails on the half you did not grant.

**The third is the interesting one.** Azure ships a built-in that does exactly
what `modify-inherit-tag-from-rg` does —
`ea3f2387-9b95-492a-a190-fcdc54f7b070` — and its `roleDefinitionIds` names
**Contributor**. Assigning the built-in therefore means granting Contributor
over every subscription under the group, permanently, in order to write a tag.
**The definition decides how much power the identity needs.**

---

## 5. Validation

```bash
./scripts/validate.sh
```

| Stage | Expected | Actual |
| --- | --- | --- |
| 1 — audit | non-compliant, nothing changed | **Non-compliant, 0% (0 of 2)**; `storage-diagnostics` flags 2 accounts; **0 resources changed** |
| 1 — identity | present, **zero grants** | present, no role assignments |
| 2 — no grants | remediation **fails** | fails, as designed |
| 3 — `storage-diagnostics` | both accounts remediated | **2 resources, 2 succeeded, 0 failed** |
| 3 — `inherit-tag` | every in-scope resource tagged | **4 resources, 4 succeeded, 0 failed** |
| 3 — re-scan | compliant | **Compliant, 100% (5 of 5), 0 non-compliant** |

**Read back from the resources, not from the tasks.** A task reporting success
says the task ran:

```
stwk02a…  diag-to-law -> law-wk02-dev-scus-001   cost-center=platform-lab
stwk02b…  diag-to-law -> law-wk02-dev-scus-001   cost-center=platform-lab
law-wk02-dev-scus-001                            cost-center=platform-lab
id-wk02-policy-remediation                       cost-center=platform-lab
```

**`modify` has no audit counterpart.** Its allowed effects are `Modify` and
`Disabled`, so there is no way to preview it the way `auditIfNotExists`
previews a deployment. Stage 1 runs it `Disabled`, and "how many resources are
missing the tag" is only answerable once the rule is switched on.

---

## 6. Cleanup

```bash
./scripts/cleanup.sh
```

**Three kinds of thing were created and only one dies with the resource
group:**

- **In the group** — workspace, storage accounts, identity, and the diagnostic
  settings the policy itself deployed
- **On the tree** — two definitions, the initiative, the assignment
- **On the tree** — three role assignments granted to the identity

**The role assignments are the ones to watch.** Deleting the resource group
deletes the managed identity, but a grant naming a principal ID that no longer
resolves is still a standing role assignment — the portal renders it as
*"Identity not found"*. They look harmless and they accumulate: every re-run of
this week would leave three more. `cleanup.sh` deletes the group, destroys
everything on the tree, then **checks by principal ID that no grant survived**.

### Verifying

Run for real on 2026-08-25: resource group deleted, **7 objects destroyed**
(assignment, initiative, two definitions, three role assignments), verified
against Azure afterwards — the subscription holds only the Azure-managed
`NetworkWatcherRG`, `mg-lz-dev` carries no policy assignment, and the identity
has **0 role assignments anywhere on the tree**.

**One thing survives, deliberately.** Remediation task records outlive the
assignment they ran against:

```bash
az policy remediation list --management-group mg-lz-dev
```

still returns every task from all three stages after teardown. They are history
rather than infrastructure, they cost nothing, and they are the only remaining
evidence of what ran — so `cleanup.sh` **reports** them instead of deleting
them silently.

**Still charging afterwards:** nothing.

---

## 7. Troubleshooting

### Only one of the two failures tells you anything

- **Problem:** both effects fail for the same reason — an identity holding no
  roles — and report it completely differently.
- **Root cause:** `modify` names the missing permission and the principal.
  `deployIfNotExists` says only that the resource identity *"does not have the
  necessary permissions to create deployment `PolicyDeployment_…`"* — not
  which permission, not at which scope, not which role is absent.
- **Resolution:** grant the roles the definition needs.
- **Lesson learned:** the error points at a deployment, so it gets debugged as
  a deployment problem. The fault is a role assignment that was never made.

### `ResourceIdentityRequired` on an audit-only assignment

- **Problem:** assigning the initiative with every effect `AuditIfNotExists`
  or `Disabled` is refused outright.
- **Root cause:** the **definition** decides whether an identity is required,
  not the effect you assign it with.
- **Resolution:** attach the identity at every stage; keep the audit stage
  inert by granting it no roles.
- **Lesson learned:** "it is only auditing, so there is no identity" is false.

### `InvalidCreateRemediationRequest`

- **Problem:** a second remediation request while one is running is refused.
- **Root cause:** remediations are serialised per assignment, per definition
  reference, per scope.
- **Resolution:** queue rather than fan out.
- **Lesson learned:** worth knowing before writing a loop — and if two people
  share a subscription.

### The task reports failure before it reports what failed

- **Problem:** `provisioningState` reaches `Failed` while
  `successfulDeployments` and `failedDeployments` are both still `0`.
- **Root cause:** the counters fill in *after* the terminal state is set.
- **Resolution:** wait for the counters to settle.
- **Lesson learned:** a script that polls for a terminal state and immediately
  reads the counters publishes a number that is wrong for a few seconds and
  wrong forever in your notes.

---

## 8. Known limitations and what production adds

- **Two definitions is a demonstration.** A real estate runs dozens, grouped
  into initiatives per compliance regime.
- **No exemptions.** Production needs a documented exemption process with
  expiry, or policy becomes something people route around.
- **Assigned at one dev group.** Rolling to production scopes needs a staged
  assignment plan and a compliance baseline taken first.
- **No policy testing.** Definitions should be tested against sample resources
  before assignment, not against the live estate.
- **Remediation is manual.** Production triggers it from CI, under week 07's
  federated credential.

---

## 9. References

- [Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects)
- [Remediate non-compliant resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources)
- [Managed identities for remediation](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources#configure-the-managed-identity)
- [Policy definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure)
- Write-up: [jayanthkatta.com/blog/week-02-policy-as-code](https://jayanthkatta.com/blog/week-02-policy-as-code/)
