# Four resources chosen to produce three different outcomes under one
# initiative. The matrix is the week's result, not an accident:
#
#   key vault        audit: yes  -> remediated
#   public ip        audit: yes  -> remediated
#   network security group  audit: NO, allLogs yes
#                                -> untouched under audit, by design
#   storage account  no built-in policy for the type at all
#                                -> never remediated at any category group

resource "azurerm_key_vault" "target" {
  name                = "kv-wk13-dev-scus-001"
  resource_group_name = azurerm_resource_group.diag.name
  location            = azurerm_resource_group.diag.location
  tenant_id           = var.tenant_id

  # Standard, not premium and not an HSM. The hourly Key Vault meters in the
  # price API belong to Azure Dedicated HSM and Key Vault HSM Pool; a standard
  # vault bills per 10,000 operations.
  sku_name = "standard"

  # RBAC rather than access policies: required by azurerm 5.x, and the only
  # model consistent with the rest of this lab.
  rbac_authorization_enabled = true

  tags = local.tags
}

# The vault exists to emit audit logs, so something has to touch it. Secrets
# Officer on the deployer is what makes the validation step possible.
resource "azurerm_role_assignment" "kv_writer" {
  scope                = azurerm_key_vault.target.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

data "azurerm_client_config" "current" {}

resource "azurerm_public_ip" "target" {
  name                = "pip-wk13-dev-scus-001"
  resource_group_name = azurerm_resource_group.diag.name
  location            = azurerm_resource_group.diag.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_security_group" "target" {
  name                = "nsg-wk13-dev-scus-001"
  resource_group_name = azurerm_resource_group.diag.name
  location            = azurerm_resource_group.diag.location
  tags                = local.tags
}

resource "azurerm_storage_account" "target" {
  name                     = "stwk13devscus001"
  resource_group_name      = azurerm_resource_group.diag.name
  location                 = azurerm_resource_group.diag.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.tags
}
