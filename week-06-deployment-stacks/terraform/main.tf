# ═══════════════════════════════════════════════════════════════════════════
# The control
#
# This week's claim is that a deployment stack can refuse a delete that an
# Owner is otherwise entitled to perform. A claim like that is worth nothing
# without something to compare against, so Terraform builds an ordinary,
# unprotected storage account alongside the protected one.
#
# Same subscription, same region, same SKU, same identity attempting the
# delete. The ONLY difference is that a stack is holding one of them.
#
# The protected half is deliberately not here. It belongs to the stack, and a
# resource with two owners has an ambiguous teardown — which is precisely the
# failure this week is about avoiding.
# ═══════════════════════════════════════════════════════════════════════════

locals {
  common_tags = {
    week        = "06"
    env         = "dev"
    managed-by  = "terraform"
    cost-center = "platform-lab"
  }
}

resource "azurerm_resource_group" "control" {
  name     = "rg-wk06-control-dev-scus-001"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_storage_account" "control" {
  name                = var.control_storage_account_name
  resource_group_name = azurerm_resource_group.control.name
  location            = azurerm_resource_group.control.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Matched to the stack's template on purpose. If the two accounts differed in
  # configuration, "one delete was refused" would have more than one possible
  # explanation.
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  tags = local.common_tags
}
