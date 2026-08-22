// Management group IDs contain only names chosen in this repo, so they are safe
// to print. Anything containing a subscription, tenant or client GUID is marked
// sensitive — those are account identifiers and must not reach a terminal
// transcript, a CI log, or a screenshot.

output "management_group_ids" {
  description = "The management group tree, keyed by short name."
  value       = local.management_groups
}

output "root_management_group_name" {
  description = "Intermediate root. Every later week assigns policy at or below this."
  value       = azurerm_management_group.root.name
}

output "terraform_client_id" {
  description = "Client ID of the CI app registration. Set as ARM_CLIENT_ID in each workspace."
  value       = azuread_application.terraform.client_id
  sensitive   = true
}

output "terraform_principal_object_id" {
  description = "Object ID of the CI service principal, for role assignments in later weeks."
  value       = azuread_service_principal.terraform.object_id
  sensitive   = true
}

output "federated_credential_subjects" {
  description = <<-EOT
    The exact subject strings Entra will accept. If a workspace fails to
    authenticate, compare its token subject against this list before changing
    anything else — a mismatched project name or run phase is the usual cause
    and it fails with a generic AADSTS70021.
  EOT
  value = {
    for key, credential in local.federated_credentials :
    key => "organization:${var.hcp_organization}:project:${var.hcp_project}:workspace:${credential.workspace}:run_phase:${credential.phase}"
  }
}

output "federated_credentials_used" {
  description = "Federated identity credentials consumed of the 20 Entra allows per application."
  value       = "${length(local.federated_credentials)} of 20"
}

output "subscription_ids" {
  description = "Subscriptions created through the alias API. Empty until create_subscriptions is true."
  value       = { for key, subscription in azurerm_subscription.lab : key => subscription.subscription_id }
  sensitive   = true
}

output "next_steps" {
  description = "What bootstrap deliberately does not do."
  value = join("\n", [
    "1. Set ARM_CLIENT_ID, ARM_TENANT_ID and ARM_SUBSCRIPTION_ID as environment variables on each HCP workspace, plus TFC_AZURE_PROVIDER_AUTH = true. Never a client secret.",
    "2. Run scripts/revoke-legacy-sp-access.sh to strip standing access from: ${join(", ", var.legacy_service_principal_names)}",
    "3. Delete those app registrations one week later, once nothing has broken.",
    "4. Flip create_subscriptions to true and apply again to test the MCA alias API.",
  ])
}
