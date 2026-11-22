output "server_fqdn" {
  value       = azurerm_postgresql_flexible_server.db.fqdn
  description = "The documented hostname. Inside the virtual network it resolves to the private endpoint."
}

output "server_name" {
  value = azurerm_postgresql_flexible_server.db.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.app.name
}

output "db_user" {
  value       = azurerm_user_assigned_identity.app.name
  description = "The PostgreSQL role name is the managed identity's name. There is no password for it to have."
}

output "ha_mode" {
  value       = azurerm_postgresql_flexible_server.db.high_availability[0].mode
  description = "Read back from the server rather than from the variable, because the region may have refused the mode that was asked for."
}
