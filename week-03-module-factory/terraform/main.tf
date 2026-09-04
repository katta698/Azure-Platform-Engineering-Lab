# ═══════════════════════════════════════════════════════════════════════════
# The consumers
#
# Two calls to the same module at two major versions, in one configuration and
# one state file. That arrangement is the week: it is the situation a platform
# team is in permanently — a module they own, several consumers, and no
# authority to make everyone upgrade on the same day.
#
# The module is sourced from the private registry rather than from
# ../modules/storage-baseline, and the difference is not cosmetic. A relative
# path has no version: it is whatever is in the working tree, so every consumer
# is on HEAD whether they wanted to be or not, and "which version is app-a
# running" has no answer. Going through the registry is what makes the pin
# below mean something.
# ═══════════════════════════════════════════════════════════════════════════

locals {
  common_tags = {
    week       = "03"
    env        = "dev"
    managed-by = "terraform"
  }
}

resource "azurerm_resource_group" "week" {
  name     = "rg-wk03-module-factory-dev-scus-001"
  location = var.location

  # cost-center is set here as well as passed into each module. The resource
  # group needs it in its own right — week 02's modify rule inherits this tag
  # DOWN from the group, and a group without it has nothing to inherit.
  tags = merge(local.common_tags, { cost-center = "platform-lab" })
}

resource "azurerm_log_analytics_workspace" "diagnostics" {
  name                = "law-wk03-dev-scus-001"
  resource_group_name = azurerm_resource_group.week.name
  location            = azurerm_resource_group.week.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  tags = merge(local.common_tags, { cost-center = "platform-lab" })
}

# ── Consumer A — pinned to 1.0.0, and left alone ────────────────────────────
#
# This is the consumer that must not move. It was written against 1.0.0, it
# passes no workspace because 1.0.0 allowed that, and it never changes for the
# rest of the week. Everything measured here is measured against this block
# staying exactly as it is while the world around it moves.
module "app_a" {
  source  = "app.terraform.io/Katta/storage-baseline/azurerm"
  version = "1.0.0"

  workload          = "appa"
  environment       = "dev"
  location          = var.location
  resource_group_id = azurerm_resource_group.week.id
  cost_center       = "platform-lab"
  container_name    = "app-a-data"
  tags              = local.common_tags

  # No log_analytics_workspace_id, and no shared_access_key_enabled. Both are
  # doing work by being absent: in 1.0.0 the first is optional and the second
  # defaults to true, and 2.0.0 changes both. This block is the evidence of
  # what the defaults were on the day it was written.
}

# ── Consumer B — 2.0.0, added later ─────────────────────────────────────────
#
# An exact pin rather than `~> 2.0`, for the same reason the wrapper pins AVM
# exactly. `~> 2.0` accepts 2.1.0 and 2.7.3 — versions that do not exist yet
# and whose contents nobody has read. The constraint is not the safety
# mechanism; the review of the diff is, and a range is a standing agreement to
# skip it.
module "app_b" {
  source  = "app.terraform.io/Katta/storage-baseline/azurerm"
  version = "2.0.0"

  count = var.enable_v2_consumer ? 1 : 0

  workload          = "appb"
  environment       = "dev"
  location          = var.location
  resource_group_id = azurerm_resource_group.week.id
  cost_center       = "platform-lab"
  container_name    = "app-b-data"
  tags              = local.common_tags

  # Required in 2.0.0. Omitting it is an error at plan time, which is exactly
  # what the upgrade check in validate.sh runs against the app_a inputs.
  log_analytics_workspace_id = azurerm_log_analytics_workspace.diagnostics.id
}

# count = 0 does not mean "not downloaded". terraform init resolves and
# installs every module a configuration REFERS to, before it knows or cares
# what any count evaluates to. So 2.0.0 has to exist in the registry before the
# first stage can be initialised at all, which is why publish.sh publishes both
# versions ahead of either deploy.
