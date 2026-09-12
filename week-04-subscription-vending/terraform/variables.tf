variable "tenant_id" {
  description = "Entra tenant. Read from `az account show`; never committed."
  type        = string
}

variable "subscription_id" {
  description = <<-EOT
    The subscription the PROVIDERS authenticate against — `sub-lab-dev`.

    This is not the subscription being vended. Vending creates a new one, and a
    provider cannot authenticate against a subscription that does not exist yet,
    so the providers point at an existing subscription throughout and the alias
    request is a tenant-level call that happens to be made from it.
  EOT
  type        = string
}

variable "location" {
  description = "Azure region for anything regional the vending creates."
  type        = string
  default     = "southcentralus"
}

# ── The billing scope ───────────────────────────────────────────────────────
#
# Three names, assembled into one resource ID rather than pasted as one, because
# the assembled form is the thing that goes wrong: an invoice section ID with a
# billing profile from a different account is accepted at plan and refused at
# apply, several minutes in.
variable "billing_account_name" {
  description = "MCA billing account name. From the bootstrap's tfvars."
  type        = string
}

variable "billing_profile_name" {
  description = "MCA billing profile name."
  type        = string
}

variable "invoice_section_name" {
  description = "MCA invoice section the vended subscription is billed to."
  type        = string
}

# ── What gets vended ────────────────────────────────────────────────────────

variable "vend_new_subscription" {
  description = <<-EOT
    Stage switch. false vends CONFIGURATION onto an existing subscription; true
    additionally creates a new one through the alias API.

    Defaulted to false on purpose. Creating a subscription is the one action in
    this lab that cannot be undone on the day — a cancelled subscription cannot
    be deleted for three days and is removed automatically only after 90 — so
    the destructive stage is opt-in rather than the default a stray apply hits.
  EOT
  type        = bool
  default     = false
}

variable "landing_zone_name" {
  description = <<-EOT
    Short name of the landing zone being vended. Becomes the subscription alias
    and part of its display name.

    The alias is permanent and cannot be renamed, so it is validated here rather
    than discovered to be wrong once the subscription exists.
  EOT
  type        = string
  default     = "lz-vend-demo"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.landing_zone_name))
    error_message = "landing_zone_name must be 3-40 characters of lowercase letters, digits and hyphens."
  }
}

variable "target_management_group_id" {
  description = <<-EOT
    Management group the vended subscription is placed into.

    Placement is a SEPARATE operation from creation: the Subscription Alias API
    creates every subscription under the Tenant Root Group and does not move it.
    A subscription that was created but never placed inherits no policy and no
    role assignments from the intended tree, and looks completely healthy right
    up until something is supposed to stop you and does not.
  EOT
  type        = string
  default     = "mg-lz-dev"
}

variable "existing_subscription_id" {
  description = <<-EOT
    Subscription the configuration-only stage vends onto. Normally
    `sub-lab-dev`, i.e. the same value as subscription_id.

    This is what makes the week repeatable. Vending the same payload onto an
    existing subscription exercises every part of the pipeline except the alias
    call, and leaves nothing behind that cannot be destroyed.
  EOT
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget, in the billing currency, placed on the vended subscription."
  type        = number
  default     = 25

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount must be greater than zero — a zero budget alerts on creation and teaches nothing."
  }
}

variable "budget_alert_emails" {
  description = "Addresses the budget alerts are sent to. Not committed."
  type        = list(string)
}

variable "role_assignment_principal_id" {
  description = <<-EOT
    Object ID granted a role on the vended subscription — the landing zone's
    owner, in a real pipeline.

    An object ID is an identifier this repo does not publish, so it lives in
    tfvars and the secret sweep checks for it.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.role_assignment_principal_id))
    error_message = "role_assignment_principal_id must be a GUID."
  }
}

variable "role_assignment_definition" {
  description = <<-EOT
    Role granted to that principal at subscription scope.

    Reader by default, deliberately. Vending decides what a landing zone owner
    gets on day one, and the interesting failure is not "they could not deploy",
    it is a pipeline that hands out Owner because that was the example in the
    documentation.
  EOT
  type        = string
  default     = "Reader"
}

variable "budget_start_date" {
  description = <<-EOT
    Start of the budget window, RFC3339 UTC.

    Static rather than derived from `timestamp()`. A window computed at plan
    time changes on every plan, so the budget reports drift forever against a
    resource nobody touched — and a drift check that always fails is a drift
    check nobody reads.
  EOT
  type        = string
  default     = "2026-09-01T00:00:00Z"

  validation {
    condition     = can(formatdate("YYYY-MM-DD", var.budget_start_date))
    error_message = "budget_start_date must be RFC3339, e.g. 2026-09-01T00:00:00Z."
  }
}

variable "budget_end_date" {
  description = "End of the budget window, RFC3339 UTC. Must be after the start."
  type        = string
  default     = "2027-09-01T00:00:00Z"

  validation {
    condition     = can(formatdate("YYYY-MM-DD", var.budget_end_date))
    error_message = "budget_end_date must be RFC3339, e.g. 2027-09-01T00:00:00Z."
  }
}

variable "subscription_workload" {
  description = <<-EOT
    Subscription workload type: Production or DevTest.

    **DevTest is not available on an MCA Individual billing account**, and the
    refusal arrives from the alias API rather than from Terraform:

      Code="NotAllowed" Message="Can't create DevTest Azure plans for
      individual billing account. Please contact Azure Support."
      code: "InvalidSku"

    Measured 2026-09-11 on this account. The word "Sku" in the error code is the
    only hint that the workload argument is the cause — nothing in the message
    names the field, and the request otherwise looks identical to one that
    works. The bootstrap never hit this because it omits `workload` entirely and
    takes the Production default.

    DevTest is the cheaper rate and the obvious choice for a lab, which is
    exactly why it is worth writing down that it is unavailable here.
  EOT
  type        = string
  default     = "Production"

  validation {
    condition     = contains(["Production", "DevTest"], var.subscription_workload)
    error_message = "subscription_workload must be Production or DevTest."
  }
}
