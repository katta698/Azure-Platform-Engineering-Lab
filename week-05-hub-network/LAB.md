# Lab Guide — Week 05: The hub network

**How to reproduce this lab.** The [blog post](https://jayanthkatta.com/blog/week-05-hub-network/)
explains what it does and why; this guide is the runbook. The
[README](README.md) carries the cost note and the design reasoning.

**Status:** deployed and validated. The firewall ran 19:48–21:35 UTC and was
removed; **measured cost $0.72**. One caveat stated plainly below: the
*hardened* version of `cleanup.sh` has not itself been run end to end.

> ### ⚠ This is the one week that bills while you are not looking
>
> Azure Firewall Basic is **$0.405/hour** from the moment it provisions, and
> it does not stop because you walked away. `deploy_firewall` defaults to
> **false**, so a plain apply builds the free layer and nothing else. Turn it
> on deliberately, and set a budget alert first.

---

## 1. Prerequisites

### Accounts and permissions

| Requirement | Why |
| --- | --- |
| **Two** Azure subscriptions — hub (`sub-connectivity`) and spoke (`sub-lab-dev`) | the split is the point: hub and spoke can be owned by different teams on different lifecycles |
| **Contributor** on both | no role assignments are created, so User Access Administrator is **not** needed |
| A budget alert you actually receive | the only week here with a meter that runs while idle |
| HCP Terraform account, organization and project | remote state, **local execution** |

One subscription works if you point both variables at it. You lose the thing
the week demonstrates, which is fine for a first run.

### Tools

| Tool | Version | Note |
| --- | --- | --- |
| Terraform | **>= 1.10.0** | pinned in `terraform/versions.tf` |
| `hashicorp/azurerm` | **~> 5.2** | **two provider aliases**, each with an explicit `subscription_id` |
| Azure CLI | 2.60+ | `az network firewall` lives in an **extension** — see §7 |

### Resource providers

```
Microsoft.Network
```

### Address space

Hub `10.0.0.0/16`, spoke `10.1.0.0/16` by default. **They must never
overlap** — peering refuses to create if they do, and it refuses at *apply*
time rather than at plan time, so you find out late.

### Prior weeks

**None required.** Week 01's hierarchy explains where the subscriptions come
from, but this week stands alone.

---

## 2. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform.tfvars` is gitignored.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `tenant_id` | **yes** | — | Entra tenant |
| `connectivity_subscription_id` | **yes** | — | where the hub and DNS estate live |
| `spoke_subscription_id` | **yes** | — | where the spoke lives |
| `location` | no | `southcentralus` | one region on purpose — peering across regions bills for traffic |
| **`deploy_firewall`** | no | **`false`** | **the cost gate.** `true` starts a $0.405/hour meter |
| `firewall_sku_tier` | no | `Basic` | Basic has no TLS inspection and no IDPS |
| **`deploy_private_dns`** | no | **`false`** | six zones at $0.50/month each; off until a week needs a private endpoint |
| `hub_address_space` | no | `10.0.0.0/16` | must not overlap any spoke, ever |
| `spoke_address_space` | no | `10.1.0.0/16` | — |
| `private_dns_zones` | no | six `privatelink` zones | only created when the flag above is true |

---

## 3. Deploy

**The week deploys in layers, and the layers are a cost boundary:**

```bash
./scripts/deploy.sh hub        # permanent layer. ~$0/hour. Safe to leave
./scripts/validate.sh
./scripts/deploy.sh firewall   # + firewall and route. $0.405/hour. Billing starts
./scripts/validate.sh
```

The permanent layer — VNets, peerings, subnets — costs essentially nothing and
can stay up between sessions. The billable layer is a separate, deliberate
apply.

**The firewall takes most of an hour to provision, and bills the whole time.**
Budget for that before you start, not after.

---

## 4. What it deploys

**22 resources.** The ones that matter:

| Resource | Count | Layer | Job |
| --- | --- | --- | --- |
| Virtual network | 2 | permanent | hub and spoke, in different subscriptions |
| VNet peering | **2** | permanent | **one per side** — a peering is two resources |
| Subnet | 3 | permanent | including the two the firewall requires |
| Private DNS zone + links | 1 + 2 | permanent, gated | only with `deploy_private_dns=true` |
| Azure Firewall | 1 | **billable** | $0.405/hour |
| Public IP | 2 | **billable** | Basic needs **two**, not one |
| Firewall policy | 2 | billable | parent and child, for inheritance |
| Route table + route | 1 + 1 | billable | what makes the firewall load-bearing |

**What Basic quietly requires:** *two* subnets, `AzureFirewallSubnet` and
`AzureFirewallManagementSubnet`, each a `/26`, and *two* public IPs. The
management subnet is not optional on Basic and nothing warns you before the
apply fails.

---

## 5. Validation

```bash
./scripts/validate.sh
```

**5 passed / 0 failed** with the firewall deployed.

| # | Check | Expected |
| --- | --- | --- |
| 1 | both peerings report Connected | both sides `Connected`, not `Initiated` |
| 2 | every private DNS zone links to both VNets | every zone linked twice |
| 3 | firewall subnets named and sized | exact names, `/26` each |
| 4 | the spoke's default route points at the firewall | next hop = firewall private IP |
| 5 | deployed state matches configuration | no drift |

Measured:

| # | Result |
| --- | --- |
| 1 | hub → spoke and spoke → hub, both `Connected` |
| 2 | **6 zones, 12 links** |
| 3 | `AzureFirewallSubnet 10.0.0.0/26`, `AzureFirewallManagementSubnet 10.0.0.64/26` |
| 4 | next hop `10.0.0.4` = firewall `10.0.0.4` |
| 5 | none |

**Without the firewall the same script reports 4 passed and skips check 4.**
That is correct, not a gap: with no firewall there should be no `0.0.0.0/0`
route, and a check that failed here would train you to ignore it.

---

## 6. Cleanup

```bash
./scripts/cleanup.sh           # removes the firewall, keeps the hub
./scripts/cleanup.sh --all     # removes everything, including the hub
```

`cleanup.sh` removes the firewall, both public IPs and both policies by
**re-applying with `deploy_firewall=false`** — not with `destroy -target`,
which would leave the route pointing at an address that no longer answers.
Both are gated on the same variable, so they go in dependency order.

### Verifying

```
Verifying nothing billable survived...
  Clean - no firewall, no public IPs. The permanent layer bills ~nothing.
```

**The public IPs matter more than they look.** A standard static IP left
behind is `$0.005/hour` — trivial per hour and permanent if nobody checks — so
the script requires zero firewalls **and** zero public IPs before reporting
clean.

If the apply fails, the script says so explicitly rather than exiting 0:

```
THE APPLY FAILED. The firewall may still exist and may still be billing.
Check, and delete it directly if so:
  az resource list -g $HUB_RG --subscription <sub> -o table
  az resource delete --ids <firewall-id>
```

> **Honest caveat.** The hardened version of this script — the one that checks
> the apply's exit code and verifies with `az resource list` — has **not been
> run end to end** since it was written. The firewall is down and there is no
> cost exposure, but this teardown is unproven, and the week it was written
> for is exactly the week that proved an unverified teardown can lie.

---

## 7. Troubleshooting

### The teardown failed and the script reported success

- **Problem:** cleanup died with `FirewallPolicyUpdateFailed — Failed with 1
  faulted referenced firewalls`. The firewall stayed up and kept billing, and
  the script **exited 0**.
- **Root cause:** *two* independent failures lined up. Terraform tried to
  update the child policy while the firewall still referenced it, so the
  destroy aborted. And the safety check meant to catch that used
  `az network firewall list`, which needs the `azure-firewall` extension and,
  in a non-interactive shell, dies on the dynamic-install prompt with
  `EOFError: EOF when reading a line`.
- **Resolution:** `az resource delete --ids <firewall>` (no extension needed),
  then re-apply. Eight minutes, and part of the $0.72. The script now checks
  the exit code explicitly and verifies with `az resource list`.
- **Lesson learned:** either failure alone would have been caught by the
  other. **A verification step is itself a dependency, and one that cannot run
  is worse than none — it reports clean.**

### A query that returns null instead of failing

- **Problem:** both firewall subnets reported missing when they existed and
  were correctly sized.
- **Root cause:** `az network vnet subnet show --query addressPrefix` now
  returns **null** — the value moved to `addressPrefixes[]`. The old field is
  still in the response, so the query *succeeds* and returns empty.
- **Resolution:** query `addressPrefixes[0]`.
- **Lesson learned:** an empty result is indistinguishable from "does not
  exist". A renamed field that leaves its old name in place fails silently.

### `azurerm_private_dns_zone_virtual_network_link` rejects two arguments

- **Problem:** validation fails on `resource_group_name` and
  `private_dns_zone_name` together.
- **Root cause:** 5.x takes a single `private_dns_zone_id`.
- **Resolution:** use the 5.x form.
- **Lesson learned:** when every argument fails at once, suspect a major
  version, not a typo.

---

## 8. Known limitations and what production adds

- **Basic SKU has no TLS inspection and no IDPS.** It is the cheapest way to
  prove the routing works and is not a security control you would rely on.
- **No forced tunnelling, no third-party NVA.** The route table sends
  `0.0.0.0/0` to one firewall in one region.
- **Single region.** Peering across regions bills for traffic, which this lab
  avoids by staying in one. A real hub is regional and there are several.
- **The DNS estate is off.** Six zones at $0.50/month each were holding
  nothing but SOA records with zero private endpoints anywhere. The design
  reasoning — zones belong in the hub, because per-spoke zones fail silently —
  is unchanged and still correct; they are simply not created until a week
  needs one.
- **No monitoring on the firewall.** Production sends its logs to week 08's
  workspace and alerts on denies.
- **Local execution.** State is in HCP; runs happen on a workstation.

---

## 9. References

- [Hub-and-spoke network topology](https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke)
- [Azure Firewall Basic](https://learn.microsoft.com/en-us/azure/firewall/basic-features)
- [Azure Firewall subnet requirements](https://learn.microsoft.com/en-us/azure/firewall/firewall-faq)
- [Azure Firewall Manager policy hierarchy](https://learn.microsoft.com/en-us/azure/firewall-manager/policy-hierarchy)
- [Private DNS zones for Private Link](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- Write-up: [jayanthkatta.com/blog/week-05-hub-network](https://jayanthkatta.com/blog/week-05-hub-network/)
