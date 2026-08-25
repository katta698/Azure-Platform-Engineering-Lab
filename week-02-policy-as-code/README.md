# Week 02 — Policy as code

Week 01 proved a `deny`. A deny governs the next deployment and nothing else —
it is a gate, and gates do not fix what is already inside. This week is the
other half: policy that reaches into an estate that already exists and changes
it, which means a managed identity, which means a role assignment, which is
where this stops being about policy and starts being about access.

## Cost note

**Under $1.** Policy definitions, assignments, compliance evaluation and
remediation tasks are free at any scale. The test bed is a Log Analytics
workspace and two Standard LRS storage accounts, up for a few hours: the
workspace ingests a few MB of storage metrics against a 5 GB/month free
allocation, and the storage accounts hold nothing. Retention is left at the
30-day free floor, because retention beyond it is the part of Log Analytics
that bills.

`scripts/cleanup.sh` removes everything, including the three role assignments
at management group scope that survive deletion of the resource group. See
**Teardown**.

## What gets built

| | |
| --- | --- |
| `deployIfNotExists` definition | `dine-storage-diagnostics-to-law` — any storage account without a diagnostic setting pointing at the lab workspace gets one deployed |
| `modify` definition | `modify-inherit-tag-from-rg` — resources inherit `cost-center` from their resource group |
| Initiative | `initiative-lab-remediation`, both rules, defined at `mg-katta` |
| Assignment | `assign-remediation-dev` at `mg-lz-dev`, carrying a user-assigned identity |
| Identity | `id-wk02-policy-remediation`, granted three roles at `mg-lz-dev` |
| Test bed | `rg-wk02-policy-as-code-dev-scus-001` — a workspace and two deliberately non-compliant storage accounts |

## The design decision: user-assigned, not system-assigned

A policy assignment holds exactly one managed identity either way, so this is
not a question of how many. It is a question of ordering.

A **system-assigned** identity does not exist until the assignment that owns it
exists. Its principal ID cannot be known before then, so the role assignment can
only be created afterwards — and Azure begins evaluating the assignment the
moment it is created. The window between "the assignment exists" and "its
identity can do anything" is real, and every remediation that starts inside it
fails. It is also fragile across changes: replace the assignment and every grant
attached to the old principal is orphaned, pointing at an object ID that no
longer resolves.

A **user-assigned** identity inverts that. Create the identity, grant it, then
hand it to the assignment:

```hcl
resource "azurerm_user_assigned_identity" "remediation" { ... }

resource "azurerm_role_assignment" "remediation" {
  for_each     = var.grant_remediation_roles ? local.roles : {}
  scope        = var.lz_dev_management_group_id
  principal_id = azurerm_user_assigned_identity.remediation.principal_id
}

resource "azurerm_management_group_policy_assignment" "dev" {
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.remediation.id]
  }
  depends_on = [azurerm_role_assignment.remediation]
}
```

The `depends_on` is not decoration. Terraform sees the assignment reference the
identity, not the grants, so without it the assignment is free to be created
first — reintroducing exactly the race that user-assigned was chosen to remove.

## Three roles, and why one of them is not Contributor

The identity holds three grants at `mg-lz-dev` — the same scope the initiative
is assigned at, so the identity can reach everything the assignment governs and
nothing else:

| Role | For |
| --- | --- |
| Monitoring Contributor | Writing the diagnostic setting on the storage account |
| Log Analytics Contributor | Writing to the workspace that setting points at |
| Tag Contributor | Writing the inherited tag |

The first two are not interchangeable: one grants the write on the source, the
other on the destination, and dropping either produces a remediation that fails
on the half you did not grant.

The third is the interesting one. Azure ships a built-in that does exactly what
`modify-inherit-tag-from-rg` does — `Inherit a tag from the resource group if
missing`, `ea3f2387-9b95-492a-a190-fcdc54f7b070` — and its `roleDefinitionIds`
names **Contributor**. Assigning the built-in therefore means granting
Contributor over every subscription under `mg-lz-dev`, permanently, in order to
write a tag.

The definition is what decides how much power the identity needs, and an
assignment cannot grant less than the definition demands. So this week writes
its own copy of the rule, identical except for one line:

```json
"roleDefinitionIds": [
  "/providers/Microsoft.Authorization/roleDefinitions/4a9ae827-6dc8-4573-8ac7-8239d42aa03f"
]
```

Tag Contributor. Write tags, nothing else. That is the entire reason the custom
definition exists, and it is the kind of choice that is only available at the
definition.

## Three stages

```
./scripts/deploy.sh audit       auditIfNotExists, tag rule Disabled, no grants
./scripts/deploy.sh no-grants   deployIfNotExists — with an identity holding nothing
./scripts/deploy.sh remediate   the same, with the three grants in place
```

The middle stage is run on purpose and is expected to fail. It is the most
common real failure of `deployIfNotExists`, and the error it produces does not
mention the missing role assignment.

## What was measured

*Filled in from the deployed runs — see the sections below.*

## Teardown

Three kinds of thing were created and only one of them dies with the resource
group:

- **In the group** — the workspace, the storage accounts, the identity, and the
  diagnostic settings the policy itself deployed
- **On the tree** — the two definitions, the initiative, the assignment
- **On the tree** — three role assignments granted to the identity

The role assignments are the ones to watch. Deleting the resource group deletes
the managed identity, but the grants at `mg-lz-dev` survive it: role assignments
naming a principal ID that no longer resolves, which the portal renders as
"Identity not found". They look harmless and they accumulate — every re-run of
this week leaves three more. `scripts/cleanup.sh` deletes the group, destroys
everything on the tree, and then checks by principal ID that no grant survived.
