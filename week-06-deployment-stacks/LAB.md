# Lab Guide — Week 06: Deployment stacks, and a deny that outranks the Owner

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-06-deployment-stacks/)
explains what it does and why; this guide is the runbook. The
[README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated 2026-09-25, then torn down. Every output
below is real.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| An Azure subscription (`sub-lab-dev` here) | both storage accounts land here |
| **A management group you can create a stack in** (`mg-lz-dev` here) | the stack is created at **management group scope**, not subscription scope — this is the prerequisite most likely to stop you |
| **Owner at the management group** | updating or deleting a stack whose deny setting is anything other than `none` needs rights at the stack's scope. *Deployment Stack Contributor* **cannot** do it |
| **Owner on the subscription** | a **test** requirement, not a deployment one — see below |
| HCP Terraform account, organization and project | remote state for the control half, **local execution** |

**Why Owner is a test requirement.** Check 5 asserts that the deletion was
refused for a caller holding **Owner and User Access Administrator**. Run the
validation as a limited principal and the result proves nothing, because a
limited principal would have been refused anyway. The claim only means
something if the caller could otherwise have done it.

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Azure CLI | 2.60+ | needs the `az stack mg` command group |
| Terraform | **>= 1.10.0** | builds **only** the control pair |
| `hashicorp/azurerm` | **~> 5.2** | — |

**There is no Terraform resource for a deployment stack.** The azurerm
provider has `*_template_deployment` resources and nothing for
`Microsoft.Resources/deploymentStacks`; Microsoft's own guidance says to use
the CLI, PowerShell or the portal. That is why this week is the first in the
lab that is not pure Terraform.

### Resource providers

```
Microsoft.Resources   Microsoft.Storage
```

### Prior weeks

**Week 01** for the management group hierarchy the stack is scoped to. Any
management group works — point `STACK_MG` at it.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform.tfvars` is gitignored.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | where both halves deploy |
| `control_storage_account_name` | **yes** | — | the unprotected account; must be globally unique |
| `location` | no | `southcentralus` | region for both resource groups |

The management group is set in `scripts/deploy.sh` as `STACK_MG`.

---

## 3. Deploy

```bash
./scripts/deploy.sh      # Terraform for the control, az stack mg create for the protected
```

The stack command, which is the week in one block:

```bash
az stack mg create \
  --name stack-wk06-protected \
  --management-group-id mg-lz-dev \
  --location southcentralus \
  --deployment-subscription "$SUB" \
  --template-file stack/protected.json \
  --parameters storageAccountName="$PROTECTED_SA" \
  --action-on-unmanage deleteAll \
  --deny-settings-mode denyWriteAndDelete \
  --yes
```

`deploy.sh` runs **`az stack mg validate` before `az stack mg create`**,
because a stack that fails midway still exists — and a half-failed stack
*with deny settings on* is harder to remove than one that never started.

---

## 4. What it deploys

| Resource | Count | Built by | Job |
| --- | --- | --- | --- |
| Resource group (control) | 1 | Terraform | holds the unprotected account |
| Storage account (control) | 1 | Terraform | the control for the experiment |
| Resource group (protected) | 1 | the stack | holds the protected account |
| Storage account (protected) | 1 | the stack | the treatment |
| Deny assignment | 1 | Azure, on the stack's behalf | what actually refuses the delete |

The two storage accounts are **deliberately identical** — same SKU, kind and
replication — so the only variable in the experiment is which one a stack
owns.

---

## 5. Validation

```bash
./scripts/validate.sh    # tries BOTH deletes and reports which one Azure refused
```

**Measured 5 passed / 0 failed on 2026-09-25.**

A successful deploy proves a stack exists with deny settings on. It proves
nothing about whether the deny stops anybody — so **check 3 genuinely deletes
a storage account**. A test that only ever attempts the delete it expects to
fail proves nothing about whether deletes work at all.

| # | Check | Expected |
| --- | --- | --- |
| 1 | the stack exists and reports managed resources | a stack at the management group, mode `denyWriteAndDelete` |
| 2 | managed resources report a deny status | every managed resource carries the deny |
| 3 | deleting the **control** account | **succeeds** |
| 4 | deleting the **protected** account | **refused** |
| 5 | the refusal applied to an Owner | caller holds `Owner`, refused anyway |

```
3. Deleting the CONTROL storage account succeeds
   RESULT: deleted - an ordinary account, deletable by an Owner

4. Deleting the PROTECTED storage account is refused
   RESULT: REFUSED by the stack's deny assignment
     DenyAssignmentAuthorizationFailed) The client '<signed-in user>' with
     object id '<oid>' has permission to perform action
     'Microsoft.Storage/storageAccounts/delete' ...

5. The refusal applied to an Owner, not a limited principal
   caller roles on the subscription: Owner User Access Administrator
   RESULT: the caller holds Owner and was still refused

── 5 passed, 0 failed ──
```

**Read check 4's error text again.** Azure is not saying the caller lacks
permission — it says the caller **has** it. The deny assignment is evaluated
after the role grant and overrides it. That sentence is the whole week.

**Re-running the validation requires a redeploy.** Check 3 really does delete
the control account.

---

## 6. Cleanup

The protected resources **cannot be deleted directly**. That is the entire
point, and it means teardown is not the usual `terraform destroy`:

```bash
./scripts/cleanup.sh
```

which runs, in order:

```bash
az stack mg delete --name stack-wk06-protected \
  --management-group-id mg-lz-dev \
  --action-on-unmanage deleteAll --yes
# then terraform destroy for the control half
```

**`deleteAll` is not optional.** The documented default is *detach*: stacks
detach and do not delete unmanaged resources. Omit the flag and the stack goes
away, the deny assignment goes with it, and **every resource it was protecting
keeps running — unowned, untracked, still billing — while the command exits 0
and tells you nothing is wrong.** On this week that costs nothing. On a week
with a firewall in it, that is the bill that arrives a month later.

### Three documented ways the delete can fail

- **Permission.** Deleting a stack whose deny setting is not `none` needs
  rights at the stack's scope. *Deployment Stack Contributor* cannot; Owner at
  the management group can.
- **Stack out of sync.** The delete is refused rather than risk removing
  something unexpected. The bypass flag is deliberately **not** used — it
  deletes whatever the managed list happens to contain, which is the exact
  situation the error exists to prevent.
- **A resource group holding unmanaged resources** is not removed, and neither
  are those resources.

### Verifying

```
Destroying the control...
Verifying nothing survived...
  Clean - both resource groups are gone.
```

`cleanup.sh` checks the delete's exit code explicitly and then **verifies
against Azure** that both resource groups are gone, rather than trusting a
zero exit. That is a direct correction from week 05, where a teardown reported
success while an Azure Firewall kept billing.

**Still charging afterwards:** nothing. Both accounts are empty and deleted.

---

## 7. Troubleshooting

### Validation says "run deploy.sh first" after a successful deploy

- **Problem:** *"Could not resolve both storage accounts. Run deploy.sh
  first."* against a deploy that succeeded ninety seconds earlier.
- **Root cause:** `deploy.sh` wrote `.protected-storage-account` at the week
  root; `validate.sh` read it from `scripts/`.
- **Resolution:** resolve the marker path from the script's own location in
  both scripts, never from the working directory.
- **Lesson learned:** the message pointed confidently at the wrong cause.
  "Run deploy.sh first" is a *guess* the script makes when a file is absent,
  and a guess in an error message gets read as a diagnosis.

### `unrecognized arguments: --yes`

- **Problem:** `az stack mg validate` rejects `--yes`.
- **Root cause:** `az stack mg create` accepts it; `validate` does not.
- **Resolution:** drop the flag from the validate call.
- **Lesson learned:** a shared command prefix is not a shared argument list.

### `Could not find member '//' on object of type 'Template'`

- **Problem:** ARM rejects the usual JSON comment convention.
- **Root cause:** ARM templates have no comments, and a top-level `"//"` key
  is not a schema member.
- **Resolution:** put commentary in `metadata`, which is real.
- **Lesson learned:** a convention from one JSON dialect does not carry into a
  schema-validated one.

### There is no portal page for the stack

- **Problem:** looking for a portal view of a management-group-scoped stack
  returns *"This feature isn't implemented at this time."*
- **Root cause:** stacks at subscription and resource group scope render in
  the portal; management group scope did not, as of 25 September 2026.
- **Resolution:** operate from the CLI, and take change-review evidence from
  `az stack mg show` and the deny assignments blade.
- **Lesson learned:** worth knowing *before* standardising on
  management-group-scoped stacks — there is no stack page to link in a change
  record.

---

## 8. Known limitations and what production adds

- **`denyWriteAndDelete` is not read-protection.** It stops writes and
  deletes; it does not stop reads, and it does not stop a data-plane
  operation inside a resource.
- **The deny applies to all principals with no exclusions.** Production
  usually excludes a break-glass principal or the pipeline's own identity, so
  legitimate automation is not locked out alongside everyone else.
- **One stack, one template.** A real estate scopes stacks per workload or per
  environment and has to decide what happens to resources that move between
  them.
- **No portal UI at management group scope**, so change-review evidence is
  CLI output rather than a link.
- **The lab runs the validation as Owner on purpose.** That is the opposite of
  a production habit; it is required here only to make the refusal meaningful.

---

## 9. References

- [Deployment stacks](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks)
- [Protect managed resources against deletion](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks#protect-managed-resources-against-deletion)
- [Understand Azure deny assignments](https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments)
- [`az stack mg`](https://learn.microsoft.com/en-us/cli/azure/stack/mg)
- Write-up: [jayanthkatta.com/blog/week-06-deployment-stacks](https://jayanthkatta.com/blog/week-06-deployment-stacks/)
