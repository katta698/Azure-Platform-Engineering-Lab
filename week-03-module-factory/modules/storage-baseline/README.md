# storage-baseline

The lab's storage account. A thin wrapper over
[`Azure/avm-res-storage-storageaccount/azurerm`](https://registry.terraform.io/modules/Azure/avm-res-storage-storageaccount/azurerm)
that decides the arguments a platform team should not be deciding twice.

Published to the private registry as
`app.terraform.io/Katta/storage-baseline/azurerm`.

## Usage

```hcl
module "storage" {
  source  = "app.terraform.io/Katta/storage-baseline/azurerm"
  version = "2.0.0"

  workload                   = "orders"
  environment                = "dev"
  location                   = "southcentralus"
  resource_group_id          = azurerm_resource_group.example.id
  cost_center                = "platform-lab"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.example.id
}
```

## What it decides for you

| Setting | Value | Why it is not an input |
| --- | --- | --- |
| Name | `st<workload><env><6-char hash>` | Storage account names are globally unique and allow no punctuation. Callers get this wrong, and the failure looks like an access error |
| `min_tls_version` | `TLS1_2` | Nothing in this lab speaks anything older |
| `allow_nested_items_to_be_public` | `false` | Anonymous blob access is a deliberate act, not a default |
| `https_traffic_only_enabled` | `true` | — |
| Replication | `LRS` | Cheapest, and this lab has no cross-region durability requirement to justify anything else |
| Tags | `env`, `cost-center`, `managed-by`, `module` | `cost-center` is what the estate's tagging policy enforces. A resource this module made is compliant on creation, so remediation never touches it |

`public_network_access_enabled` is `true`, and that is the one baseline setting
that is not where it should be. The alternative is a private endpoint, which
without a linked private DNS zone resolves to the public IP — a failure that
presents as a firewall problem. The zone estate is week 05's; this module moves
when it exists.

## Diagnostics take one input and produce two settings

A storage account emits no logs. It emits the `Transaction` metric, and the
read/write/delete audit events belong to the blob *service* — a separate ARM
resource at `.../blobServices/default` with its own diagnostic setting. Asking
for `allLogs` on the account is accepted and yields nothing.

Pass `log_analytics_workspace_id` and both settings are created: `Transaction`
metrics on the account, `audit` logs on the blob service. `audit` rather than
`allLogs`, because `allLogs` on an account under real traffic is the largest
ingestion line most labs create by accident.

## Versions

| Version | Change |
| --- | --- |
| 1.0.0 | First release. `log_analytics_workspace_id` optional, `shared_access_key_enabled` defaults to `true` |
| 2.0.0 | **Breaking.** `log_analytics_workspace_id` is required. `shared_access_key_enabled` defaults to `false` |

1.0.0 is still in the registry and still installable. It was not corrected in
place, because a published version is immutable and that property is worth more
than the two defects in it.

### Upgrading to 2.0.0

| | Change | How it reaches you |
| --- | --- | --- |
| Loud | `log_analytics_workspace_id` now required | `Missing required argument`, at plan. Nothing deploys |
| Silent | `shared_access_key_enabled` `true` → `false` | No plan error, no apply error. Whatever authenticated with a shared key stops working at runtime |

Pass a workspace ID, and decide explicitly about shared keys before applying —
`shared_access_key_enabled = true` is still available and is now a choice in
your code rather than a default you inherited.

The silent one is what makes major versions worth the trouble. A constraint like
`~> 1.0` would have caught neither, because both changes are in a new major —
and a team that writes `~> 2.0` after upgrading has re-armed it for 2.1.0.

## Provider requirements

There is no `azurerm` in this module. AVM's Terraform specification requires
every control-plane resource to be created through the **AzAPI** provider, so
the storage account, its container and both diagnostic settings are `azapi`
resources. The `azurerm` in the registry address is a namespace label, not a
dependency.

`enable_telemetry` defaults to `false` here, against AVM's own default of
`true`. The payload is a module ID and a version, so this is not a privacy
position: it is that telemetry makes an outbound HTTP call during `plan`, and a
module's defaults should not add a network dependency to an operation the
caller expected to be local.
