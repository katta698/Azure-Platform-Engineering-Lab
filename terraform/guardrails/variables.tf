variable "tenant_id" { type = string }
variable "subscription_id" { type = string }

variable "management_group" {
  type    = string
  default = "mg-katta"

  description = <<-EOT
    Where the guardrail is assigned. Two levels above sub-lab-dev, so nothing
    running in the subscription can remove it, and any future subscription
    inherits it.
  EOT
}

variable "allowed_vm_sizes" {
  type = list(string)
  default = [
    "Standard_B1s", "Standard_B2s", "Standard_B1ms", "Standard_B2ms",
    "Standard_D2als_v6", "Standard_D2als_v7", "Standard_D2s_v5", "Standard_D2s_v6",
  ]
  description = "Every size here is 1-2 vCPU. A lab has never needed more."
}

variable "allowed_postgres_skus" {
  type = list(string)
  default = [
    "B_Standard_B1ms", "B_Standard_B2s",
    "GP_Standard_D2ds_v4", "GP_Standard_D2ds_v5", "GP_Standard_D2s_v3",
  ]
  description = <<-EOT
    2 vCores maximum. The dearest PostgreSQL meter in this region is a
    ~96-vCore Memory Optimized server at $76.98/hour; this list is what stops
    a typo reaching it.
  EOT
}
