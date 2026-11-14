variable "tenant_id" {
  type        = string
  description = "Entra tenant. Read from `az account show`; never committed."
}

variable "subscription_id" {
  type        = string
  description = "sub-lab-dev. Also the scope the policy initiative is assigned at."
}

variable "location" {
  type    = string
  default = "southcentralus"
}

variable "category_group" {
  type    = string
  default = "audit"

  validation {
    condition     = contains(["audit", "allLogs"], var.category_group)
    error_message = "audit or allLogs. 'none' deploys a setting that collects nothing."
  }

  description = <<-EOT
    Selects WHICH built-in initiative is assigned, and is the cost lever of
    this week. `audit` covers 69 policies; `allLogs` covers 139 and collects
    far more per resource. It is not passed as a parameter -- these
    initiatives do not accept one.

    It also changes WHICH resources are covered at all: a network security
    group supports allLogs and not audit, so under `audit` it is never
    remediated. That is correct behaviour, not a failure.
  EOT
}

variable "daily_quota_gb" {
  type    = number
  default = 0.5

  description = <<-EOT
    Workspace ingestion cap. This week turns logging ON across resource types
    and Analytics ingestion bills $2.76/GB, so the ceiling is set in code
    rather than watched. Ingestion stops at the cap; it does not bill past it.
  EOT
}
