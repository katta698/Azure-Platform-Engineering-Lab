variable "tenant_id" {
  description = "Microsoft Entra tenant ID."
  type        = string
  sensitive   = true
}

variable "subscription_id" {
  description = "Subscription this week deploys its test bed into (sub-lab-dev)."
  type        = string
  sensitive   = true
}

variable "root_management_group_id" {
  description = <<-EOT
    Management group the policy definition and initiative are DEFINED at.
    A definition can only be assigned at or below where it is defined, so this
    sits at the intermediate root: usable by every tier, invisible outside the lab.
  EOT
  type        = string
  default     = "/providers/Microsoft.Management/managementGroups/mg-katta"
}

variable "lz_dev_management_group_id" {
  description = "Management group the dev assignment targets."
  type        = string
  default     = "/providers/Microsoft.Management/managementGroups/mg-lz-dev"
}

variable "platform_management_group_id" {
  description = "Management group the platform assignment targets."
  type        = string
  default     = "/providers/Microsoft.Management/managementGroups/mg-platform"
}

variable "location" {
  description = <<-EOT
    Region for the test bed, and the location of the assignment's managed
    identity. A policy assignment with an identity requires a location even
    though the assignment itself is not a regional resource — the identity is.
  EOT
  type        = string
  default     = "southcentralus"
}

variable "allowed_locations" {
  description = <<-EOT
    Regions the allowed-locations policy permits.

    northcentralus is included because it is southcentralus's Azure-designated
    pair, and the resilience weeks deploy there. Leaving it out means week 41
    starts by fighting a policy this week created.
  EOT
  type        = list(string)
  default     = ["southcentralus", "northcentralus"]
}

variable "enforce_policy" {
  description = <<-EOT
    false → enforcement_mode DoNotEnforce and the public IP rule set to Audit.
            The assignment evaluates and reports, but blocks nothing.
    true  → enforcement_mode Default and the rule set to Deny.

    Two stages on purpose. Introducing a deny to an environment you have not yet
    measured is how a guardrail causes the outage it was meant to prevent. Run
    false, read the compliance report, then run true.
  EOT
  type        = bool
  default     = false
}
