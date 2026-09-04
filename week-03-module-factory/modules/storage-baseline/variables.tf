variable "workload" {
  description = <<-EOT
    Short name of the thing this storage account belongs to. It becomes part of
    the account name, so it is constrained to what Azure accepts there:
    lowercase alphanumerics only.

    The length cap is arithmetic, not taste. A storage account name is capped at
    24 characters globally and this module spends 2 on the `st` prefix, 3 on the
    environment and 6 on the uniqueness hash, which leaves 13. Rejecting a
    14-character workload at plan time is the whole reason a caller hands over a
    workload name instead of an account name.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,13}$", var.workload))
    error_message = "workload must be 2-13 lowercase alphanumeric characters — it is part of a storage account name, which allows nothing else."
  }
}

variable "environment" {
  description = "Environment this account belongs to. Part of the name and of the tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "tst", "prd"], var.environment)
    error_message = "environment must be one of dev, tst, prd."
  }
}

variable "location" {
  description = "Azure region. Must match the resource group's region for the name hash to stay stable."
  type        = string
}

variable "resource_group_id" {
  description = <<-EOT
    Full resource ID of the resource group, not its name:
    /subscriptions/<guid>/resourceGroups/<name>

    The wrapped module takes `parent_id` rather than `resource_group_name`,
    because it addresses ARM directly and ARM has no concept of a resource
    group name detached from a subscription. Passing a bare name fails inside
    the AVM module with a parsing error against a variable the caller never set.
  EOT
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+$", var.resource_group_id))
    error_message = "resource_group_id must be a full resource group ID: /subscriptions/<guid>/resourceGroups/<name>."
  }
}

variable "cost_center" {
  description = <<-EOT
    Value of the cost-center tag. Required, with no default.

    Every input on this module that could plausibly be forgotten has a default,
    except this one. A storage account nobody can bill is the specific failure
    this lab's tagging policy exists to prevent, and a default here would let a
    caller inherit someone else's answer silently.
  EOT
  type        = string
}

variable "log_analytics_workspace_id" {
  description = <<-EOT
    Workspace the account's metrics and the blob service's audit logs are sent
    to. Optional: leave it null and no diagnostic setting is created.

    Optional is the wrong default and v2.0.0 of this module removes it. It is
    here in v1.0.0 because that is what the first version shipped with, and the
    version that ships is the version consumers pin.
  EOT
  type        = string
  default     = null
}

variable "shared_access_key_enabled" {
  description = <<-EOT
    Whether the account's shared keys work. true here means a connection string
    with an embedded key authenticates, which is the thing managed identities
    exist to replace.

    Defaults to true in v1.0.0 and false in v2.0.0. That flip is the more
    dangerous half of the major bump: it changes behaviour without changing the
    call, so nothing fails at plan and the break arrives at runtime in whatever
    was still using a key.
  EOT
  type        = bool
  default     = true
}

variable "container_name" {
  description = "Name of the single blob container created in the account."
  type        = string
  default     = "data"
}

variable "tags" {
  description = <<-EOT
    Tags merged over the ones this module sets. The module owns `env`,
    `cost-center` and `module`; anything else is the caller's.

    The merge order puts the caller last on purpose, so a caller CAN override
    `env`. A module that silently discards an input is worse than one that lets
    you set it wrong, because only one of those is visible in a plan.
  EOT
  type        = map(string)
  default     = {}
}

variable "enable_telemetry" {
  description = <<-EOT
    AVM modules report anonymous usage telemetry to Microsoft through the modtm
    provider, and default it to on. This module defaults it to off.

    It is not a privacy position — the payload is a module ID and a version.
    It is that telemetry makes an outbound HTTP call during plan, so a plan in
    an egress-restricted network gains a way to be slow or to fail that has
    nothing to do with the infrastructure being planned. A platform module's
    defaults should not include a network dependency the caller did not ask for.
  EOT
  type        = bool
  default     = false
}
