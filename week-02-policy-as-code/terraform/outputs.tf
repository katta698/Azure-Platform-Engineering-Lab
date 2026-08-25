output "assignment_id" {
  description = "The assignment a remediation task is created against."
  value       = azurerm_management_group_policy_assignment.dev.id
}

output "assignment_scope" {
  description = "Where the initiative is assigned. Outside every resource group, so cleanup has to remove it explicitly."
  value       = var.lz_dev_management_group_id
}

output "definition_ids" {
  description = "The two custom definitions, defined at mg-katta."
  value = {
    storage_diagnostics = azurerm_policy_definition.storage_diagnostics.id
    inherit_tag         = azurerm_policy_definition.inherit_tag.id
  }
}

output "remediation_identity" {
  description = <<-EOT
    The identity remediation runs as, and what it currently holds. An empty
    roles list with stage = REMEDIATING is the deliberate failure case.
  EOT
  value = {
    name         = azurerm_user_assigned_identity.remediation.name
    principal_id = azurerm_user_assigned_identity.remediation.principal_id
    scope        = var.lz_dev_management_group_id
    roles        = var.grant_remediation_roles ? keys(local.roles) : []
  }
}

output "stage" {
  description = "Which stage of the week is deployed."
  value = var.enable_remediation ? (
    var.grant_remediation_roles
    ? "REMEDIATING - deployIfNotExists and modify, identity granted"
    : "REMEDIATING WITHOUT GRANTS - the deliberate failure: the identity is attached but holds nothing"
  ) : "AUDIT ONLY - auditIfNotExists, tag rule disabled, identity attached but idle"
}

output "test_resource_group" {
  description = "Everything except the definitions and the assignment dies with this group."
  value       = azurerm_resource_group.week.name
}

output "log_analytics_workspace_id" {
  description = "The diagnostic destination the policy writes into."
  value       = azurerm_log_analytics_workspace.diagnostics.id
}

output "target_storage_accounts" {
  description = "The storage accounts the policy is expected to fix."
  value       = [for s in azurerm_storage_account.target : s.name]
}
