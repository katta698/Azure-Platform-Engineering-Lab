variable "tenant_id" {
  type        = string
  description = "Entra tenant."
}

variable "subscription_id" {
  type        = string
  description = "sub-lab-dev. Where the identity is created and scoped."
}

variable "location" {
  type    = string
  default = "southcentralus"
}

variable "github_org" {
  type        = string
  description = "GitHub org or user that owns the repo the token comes from."
}

variable "github_repo" {
  type        = string
  description = "Repository name. Combined with the org into the credential's subject."
}

variable "github_subject_prefix" {
  type        = string
  description = <<-EOT
    The subject prefix GitHub actually presents, read at deploy time from
    /repos/{owner}/{repo}/actions/oidc/customization/sub. With immutable
    subject claims on it carries numeric IDs, so it cannot be derived from the
    org and repo names alone.
  EOT
}
