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
    Management group the definitions and the initiative are DEFINED at.
    A definition can only be assigned at or below where it is defined.
  EOT
  type        = string
  default     = "/providers/Microsoft.Management/managementGroups/mg-katta"
}

variable "lz_dev_management_group_id" {
  description = <<-EOT
    Management group the initiative is ASSIGNED at, and the scope the
    remediation identity is granted its roles at.

    These two are the same scope on purpose. An identity granted at a wider
    scope than the assignment can remediate resources the assignment does not
    govern; granted at a narrower one, remediation fails on everything outside
    the grant with an error that names permissions rather than scope.
  EOT
  type        = string
  default     = "/providers/Microsoft.Management/managementGroups/mg-lz-dev"
}

variable "location" {
  description = <<-EOT
    Region for the test bed, and the location of the policy assignment.
    An assignment carrying an identity requires a location even though the
    assignment is not itself a regional resource — the identity is.
  EOT
  type        = string
  default     = "southcentralus"
}

variable "enable_remediation" {
  description = <<-EOT
    false → the initiative evaluates with AuditIfNotExists and the tag rule
            Disabled. Nothing is deployed or modified.
    true  → DeployIfNotExists and Modify. The same assignment now acts.

    The identity is attached either way — Azure requires one on any assignment
    whose definitions contain a deployment, regardless of the effect selected.
    What separates the stages is the effect, and what separates a harmless
    identity from a powerful one is grant_remediation_roles below.

    The two stages are the whole shape of the week. Stage 1 tells you how much
    is non-compliant before anything is changed on your behalf; stage 2 changes
    it. Going straight to stage 2 means the first time you learn the blast
    radius is while it is already deploying.
  EOT
  type        = bool
  default     = false
}

variable "grant_remediation_roles" {
  description = <<-EOT
    Whether the remediation identity gets its role assignments.

    Set false on purpose to see what a remediation task does when the identity
    has no permissions. It is the most common real failure of deployIfNotExists
    and the error names the deployment, not the missing grant. Week 02 runs
    that deliberately once, captures it, then sets this back to true.
  EOT
  type        = bool
  default     = true
}

variable "diagnostic_setting_name" {
  description = <<-EOT
    Name of the diagnostic setting the policy deploys, and the name its
    existence check looks for.

    These must be the same string. The existence check is scoped to a
    diagnostic setting of this name — deploy under one name and check for
    another and the policy redeploys on every evaluation, reporting
    non-compliant forever while creating a new setting each time.
  EOT
  type        = string
  default     = "diag-to-law"
}

variable "inherited_tag_name" {
  description = <<-EOT
    Tag the modify rule copies down from the resource group.

    cost-center rather than managed-by: this is a tag whose correct value is a
    property of where the resource lives, which is exactly the case inheritance
    suits. managed-by is a property of how the resource was created and is set
    by the thing that created it.
  EOT
  type        = string
  default     = "cost-center"
}

variable "cost_center" {
  description = "Value of the inherited tag, set on the resource group only."
  type        = string
  default     = "platform-lab"
}

variable "log_retention_days" {
  description = <<-EOT
    Log Analytics retention. 30 days is the free floor — the workspace bills
    for retention beyond it, so anything higher is a standing cost for a week
    that is torn down in a day.
  EOT
  type        = number
  default     = 30
}
