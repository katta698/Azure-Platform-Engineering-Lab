locals {
  tags = {
    week       = "13"
    env        = "dev"
    managed-by = "terraform"
  }
}

resource "azurerm_resource_group" "diag" {
  name     = "rg-diagnostics-lab-dev-scus-001"
  location = var.location
  tags     = local.tags
}

# The destination. daily_quota_gb is the cost bound for the whole week.
resource "azurerm_log_analytics_workspace" "diag" {
  name                = "law-wk13-dev-scus-001"
  resource_group_name = azurerm_resource_group.diag.name
  location            = azurerm_resource_group.diag.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = var.daily_quota_gb
  tags                = local.tags
}
