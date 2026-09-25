output "control_resource_group" {
  description = "The unprotected resource group. Deletable by anyone with rights, which is the point."
  value       = azurerm_resource_group.control.name
}

output "control_storage_account" {
  description = "The unprotected storage account — the baseline the protected one is compared against."
  value       = azurerm_storage_account.control.name
}
