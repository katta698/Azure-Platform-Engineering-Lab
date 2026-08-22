output "policy_definition_id" {
  description = "The custom definition. Later weeks reference this rather than redefining it."
  value       = azurerm_policy_definition.deny_public_ip_on_nic.id
}

output "initiative_id" {
  description = "The baseline initiative."
  value       = azurerm_management_group_policy_set_definition.baseline.id
}

output "assignment_scopes" {
  description = "Where the baseline is assigned. Note these are outside any resource group."
  value = {
    lz_dev   = azurerm_management_group_policy_assignment.lz_dev.id
    platform = azurerm_management_group_policy_assignment.platform.id
  }
}

output "enforcement" {
  description = "Which stage of the week is currently deployed."
  value       = var.enforce_policy ? "ENFORCING - the public IP rule denies" : "REPORT ONLY - evaluating, blocking nothing"
}

output "test_resource_group" {
  description = "Everything except the assignments is deleted with this one group."
  value       = azurerm_resource_group.week.name
}

output "test_subnet_id" {
  description = "Used by validate.sh to attempt the non-compliant deployment."
  value       = azurerm_subnet.test.id
  sensitive   = true
}
