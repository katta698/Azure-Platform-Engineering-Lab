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
