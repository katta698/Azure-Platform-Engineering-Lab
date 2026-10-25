# Lab Guide — Week 03: A module factory on Azure Verified Modules

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-03-module-factory/)
explains what it does and why; this guide is the runbook. The
[README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated 2026-09-03 — **8 passed, 0 failed** — then
the Azure side was torn down. The two registry versions were **kept on
purpose**; see §6.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| **An HCP Terraform organization with a private module registry** | the week publishes two module versions and consumes them by version — this is the exercise |
| **A token that can publish modules** | publishing is by tag through the registry **API**, not the UI |
| An Azure subscription with **Contributor** | the two consumers deploy here; no role assignments are created, so User Access Administrator is **not** needed |

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | — |
| `Azure/azapi`, `hashicorp/random`, `Azure/modtm` | transitive | they arrive through the Azure Verified Module this week wraps, which is itself the point about dependency trees |
| Azure CLI | 2.60+ | the validation queries |
| `git` | any | `publish.sh` extracts with `git archive`, from the **tag**, not the working tree |

### Resource providers

```
Microsoft.Storage   Microsoft.OperationalInsights   Microsoft.Insights
```

### Windows: move `TF_DATA_DIR` first

AVM nests deeply enough to hit `MAX_PATH`. Set `TF_DATA_DIR` somewhere short
(`C:/tfd/w03`) **before** the first `init` — see §7 for why
`core.longpaths` does not save you.

### Prior weeks

**None.** The Log Analytics workspace here is this week's own, not week 08's.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `subscription_id` | **yes** | — | where the two consumers deploy |
| `location` | no | `southcentralus` | region for the resource group and everything in it |
| `enable_v2_consumer` | no | `false` | adds the second consumer, pinned to 2.0.0 |
| `log_retention_days` | no | `30` | 30 is the free floor; beyond it retention bills |

---

## 3. Deploy

```bash
./scripts/publish.sh 1.0.0     # both versions must exist before either stage runs
./scripts/publish.sh 2.0.0
./scripts/deploy.sh v1         # one consumer, pinned to 1.0.0
./scripts/deploy.sh v2         # a second on 2.0.0, alongside the first
```

**`count = 0` does not mean "not downloaded".** `terraform init` resolves and
installs every module a configuration refers to *before* it evaluates what any
count is, so 2.0.0 has to exist in the registry before stage `v1` can
initialise at all.

**What gets published is the module as it exists at the git tag**, extracted
with `git archive` rather than copied from the working tree — so an uncommitted
edit cannot reach the registry.

---

## 4. What it deploys

| Resource | Count | Job |
| --- | --- | --- |
| Resource group | 1 | what dies together at teardown |
| Log Analytics workspace | 1 | the diagnostic destination 2.0.0 requires |
| Storage account (via module 1.0.0) | 1 | the old consumer |
| Storage account (via module 2.0.0) | 1 | the new consumer |
| Diagnostic settings | 2 | both on the 2.0.0 consumer — account and blob service |

The two consumers pass **identical inputs**. Every difference between them
comes from the module major they are pinned to.

---

## 5. Validation

```bash
./scripts/validate.sh
```

**8 passed, 0 failed** across seven numbered checks.

| # | Check | Expected | Actual |
| --- | --- | --- | --- |
| 1 | both versions published and usable | both resolve | **`1.0.0 ok`, `2.0.0 ok`** |
| 2 | the baseline the module decides | applied to both regardless of version | **both `TLS1_2`**, no public blob access, `cost-center=platform-lab` |
| 3 | the 1.0.0 consumer's diagnostics | none — 1.0.0 let the workspace be omitted | **0** on the account, **0** on the blob service |
| 4 | the 2.0.0 consumer's diagnostics | two, on two resources | **1** account (`Transaction`), **1** blob service (`audit`) |
| 5 | **the silent break** | shared-key access differs | **1.0.0 `True`, 2.0.0 `False`** |
| 6 | **the loud break** | 1.0.0's inputs fail against 2.0.0 before planning | **`Missing required argument`** |
| 7 | drift | none | **none** |

### The property the pin actually buys

The stage-v2 plan, read as JSON rather than eyeballed:

```
module.app_a changes in this plan: 0
```

Four resources created, all `module.app_b`. **That is a claim about a *plan*,**
which is why `deploy.sh` saves the plan and reports on it before applying —
after the apply, the plan is gone.

---

## 6. Cleanup

```bash
./scripts/cleanup.sh              # the Azure side
./scripts/cleanup.sh --registry   # ALSO deletes the two module versions
```

**Two kinds of thing were created and only one of them should go.**

- **The consumers** — resource group, workspace, two storage accounts, four
  diagnostic settings. They cost money and prove nothing further once the
  measurements are taken. **Deleted.**
- **The registry versions** — `storage-baseline` 1.0.0 and 2.0.0. **Kept.**

Keeping them is not laziness. They cost nothing, they are the week's actual
output, and **deleting a published version is the one destructive act a module
registry does not forgive**: every configuration pinned to it stops
initialising, including configurations owned by people who were never asked.
The `--registry` flag exists so that removal is always a deliberate sentence
someone typed.

### Verifying

Run for real on 2026-09-03. `az group list` against the subscription afterwards
returns only `NetworkWatcherRG`, which Azure creates by itself in any
subscription where a virtual network has existed and **is not drift**. The
registry was queried after the destroy: 1.0.0 and 2.0.0 both still present at
status `ok`.

**Still charging afterwards:** nothing.

---

## 7. Troubleshooting

### An empty module published, and every signal said success

- **Problem:** the first publish uploaded a valid 45-byte tarball containing
  nothing. Upload returned `200`, the version reached `ok`, and a consumer
  would have met it as a module with no inputs rather than as a failure.
- **Root cause:** `git archive <tag>:<path>` resolves the path relative to the
  current directory. The script ran from the week directory with a
  repo-root-relative path, so it did not error — it resolved to an *empty
  tree*.
- **Resolution:** count the files in the tarball before uploading. The obvious
  guard does **not** work: `git rev-parse -q --verify "<tag>^{tree}:<path>"`
  still returns a hash for the missed path.
- **Lesson learned:** every status was green because nothing checked content.
  A publish pipeline must assert *what* it published.

### A pending version blocks its own retry

- **Problem:** republishing `1.0.0` was refused — *"already exists, registry
  versions are immutable"*.
- **Root cause:** the failed publish created the version record before it
  broke, leaving it `pending`, awaiting an upload it would never receive.
- **Resolution:** delete the version through the API, then republish.
- **Lesson learned:** safe here only because nothing was pinned to it yet.

### `Filename too long` on Windows

- **Problem:** module download fails — with `core.longpaths=true` set *and*
  `LongPathsEnabled` already `0x1`.
- **Root cause:** AVM pulls `avm-utl-interfaces` once per sub-resource,
  producing paths like
  `.terraform/modules/app_a.storage_account.queues.role_assignments.interfaces/.git/objects/pack/pack-<sha>.pack`.
- **Resolution:** move `TF_DATA_DIR` somewhere short. The module cache is
  relocatable; the repository's location is not.
- **Lesson learned:** when both fixes are already applied and the error
  persists, move the artefact, not the setting.

### A validation that failed on correct resources

- **Problem:** two checks reported failures against perfectly correct
  resources.
- **Root cause:** `az` renders JSON booleans Python-style — `True` and
  `False`, capitalised — and the script compared against lowercase `"false"`.
- **Resolution:** normalise case before comparing.
- **Lesson learned:** the inverse of a check that passes because its lookup
  broke. Both are the check lying about the system.

---

## 8. Known limitations and what production adds

- **Two majors of one module is a demonstration, not a factory.** A real
  factory has many modules, a release process and a deprecation policy.
- **No automated changelog or upgrade guide.** The silent break is exactly the
  kind of change that needs one, and nothing here generates it.
- **No test suite on the module itself.** Production runs `terraform test` or
  Terratest against each version before publishing.
- **Publishing is manual.** It should run in CI from a tag, under week 07's
  federated credential.
- **The AVM dependency is pinned exactly**, which is correct for a lab and
  means security updates to AVM need a deliberate bump.

---

## 9. References

- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
- [HCP Terraform private module registry](https://developer.hashicorp.com/terraform/cloud-docs/registry)
- [Publishing modules via the API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/private-registry/modules)
- [Module version constraints](https://developer.hashicorp.com/terraform/language/expressions/version-constraints)
- Write-up: [jayanthkatta.com/blog/week-03-module-factory](https://jayanthkatta.com/blog/week-03-module-factory/)
