variable "tenant_id" {
  description = "Microsoft Entra tenant ID."
  type        = string
  sensitive   = true
}

variable "subscription_id" {
  description = "Subscription the consumers deploy into (sub-lab-dev)."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Region for the resource group and everything in it."
  type        = string
  default     = "southcentralus"
}

variable "enable_v2_consumer" {
  description = <<-EOT
    false → only the consumer pinned to storage-baseline 1.0.0 exists
    true  → a second consumer on 2.0.0 is added alongside it

    The two stages exist to make one measurement: what the plan says about the
    v1 consumer at the moment a breaking major version is introduced into the
    same configuration and the same state file. The answer should be nothing,
    and "should" is not evidence.

    Note what this variable does NOT do. It does not change either consumer's
    version — a module's `version` argument must be a literal, so no flag, no
    variable and no workspace setting can move a pin. Upgrading is a code
    change and a commit, always, which is the property that makes a pin worth
    anything.
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Log Analytics retention. 30 days is the free floor; beyond it, retention is what bills."
  type        = number
  default     = 30
}
