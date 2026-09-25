variable "tenant_id" {
  description = "Entra tenant. Read from `az account show`; never committed."
  type        = string
}

variable "subscription_id" {
  description = "`sub-lab-dev` — where both the control and the protected resources land."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "southcentralus"
}

variable "control_storage_account_name" {
  description = <<-EOT
    Name of the UNPROTECTED storage account.

    Passed in rather than derived so that `validate.sh` can attempt to delete it
    by name without re-deriving a hash, and so the control and the protected
    account are named the same way apart from the word that distinguishes them.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.control_storage_account_name))
    error_message = "Storage account names are 3-24 lowercase alphanumerics."
  }
}
