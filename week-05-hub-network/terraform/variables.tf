variable "tenant_id" {
  description = "Entra tenant. Read from `az account show`; never committed."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "`sub-connectivity` — where the hub and the private DNS estate live."
  type        = string
}

variable "spoke_subscription_id" {
  description = "`sub-lab-dev` — where the spoke lives."
  type        = string
}

variable "location" {
  description = "Region for everything in this week. One region on purpose: peering is free within a region and charged across."
  type        = string
  default     = "southcentralus"
}

# ── The cost switch ─────────────────────────────────────────────────────────

variable "deploy_firewall" {
  description = <<-EOT
    Whether to deploy Azure Firewall and its two public IPs.

    **This is the only expensive thing in the week**, and it is the only thing
    `cleanup.sh` destroys by default. Everything else — the hub, the subnets,
    the spoke, the peerings, the route table and the whole private DNS estate —
    costs approximately nothing and is what weeks 06 onward attach to.

    Defaulted false so that the cheap, permanent layer can be applied, re-applied
    and left alone without ever standing up a firewall by accident.

    Measured 2026-09-19 from the Azure retail price API, southcentralus:
      Basic deployment   $0.395/hour
      2 × public IP      $0.010/hour   (Basic mandates a management IP)
      total              $0.405/hour   ≈ $296/month if left running
  EOT
  type        = bool
  default     = false
}

variable "firewall_sku_tier" {
  description = <<-EOT
    Basic, Standard or Premium.

    Basic is not simply a cheaper Standard. It **mandates a management NIC**:
    a second subnet named `AzureFirewallManagementSubnet` and a second public
    IP, neither of which Standard requires. That is a virtual network design
    decision, not a pricing toggle, which is why the hub always carries the
    management subnet — switching tiers should not require re-addressing the
    hub.

    Basic also has no DNS proxy ("uses Azure DNS only"), no network-level FQDN
    filtering, no web categories, threat intelligence in alert mode only, and a
    250 Mbps ceiling.
  EOT
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.firewall_sku_tier)
    error_message = "firewall_sku_tier must be Basic, Standard or Premium."
  }
}

# ── Addressing ──────────────────────────────────────────────────────────────

variable "hub_address_space" {
  description = "Hub VNet address space. Must not overlap any spoke, ever — peering refuses overlapping ranges and re-addressing a live hub is not a small job."
  type        = string
  default     = "10.0.0.0/16"
}

variable "spoke_address_space" {
  description = "Spoke VNet address space."
  type        = string
  default     = "10.1.0.0/16"
}

# ── The private DNS estate ──────────────────────────────────────────────────

variable "private_dns_zones" {
  description = <<-EOT
    Private DNS zones created in the hub and linked to every VNet.

    These names are not arbitrary and cannot be invented: each Azure service
    publishes the exact zone name its private endpoint registers into, and a
    zone whose name is one character off resolves nothing while looking
    completely correct in the portal.

    They live in the hub, in the connectivity subscription, because a private
    endpoint in any spoke must resolve to the same record everywhere. Per-spoke
    zones are the classic mistake: resolution works in the spoke that owns the
    endpoint and silently returns the public IP everywhere else.
  EOT
  type        = map(string)
  default = {
    blob    = "privatelink.blob.core.windows.net"
    file    = "privatelink.file.core.windows.net"
    vault   = "privatelink.vaultcore.azure.net"
    sql     = "privatelink.database.windows.net"
    acr     = "privatelink.azurecr.io"
    monitor = "privatelink.monitor.azure.com"
  }
}
