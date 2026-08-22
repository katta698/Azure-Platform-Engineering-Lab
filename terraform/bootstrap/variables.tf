// Every identifier in this file is an account identifier. None of them has a
// default, and none of them may be hardcoded in a .tf file. Values come from
// terraform.tfvars, which is gitignored. See terraform.tfvars.example.

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Also the name of the Tenant Root Group."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "sandbox_subscription_id" {
  description = <<-EOT
    The pre-existing subscription. Bootstrap does not deploy into it — it only
    moves it under mg-sandbox and anchors the azurerm provider to it, because a
    provider block needs a subscription and this is the only one that exists
    before bootstrap runs.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.sandbox_subscription_id))
    error_message = "sandbox_subscription_id must be a GUID."
  }
}

// ── Billing ────────────────────────────────────────────────────────────────
// Together these three form the billing scope that new subscriptions are
// created against. Split into three variables rather than one composite ID so
// the shape stays readable and so a wrong one fails with a useful message.

variable "billing_account_name" {
  description = "MCA billing account name, the long colon-separated identifier."
  type        = string
  sensitive   = true
}

variable "billing_profile_name" {
  description = "MCA billing profile name, e.g. XXXX-XXXX-XXX-XXX."
  type        = string
  sensitive   = true
}

variable "invoice_section_name" {
  description = "MCA invoice section name, e.g. XXXX-XXXX-XXX-XXX. New subscriptions bill here."
  type        = string
  sensitive   = true
}

// ── Placement ──────────────────────────────────────────────────────────────

variable "root_management_group_name" {
  description = <<-EOT
    Name of the intermediate root management group. Nothing is ever assigned at
    Tenant Root Group; this is the anchor everything else hangs from, so the
    blast radius of a policy or role assignment stops at the lab.
  EOT
  type        = string
  default     = "mg-katta"
}

variable "location" {
  description = "Primary region. Its Azure-designated pair is northcentralus."
  type        = string
  default     = "southcentralus"
}

// ── Subscriptions to create ────────────────────────────────────────────────

variable "create_subscriptions" {
  description = <<-EOT
    Whether to create subscriptions through the Subscription Alias API.

    The billing account is Microsoft Customer Agreement (Individual), which
    should make the alias API available — but MCA-Individual is the least
    documented corner of that API and this has not been proven on this account.
    Apply once with this false to get the management group tree and the CI
    identity, then flip it to true and apply again so that a rejection from the
    alias API is an isolated failure rather than one that blocks everything.
  EOT
  type        = bool
  default     = false
}

variable "subscriptions" {
  description = <<-EOT
    Subscriptions to create, keyed by short name. management_group is the key of
    an entry in the management group tree defined in main.tf.

    Deliberately three, not one per week: quota is counted per subscription per
    region, so the permanent platform workloads are kept out of reach of a
    runaway lab week. Weekly isolation is a resource group, because only
    resource-group deletion is atomic and complete — a cancelled subscription is
    retained and cannot be deleted on demand.
  EOT
  type = map(object({
    display_name     = string
    management_group = string
    monthly_budget   = number
  }))

  default = {
    connectivity = {
      display_name     = "sub-connectivity"
      management_group = "connectivity"
      monthly_budget   = 50
    }
    management = {
      display_name     = "sub-management"
      management_group = "management"
      monthly_budget   = 30
    }
    lab_dev = {
      display_name     = "sub-lab-dev"
      management_group = "lz_dev"
      monthly_budget   = 100
    }
  }
}

// ── CI identity ────────────────────────────────────────────────────────────

variable "hcp_organization" {
  description = "HCP Terraform organization. Appears in the federated credential subject."
  type        = string
  default     = "Katta"
}

variable "hcp_project" {
  description = "HCP Terraform project. Appears in the federated credential subject."
  type        = string
  default     = "Azure Platform Lab"
}

variable "hcp_workspaces" {
  description = <<-EOT
    Workspaces that may authenticate as the CI service principal. Each one costs
    TWO federated credentials, because HCP Terraform issues a different token for
    the plan phase and the apply phase.

    Entra allows a maximum of 20 federated identity credentials per application,
    so this list cannot exceed 10 entries. That ceiling is reached around week 9
    and is a real design constraint, not a formality — see README.md for the
    three ways out.
  EOT
  type        = list(string)
  default     = ["azure-bootstrap"]

  validation {
    condition     = length(var.hcp_workspaces) <= 10
    error_message = "Entra allows 20 federated identity credentials per app, and each workspace needs 2 (plan and apply). Max 10 workspaces per app registration."
  }
}

variable "budget_alert_emails" {
  description = "Addresses that receive Cost Management budget alerts."
  type        = list(string)
  sensitive   = true
}

variable "legacy_service_principal_names" {
  description = <<-EOT
    App registrations that predate this lab and hold standing write access.
    Bootstrap does not touch them — scripts/revoke-legacy-sp-access.sh strips
    their role assignments, because Terraform cannot destroy an assignment it
    never created without importing it first, and importing something in order
    to delete it is a worse audit trail than a script that logs what it removed.

    Listed here so the set is recorded in one place and so outputs can remind
    whoever runs bootstrap that the script still needs running.
  EOT
  type        = list(string)

  // All five hold Contributor on the subscription — confirmed 2026-08-22 by
  // running the revoke script in report mode. The azure-cli-* three are
  // abandoned device-code logins and were initially assumed harmless; they are
  // not, and they are the easiest to overlook because nobody created them
  // deliberately.
  default = [
    "TerraformTesting",
    "jayanthkatta_sp",
    "azure-cli-2023-01-27-03-38-22",
    "azure-cli-2023-02-10-01-38-41",
    "azure-cli-2023-02-15-16-08-57",
  ]
}

variable "budget_start_date" {
  description = <<-EOT
    First day of the month the budget starts, RFC3339. Static on purpose: a
    computed timestamp() would change on every plan and produce a permanent
    diff. Azure rejects a start date more than three months in the past.
  EOT
  type        = string
  default     = "2026-09-01T00:00:00Z"
}
