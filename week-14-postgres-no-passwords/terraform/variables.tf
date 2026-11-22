variable "subscription_id" { type = string }
variable "tenant_id" { type = string }

variable "location" {
  type    = string
  default = "southcentralus"
}

variable "sku_name" {
  type    = string
  default = "GP_Standard_D2ds_v5"

  description = <<-EOT
    General Purpose, 2 vCores, 0.2052/hour -- doubled by the standby.

    Burstable is cheaper and cannot be used: it supports no form of high
    availability, so a failover could not be performed at all. The deny
    policy at mg-katta refuses anything outside a 2-vCore allowlist, so a
    typo here fails at the request rather than on the invoice.
  EOT

  validation {
    condition     = can(regex("^(GP|MO)_Standard_D2", var.sku_name))
    error_message = "HA needs General Purpose or Memory Optimized, and this lab caps at 2 vCores."
  }
}

variable "ha_mode" {
  type    = string
  default = "ZoneRedundant"

  description = <<-EOT
    ZoneRedundant puts the standby in another availability zone; SameZone
    puts it beside the primary. Both run a standby and both cost the same,
    so this is a resilience choice and not a cost one.

    southcentralus has three availability zones, and the capability API
    reports ZoneRedundantHa as Disabled for it. The two disagree, so the
    value is a variable: if the create is refused, SameZone still carries a
    real failover and the week says which it got.
  EOT

  validation {
    condition     = contains(["ZoneRedundant", "SameZone"], var.ha_mode)
    error_message = "ha_mode is ZoneRedundant or SameZone."
  }
}

variable "postgres_version" {
  type    = string
  default = "17"

  description = <<-EOT
    17 is in community support, so the Extended Support vCore meter
    (0.084/hour for running past end-of-life) cannot apply.
  EOT
}

variable "storage_mb" {
  type        = number
  default     = 32768
  description = "32 GB, the minimum. Billed per provisioned GB, for the standby too."
}

variable "vm_size" {
  type    = string
  default = "Standard_D2als_v7"

  description = <<-EOT
    The client. 2 vCPU, 0.0962/hour measured in week 11, and on the
    guardrail's allowlist. It exists because a private database cannot be
    reached from a laptop: proving the connection and measuring failover
    downtime both have to happen inside the virtual network.
  EOT
}
