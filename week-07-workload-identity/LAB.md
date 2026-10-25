# Lab Guide — Week 07: A CI identity with no secret to steal

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-07-workload-identity/)
explains what it does and why; this guide is the runbook. The
[README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated 2026-09-29, then torn down. Every output
below is real.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| An Azure subscription | holds the identity, the credential and the role assignment |
| **Contributor** on it | creates the resource group and the identity |
| **User Access Administrator** (or Owner) on it | the lab creates a `Reader` role assignment, which Contributor cannot do |
| **A GitHub repository you can add a workflow to** | the federated credential is pinned to one org, repo **and branch** — know all three before deploying |
| HCP Terraform account, organization and project | remote state, **local execution** mode |

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | 5.x changed `azurerm_federated_identity_credential` — see §7 |
| Azure CLI | 2.60+ | provider registration and the validation checks |
| **GitHub CLI (`gh`)**, authenticated | **required** | the subject claim must be *read from GitHub*, never constructed by hand |

### Resource providers

`deploy.sh` registers one:

```
Microsoft.ManagedIdentity
```

### Prior weeks

**None.** This week is depended on rather than depending — it is the identity
later weeks would run their CI under.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform.tfvars` is gitignored.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | where the identity is created and scoped |
| `github_org` | **yes** | — | the org or user that owns the repo the token comes from |
| `github_repo` | **yes** | — | repository name |
| `github_subject_prefix` | **yes** | — | **do not invent this** — `deploy.sh` reads it from GitHub |
| `location` | no | `southcentralus` | region for the resource group |

Point `versions.tf`'s `cloud {}` block at your own HCP organization, project
and workspace name, and **set the workspace to local execution** before the
first run.

---

## 3. Deploy

```bash
./scripts/deploy.sh      # reads the subject prefix from GitHub, then applies
```

**4 resources** on a clean apply. The script prints three identifiers:

```
AZURE_CLIENT_ID  AZURE_TENANT_ID  AZURE_SUBSCRIPTION_ID
```

They go into GitHub as repository **variables** — Settings → Secrets and
variables → Actions → *Variables*. Variables, not secrets. They are
identifiers; knowing them grants nothing without a token GitHub will only mint
for this repo on this branch. **A repo with three variables and zero secrets is
the week in one screen.**

The workflow also needs `permissions: id-token: write`, or GitHub never mints
a token at all — and the resulting error points at Azure rather than at the
workflow.

---

## 4. What it deploys

| Resource | Count | Job |
| --- | --- | --- |
| Resource group | 1 | what dies together at teardown |
| User-assigned managed identity | 1 | the principal CI authenticates as |
| Federated credential | 1 | the trust: issuer, audience and an exact subject |
| Reader role assignment | 1 | **at subscription scope** — see the limitation in §8 |

**User-assigned is forced, not chosen.** Federation does not work with a
system-assigned identity, because there is no Azure resource here to own one —
the workload runs on GitHub's infrastructure.

---

## 5. Validation

```bash
./scripts/validate.sh    # 5 checks against the live identity
```

**Measured 5 passed / 0 failed on 2026-09-29.**

A successful `terraform apply` proves four resources exist. It proves nothing
about whether GitHub can authenticate with them, which is the whole claim —
so the workflow run below is part of the validation, not a decoration.

| # | Check | Expected |
| --- | --- | --- |
| 1 | the managed identity exists | present, client ID resolves |
| 2 | exactly one federated credential, correctly configured | count **1**, issuer `token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange` |
| 3 | the subject names this repo and branch exactly | matches the subject GitHub actually presents |
| 4 | there is no secret to steal | **0** password credentials on the service principal |
| 5 | the role is Reader, and only Reader | `Reader` alone |

```
1. The managed identity exists
   RESULT: present, client ID resolved

2. Exactly one federated credential, correctly configured
   count=1  issuer=https://token.actions.githubusercontent.com
   audience=api://AzureADTokenExchange
   RESULT: one credential, GitHub as issuer, Entra token exchange as audience

3. The subject names this repo and branch exactly
   RESULT: matches repo:katta698@.../Azure-Platform-Engineering-Lab@...:ref:refs/heads/main

4. There is no secret to steal
   password credentials on the identity's service principal: 0
   RESULT: none - authentication is a federated token, minted per run

5. The role is Reader, and only Reader
   roles: Reader
   RESULT: Reader alone - it can look, and cannot change anything

── 5 passed, 0 failed ──
```

**Check 4 is the claim.** A managed identity *cannot* hold a password — the
API has nowhere to put one. In an app registration, "no secret" is a discipline
somebody has to keep rather than a property of the object.

### On a real runner

The workflow completed in **19 seconds**:

```
client id  : f8bfdca3-...          <- a variable, not a secret
secrets    : none configured for this repo

── who am I ──
Subscription    Tenant
sub-lab-dev     29a908ac-...

── what can I see ──
rg-wk07-identity-dev-scus-001

── what I cannot do (Reader, deliberately) ──
refused, as designed - this identity reads and nothing more
```

The workflow **asserts its own limit** rather than assuming it: it attempts a
resource group create and fails the build if that *succeeds*.

---

## 6. Cleanup

```bash
./scripts/cleanup.sh
```

Everything belongs to Terraform, so `destroy` removes the lot. The script then
checks Azure directly rather than trusting an exit code:

```
Verifying nothing survived...
  Clean - the resource group is gone.
  Orphaned Reader assignments with an unresolvable principal: 0
```

That last line matters. Deleting an identity does **not** delete the role
assignments pointing at it; they linger as entries with an unresolvable
principal. Expect `0`.

**Preserved:** nothing — this week owns everything it created.
**Still charging afterwards:** nothing. None of it billed in the first place.

**Also revoke by hand:** the three repository variables in GitHub. They grant
nothing once the identity is gone, but leaving them is leaving a dangling
reference for the next person to puzzle over.

---

## 7. Troubleshooting

### The first run fails at login, not at apply

- **Problem:** Terraform applies cleanly, then the workflow fails with
  `AADSTS700213: No matching federated identity record found for presented
  assertion subject`.
- **Root cause:** GitHub defaults to **immutable subject claims** — the owner
  and repository each carry a numeric ID. A credential built from the
  documented `repo:owner/repo` form applies cleanly and matches nothing a
  runner presents.
- **Resolution:** read the subject from GitHub rather than constructing it:
  ```bash
  gh api repos/{owner}/{repo}/actions/oidc/customization/sub --jq '.sub_claim_prefix'
  ```
  `deploy.sh` does this for you.
- **Lesson learned:** a trust relationship has two ends and only one is in
  your Terraform. The half you did not write is the half to go and read.

### `az: executable file not found in $PATH`

- **Problem:** the plan fails with what looks like a broken local PATH.
- **Root cause:** a **new HCP workspace defaults to remote execution**. The
  plan ran on HCP's servers, where there is no Azure CLI and no credentials
  either.
- **Resolution:** set the workspace to **local execution**. It applies first
  time afterwards.
- **Lesson learned:** an error naming a local tool does not prove the failure
  is local. Check *where* the command ran before debugging the machine in
  front of you.

### Every argument on the credential is rejected at once

- **Problem:** `azurerm_federated_identity_credential` rejects
  `resource_group_name` and `parent_id`.
- **Root cause:** azurerm 5.x takes a single `user_assigned_identity_id` where
  4.x took both.
- **Resolution:** use the 5.x form.
- **Lesson learned:** when *every* argument fails simultaneously, suspect a
  major-version change rather than a typo. Any example predating the 5.0
  release is wrong here.

---

## 8. Known limitations and what production adds

- **Reader is granted at SUBSCRIPTION scope.** The workflow only reads one
  resource group, so this is broader than the lab needs. Narrow it to the
  resource group, or to whatever the pipeline genuinely touches.
- **One branch, one repo.** The credential is pinned to `refs/heads/main`.
  Production usually needs several — a credential per environment, pinned to
  tags or to a GitHub environment rather than a branch.
- **No approval gate.** A branch-pinned credential means anyone who can merge
  to `main` can act as this identity. Production pairs federation with a
  protected GitHub environment and required reviewers.
- **Reader is the lab's ceiling, not a template.** A pipeline that deploys
  needs write access; the discipline to copy is asserting the limit in the
  workflow, not the particular role.
- **Local execution.** State is in HCP but runs happen on a workstation. The
  whole point of this week is the identity that would let CI run them instead.

---

## 9. References

- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a federated identity credential on a user-assigned managed identity](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
- [GitHub: about security hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [GitHub: customizing the OIDC subject claim](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-cloud-providers#customizing-the-token-claims)
- [Terraform `azurerm_federated_identity_credential`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential)
- Write-up: [jayanthkatta.com/blog/week-07-workload-identity](https://jayanthkatta.com/blog/week-07-workload-identity/)
