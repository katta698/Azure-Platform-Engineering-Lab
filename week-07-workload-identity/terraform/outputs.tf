# These three go into GitHub as repository VARIABLES, not secrets.
#
# They are identifiers, not credentials: knowing them grants nothing without a
# token from the exact repo and branch named in the federated credential. That
# distinction is the week - a repo with three variables and zero secrets.
output "client_id" {
  value       = azurerm_user_assigned_identity.ci.client_id
  description = "AZURE_CLIENT_ID"
}

output "tenant_id" {
  value       = var.tenant_id
  description = "AZURE_TENANT_ID"
}

output "subscription_id" {
  value       = var.subscription_id
  description = "AZURE_SUBSCRIPTION_ID"
}

output "federated_subject" {
  value       = azurerm_federated_identity_credential.main_branch.subject
  description = "Exactly what a token must claim to be accepted."
}
