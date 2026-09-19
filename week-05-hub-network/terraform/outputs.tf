output "layer" {
  description = "Which layer this state currently holds — the permanent one, or that plus the billable firewall."
  value = (var.deploy_firewall
    ? "HUB + FIREWALL — billing at ~$0.405/hour while this is true"
  : "HUB ONLY — permanent layer, ~$0/hour")
}

output "hub_vnet_id" {
  description = "Hub VNet. Later weeks peer to this."
  value       = azurerm_virtual_network.hub.id
}

output "spoke_vnet_id" {
  description = "Spoke VNet in the landing zone subscription."
  value       = azurerm_virtual_network.spoke.id
}

output "private_dns_zones" {
  description = "The estate, by key. Later weeks put private endpoints into these rather than creating their own."
  value       = { for k, z in azurerm_private_dns_zone.estate : k => z.name }
}

output "firewall_private_ip" {
  description = <<-EOT
    The firewall's private address — the next hop the spoke's default route
    points at. Null when the firewall is not deployed, which is also why the
    route itself is conditional: a 0.0.0.0/0 route to a next hop that does not
    exist blackholes the subnet rather than failing loudly.
  EOT
  value       = try(azurerm_firewall.hub[0].ip_configuration[0].private_ip_address, null)
}

output "firewall_public_ip" {
  description = "The firewall's outbound SNAT address, when deployed."
  value       = try(azurerm_public_ip.firewall_data[0].ip_address, null)
}
