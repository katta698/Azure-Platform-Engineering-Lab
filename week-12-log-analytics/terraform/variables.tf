variable "tenant_id" {
  type        = string
  description = "Entra tenant."
}

variable "subscription_id" {
  type        = string
  description = "sub-management. HIERARCHY.md assigns Log Analytics here."
}

variable "location" {
  type    = string
  default = "southcentralus"
}

variable "daily_cap_gb" {
  type        = number
  default     = 1
  description = <<-EOT
    The backstop, in GB/day. 1 GB is far above anything this lab ingests, which
    is the point: a cap set near normal volume trips on a normal busy day and
    loses data you needed. Set it where it catches a runaway, not a Tuesday.
  EOT
}

variable "alert_email" {
  type        = string
  description = "Where the daily-cap alert goes. A cap that trips silently is data loss nobody noticed."
}
