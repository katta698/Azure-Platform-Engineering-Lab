variable "tenant_id" {
  type        = string
  description = "Entra tenant."
}

variable "subscription_id" {
  type        = string
  description = "sub-lab-dev. The workload and its registry are application concerns."
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
  type    = string
  default = "rg-observability-prod-scus-001"
}

variable "log_analytics_workspace_name" {
  type        = string
  default     = "log-platform-prod-scus-001"
  description = "Week 08's workspace. Application Insights stores its data here rather than creating a second store."
}

variable "image_tag" {
  type        = string
  default     = "v1"
  description = "Set by deploy.sh from the ACR build, so the apps always reference an image that exists."
}

variable "trace_sampler_arg" {
  type        = number
  default     = 1.0
  description = <<-EOT
    The fraction of traces kept, 0.0 to 1.0, passed to the OpenTelemetry SDK as
    OTEL_TRACES_SAMPLER_ARG. 1.0 keeps everything, which is right for a lab and
    wrong for anything busy: traces are billed per GB like any other telemetry.
    The week measures what changing this actually does.
  EOT
}

variable "backend_work_ms" {
  type        = number
  default     = 250
  description = "How long the backend deliberately takes, so the trace has something to attribute."
}
