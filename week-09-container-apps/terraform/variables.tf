variable "tenant_id" {
  type        = string
  description = "Entra tenant."
}

variable "subscription_id" {
  type        = string
  description = "sub-lab-dev. The workload is an application, so it belongs under mg-lz-dev."
}

variable "management_subscription_id" {
  type        = string
  description = "sub-management, which holds week 08's Log Analytics workspace."
}

variable "location" {
  type    = string
  default = "southcentralus"
}

variable "log_analytics_resource_group" {
  type        = string
  default     = "rg-observability-prod-scus-001"
  description = "Week 08's resource group, in sub-management."
}

variable "log_analytics_workspace_name" {
  type        = string
  default     = "log-platform-prod-scus-001"
  description = "Week 08's workspace. This week sends its logs here rather than creating a second one."
}

variable "container_image" {
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
  description = <<-EOT
    Microsoft Container Registry, deliberately, and it is the reason this week
    needs no registry credential at all.

    Docker Hub would have worked and is what most examples use. It also rate
    limits anonymous pulls by source IP, and a Container Apps environment
    scaling out shares one egress address - so the failure mode is a replica
    that cannot start under exactly the load that caused it to be created.
    MCR is anonymous, unmetered and Microsoft-operated.

    A private ACR is what production uses, and it changes one thing about this
    code: a registry block pointing at the managed identity below. See the
    README for what that costs.
  EOT
}

variable "min_replicas" {
  type        = number
  default     = 0
  description = <<-EOT
    Zero is the whole point of the week. At zero replicas the app bills nothing
    and the first request pays for the cold start. Set it to 1 and you have
    bought away the latency with a container that runs all night.
  EOT
}

variable "max_replicas" {
  type        = number
  default     = 3
  description = <<-EOT
    A ceiling, not a target. Scale-to-zero removes the floor on cost; without
    a ceiling the same autoscaler removes the limit on it. A runaway client or
    a load test should hit a wall that is cheap, not elastic.
  EOT
}
