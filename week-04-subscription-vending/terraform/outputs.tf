output "stage" {
  description = "Which stage this state represents, so validate.sh does not have to guess."
  value = (var.vend_new_subscription
    ? "VEND — a new subscription created, placed, budgeted and granted"
  : "CONFIG ONLY — payload vended onto an existing subscription")
}

output "vended_subscription_id" {
  description = <<-EOT
    The GUID of the newly vended subscription, or null when the stage did not
    create one.

    Deliberately the subscription ID and not the module's alias resource ID.
    `azurerm_subscription.id` is the ALIAS resource ID
    (`/providers/Microsoft.Subscription/aliases/<name>`), and passing that
    anywhere expecting a subscription fails with "the segment at position 0
    didn't match".
  EOT
  value       = try(azurerm_subscription.vended[0].subscription_id, null)
}

output "config_target_subscription_id" {
  description = "The existing subscription the configuration-only stage vended onto."
  value       = var.existing_subscription_id
}

output "target_management_group" {
  description = "Where a newly vended subscription was placed. Placement is a separate call from creation."
  value       = var.vend_new_subscription ? var.target_management_group_id : null
}

output "budget_name" {
  description = "Budgets created by vending, keyed by target. Checked against Azure rather than against state."
  value       = { for k, v in local.vend_targets : k => "budget-${var.landing_zone_name}-${k}" }
}
