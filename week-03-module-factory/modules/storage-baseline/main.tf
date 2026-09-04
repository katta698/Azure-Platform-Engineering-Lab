# ═══════════════════════════════════════════════════════════════════════════
# storage-baseline — the lab's storage account
#
# This module creates nothing itself. Every resource it produces is created by
# Azure/avm-res-storage-storageaccount/azurerm, and that is the point: AVM is
# maintained by the people who own the resource provider, and re-implementing
# it would be taking on the maintenance of a thing that is already maintained.
#
# What it adds is everything AVM deliberately does not have an opinion about.
# AVM ships a correct storage account; a platform team needs THEIR storage
# account, which is the same resource with the arguments already decided. The
# difference between those two is this file, and it is short on purpose — a
# wrapper that grows past its wrapped module has stopped being a wrapper.
#
# Concretely, a caller gets four things they would otherwise get wrong:
#
#   1. a name that is valid, unique and derivable, from a workload word
#   2. transport and public-access settings already at the lab's baseline
#   3. the cost-center tag the week 02 policy enforces, so the estate's own
#      remediation never has to touch anything this module made
#   4. diagnostics wired to a workspace by passing one ID, not by knowing that
#      account metrics and blob logs are two different diagnostic settings
# ═══════════════════════════════════════════════════════════════════════════

locals {
  # A storage account name is globally unique across every tenant in Azure, so
  # a name built only from workload and environment collides with a stranger's
  # account and fails at apply with an error that reads like a permissions
  # problem. The hash is over the resource group ID, which contains the
  # subscription GUID — stable across applies, different per subscription, and
  # already known at plan time. Deriving it beats the random provider, whose
  # entire job would be to keep a value in state that is a pure function of an
  # input that is already in state.
  suffix = substr(sha1(var.resource_group_id), 0, 6)

  # st + workload(<=13) + env(3) + hash(6) = at most 24, which is the cap. The
  # validation on var.workload is what keeps that true; the substr here is a
  # guard, not the mechanism, because a name silently truncated to fit is a
  # name that collides with its neighbour.
  account_name = substr("st${var.workload}${var.environment}${local.suffix}", 0, 24)

  tags = merge(
    {
      env         = var.environment
      cost-center = var.cost_center
      managed-by  = "terraform"
      module      = "storage-baseline"
    },
    var.tags,
  )

  # One workspace ID in, two diagnostic settings out.
  #
  # A storage account emits no logs of its own — only the Transaction metric.
  # The read, write and delete audit events belong to the blob SERVICE, which is
  # a separate ARM resource (.../blobServices/default) and therefore takes its
  # own diagnostic setting. Sending "allLogs" at the account level is accepted
  # and produces nothing, which is the failure that gets discovered during an
  # incident rather than during a deploy.
  #
  # The category group is `audit` rather than `allLogs` deliberately: allLogs on
  # a busy account is the single largest ingestion line a lab ever accidentally
  # creates, and audit carries the events anyone actually goes looking for.
  diagnostics_enabled = var.log_analytics_workspace_id != null

  account_diagnostics = local.diagnostics_enabled ? {
    to_law = {
      name                  = "diag-to-law"
      workspace_resource_id = var.log_analytics_workspace_id
      metrics               = [{ category = "Transaction" }]
    }
  } : {}

  blob_diagnostics = local.diagnostics_enabled ? {
    to_law = {
      name                  = "diag-blob-to-law"
      workspace_resource_id = var.log_analytics_workspace_id
      logs                  = [{ category_group = "audit" }]
    }
  } : {}
}

module "storage_account" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.10.0"

  # An exact pin, not a range, and that is a different decision from the one a
  # consumer of THIS module makes. A wrapper's job is to be the stable thing:
  # if it floated on `~> 0.10` then a caller pinned to storage-baseline 1.0.0
  # could still have their storage account change under them, which is the
  # opposite of what pinning the wrapper was supposed to buy. Moving to 0.11.0
  # is a commit here and a version bump of this module.
  #
  # AVM is pre-1.0. Under semver a 0.x minor bump is allowed to break, so
  # `~> 0.10` would be a range across breaking changes, not a range of patches.
  location  = var.location
  name      = local.account_name
  parent_id = var.resource_group_id

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # The baseline. Each of these is a default this module exists to have already
  # made, rather than a setting a caller is trusted to remember:
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  shared_access_key_enabled       = var.shared_access_key_enabled

  # public_network_access_enabled is the honest exception. It is true because
  # the alternative is a private endpoint, and a private endpoint without a
  # linked private DNS zone resolves to the public IP and fails closed in a way
  # that looks like a firewall problem. The zone estate is week 05; until it
  # exists, this module would be shipping a default that cannot work.

  containers = {
    data = {
      name          = var.container_name
      public_access = "None"
    }
  }

  diagnostic_settings_storage_account = local.account_diagnostics
  diagnostic_settings_blob            = local.blob_diagnostics

  enable_telemetry = var.enable_telemetry
  tags             = local.tags
}
