# Bootstrap

Builds the management group tree, the CI identity, and the subscriptions
everything else sits inside. Runs once. After this, every week is its own
workspace.

State lives in HCP Terraform, organization `Katta`, project
**Azure Platform Lab**, workspace `azure-bootstrap`. Local execution — remote
execution is switched on once the federated credentials this creates are wired
into the workspace.

## What it creates

| | |
| --- | --- |
| Management groups | `mg-katta` and six below it — see `docs/HIERARCHY.md` |
| Subscription placement | Moves the pre-existing subscription under `mg-sandbox` |
| CI identity | `sp-hcp-terraform-lab`, federated credentials only, no secret |
| Role assignments | Contributor + RBAC Administrator + Management Group Contributor, at `mg-katta` |
| Subscriptions | `sub-connectivity`, `sub-management`, `sub-lab-dev` — gated, see below |
| Budgets | One per created subscription, actual at 50% and forecast at 90% |

## Cost note

**Nothing here costs money.** Management groups are free. Subscriptions created
through the alias API are free — a subscription is a billing container, and an
empty one bills nothing. App registrations and federated credentials are free.
Budgets are free.

Teardown is `terraform destroy`, with one caveat that is the whole reason the
hierarchy is shaped the way it is: **destroy will not delete the subscriptions.**
It removes them from state and from their management groups. Cancelling a
subscription is a separate, manual action, and even then Azure retains it. Plan
on the three platform subscriptions being permanent.

## Prerequisites

```bash
az login
terraform login
```

`terraform login` writes its token to `%APPDATA%	erraform.d\credentials.tfrc.json`
on Windows — **not** `~/.terraform.d/`, which is the Linux and macOS location.
Checking the wrong one is how you conclude you are not logged in when you are.

The HCP project **Azure Platform Lab** must exist in the `Katta` organization
before the first init. The `cloud` block creates the *workspace* on first init;
it will not create the project.

## Running it

```bash
cp terraform.tfvars.example terraform.tfvars
# fill in — every command you need is in the comments at the top of that file
terraform init
terraform plan
terraform apply
```

**Apply twice, on purpose.** The first apply leaves `create_subscriptions =
false`, so it builds only the management group tree and the CI identity — the
parts that are certain to work. Confirm those, then flip the flag and apply
again to exercise the Subscription Alias API.

That split existed because the alias API's behaviour on a Microsoft Customer
Agreement **Individual** billing account is the least documented corner of Azure
billing. **Resolved 2026-08-22: it works.** All three subscriptions were created
from Terraform against the invoice section, at no cost.

Two things learned doing it. Subscription creation is **slow** — minutes per
subscription, not seconds, and the apply gives no intermediate output. And an
alias record **outlives the subscription it created**: this tenant carries four
GUID-named aliases pointing at subscriptions that no longer exist. Aliases are
not a reliable inventory of what you have; `az account list` is.

## Wiring a workspace for OIDC

On each HCP workspace, as **environment** variables:

| Variable | Value |
| --- | --- |
| `TFC_AZURE_PROVIDER_AUTH` | `true` |
| `TFC_AZURE_RUN_CLIENT_ID` | the `terraform_client_id` output |
| `ARM_TENANT_ID` | the tenant ID |
| `ARM_SUBSCRIPTION_ID` | the subscription the workspace deploys into |

There is no `ARM_CLIENT_SECRET` row in that table and there will not be one.

## The federated credential ceiling

**Entra allows 20 federated identity credentials per application.** HCP Terraform
issues a distinct token for the plan phase and the apply phase, so each workspace
consumes two. That is **10 workspaces per app registration**, and at one
workspace per week the ceiling arrives around week 9.

`var.hcp_workspaces` is validated at 10 entries so this fails at plan time with a
clear message rather than at apply time with an Entra error.

Three ways out, in the order they should be considered:

1. **Flexible federated identity credentials** — a single credential with a
   claims-matching expression covering every workspace in the project. One
   credential replaces all twenty. This is the right answer if it is generally
   available by the time the ceiling is hit; check before building anything else.
2. **An app registration per tier** — one for platform workspaces, one for lab
   workspaces. Doubles the ceiling and improves the blast radius, since the lab
   identity would not hold rights over connectivity. Costs a second identity to
   maintain.
3. **Retire credentials as weeks complete** — a torn-down week's workspace does
   not need to authenticate any more. Cheapest, but it means the credential list
   is state that has to be maintained, and forgetting to add one back is a
   confusing failure.

A subject mismatch fails with a generic `AADSTS70021` that names nothing useful.
The `federated_credential_subjects` output prints the exact strings Entra will
accept — compare against the token's subject before changing anything else.

## Verifying

Verify against Azure, not against state:

```bash
../../scripts/azure-inventory.sh
terraform plan -detailed-exitcode     # exit 0 means no drift
```

## After bootstrap

```bash
../../scripts/revoke-legacy-sp-access.sh revoke            # report
../../scripts/revoke-legacy-sp-access.sh revoke --apply    # act
```

Then audit properly — the revoke script works from a list of names, and a list
of names is only as good as how it was built:

```bash
../../scripts/access-audit.sh
```

That script starts from `az role assignment list --all` and resolves each
principal backwards. It is the only method that cannot miss an identity.
Building the list the obvious way instead — `az ad app list --show-mine` —
found 5 identities on this tenant when there were 9, because that flag returns
only apps you are a registered *owner* of, and registrations created by portal
wizards, Cloud Shell or deployment templates have no owner at all.
