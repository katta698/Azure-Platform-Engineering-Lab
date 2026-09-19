# ═══════════════════════════════════════════════════════════════════════════
# The hub network
#
# Everything later in this lab attaches to what is built here. That makes the
# lifecycle the important design decision, not the topology:
#
#   the permanent layer   hub VNet, subnets, spoke, both peerings, the route
#                         table, the private DNS estate. Costs ~nothing. Stays.
#   the disposable layer  Azure Firewall and its two public IPs. $0.405/hour.
#                         Deployed deliberately, destroyed the same day.
#
# Splitting them is why `deploy_firewall` exists. A week that is "built once and
# kept" cannot also be a week that bills by the hour forever.
# ═══════════════════════════════════════════════════════════════════════════

locals {
  common_tags = {
    week       = "05"
    env        = "prod"
    managed-by = "terraform"
  }

  # Subnet maths, written out rather than hardcoded, because the two firewall
  # subnets have fixed names Azure requires and a minimum size of /26. Azure
  # rejects anything smaller with an error that names the size but not the
  # reason.
  fw_data_subnet  = cidrsubnet(var.hub_address_space, 10, 0)  # 10.0.0.0/26
  fw_mgmt_subnet  = cidrsubnet(var.hub_address_space, 10, 1)  # 10.0.0.64/26
  workload_subnet = cidrsubnet(var.spoke_address_space, 8, 0) # 10.1.0.0/24
}

# ── The hub, in the connectivity subscription ───────────────────────────────

resource "azurerm_resource_group" "hub" {
  name     = "rg-hub-connectivity-prod-scus-001"
  location = var.location
  tags     = merge(local.common_tags, { cost-center = "platform-lab" })
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub-prod-scus-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  address_space       = [var.hub_address_space]
  tags                = merge(local.common_tags, { cost-center = "platform-lab" })
}

# The name is mandatory and case-sensitive. A firewall cannot be placed in a
# subnet called anything else, and the error does not say so.
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.fw_data_subnet]
}

# Created ALWAYS, even when the firewall is not deployed and even when the tier
# is Standard, which does not require it.
#
# Basic mandates a management NIC — "Firewall Basic has a mandatory requirement
# to be configured with a management NIC" — so this subnet is a prerequisite of
# the tier, not of the deployment. Creating it unconditionally means switching
# tiers later is a variable change rather than a re-addressing exercise on a
# live hub, and an empty /26 costs nothing.
resource "azurerm_subnet" "firewall_management" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.fw_mgmt_subnet]
}

# ── The spoke, in the landing zone subscription ─────────────────────────────

resource "azurerm_resource_group" "spoke" {
  provider = azurerm.spoke

  name     = "rg-spoke-lab-dev-scus-001"
  location = var.location
  tags     = merge(local.common_tags, { env = "dev", cost-center = "platform-lab" })
}

resource "azurerm_virtual_network" "spoke" {
  provider = azurerm.spoke

  name                = "vnet-spoke-lab-dev-scus-001"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = azurerm_resource_group.spoke.location
  address_space       = [var.spoke_address_space]
  tags                = merge(local.common_tags, { env = "dev", cost-center = "platform-lab" })
}

resource "azurerm_subnet" "workload" {
  provider = azurerm.spoke

  name                 = "snet-workload-dev-scus-001"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.workload_subnet]
}

# ── Peering: two resources, not one ─────────────────────────────────────────
#
# A peering is declared from each side independently and is only usable when
# both exist. One side alone sits in state `Initiated` rather than `Connected`,
# which is a working-looking resource that carries no traffic — so validate.sh
# checks the state rather than the existence.
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-spoke-lab-dev"
  resource_group_name       = azurerm_resource_group.hub.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true

  # The hub does not accept routes from the spoke, and does not need to: the
  # spoke's default route points at the firewall, not the other way round.
  allow_gateway_transit = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  provider = azurerm.spoke

  name                      = "peer-spoke-lab-dev-to-hub"
  resource_group_name       = azurerm_resource_group.spoke.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# ── The private DNS estate ──────────────────────────────────────────────────
#
# In the hub, linked to every VNet. One zone per service, shared by every spoke.
resource "azurerm_private_dns_zone" "estate" {
  for_each = var.private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.hub.name
  tags                = merge(local.common_tags, { cost-center = "platform-lab" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each = var.private_dns_zones

  name = "link-hub-${each.key}"

  # azurerm 5.x takes the zone's RESOURCE ID here. 4.x took
  # `resource_group_name` + `private_dns_zone_name`, and copying a link block
  # from almost any published example fails validate with "argument not
  # expected here" on both of them.
  private_dns_zone_id = azurerm_private_dns_zone.estate[each.key].id
  virtual_network_id  = azurerm_virtual_network.hub.id

  # No auto-registration. These zones exist for private ENDPOINTS, which create
  # their own A records. Auto-registration would additionally register every VM
  # NIC in the linked VNet into a privatelink zone, which is not what any of
  # these zones are for.
  registration_enabled = false
}

# The link that does the real work. A zone linked only to the hub resolves
# nothing for a workload sitting in the spoke — the endpoint would resolve to
# its public IP, which fails closed later and looks like a firewall problem.
resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each = var.private_dns_zones

  name                 = "link-spoke-lab-dev-${each.key}"
  private_dns_zone_id  = azurerm_private_dns_zone.estate[each.key].id
  virtual_network_id   = azurerm_virtual_network.spoke.id
  registration_enabled = false
}

# ── The firewall: everything below here is the disposable layer ─────────────

resource "azurerm_public_ip" "firewall_data" {
  count = var.deploy_firewall ? 1 : 0

  name                = "pip-fw-hub-data-prod-scus-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  allocation_method   = "Static"
  sku                 = "Standard" # Azure Firewall requires Standard, not Basic
  tags                = merge(local.common_tags, { cost-center = "platform-lab" })
}

# The second public IP exists because the Basic tier requires one, not because
# the design wanted two. It carries only Microsoft's management traffic —
# "No other connections are allowed on this IP."
resource "azurerm_public_ip" "firewall_management" {
  count = var.deploy_firewall ? 1 : 0

  name                = "pip-fw-hub-mgmt-prod-scus-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.common_tags, { cost-center = "platform-lab" })
}

# ── Policy hierarchy: a parent nobody edits, a child every landing zone gets ─
#
# The parent holds rules that apply everywhere and that a landing zone team
# cannot remove. The child inherits them and adds its own. Rule collection
# groups in a child are evaluated AFTER the parent's, so the parent always wins
# — which is the entire reason to have two.
resource "azurerm_firewall_policy" "platform" {
  count = var.deploy_firewall ? 1 : 0

  name                = "afwp-platform-baseline-prod-scus-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  sku                 = var.firewall_sku_tier
  tags                = merge(local.common_tags, { cost-center = "platform-lab" })
}

# The policy tier must MATCH the firewall tier. A Standard policy on a Basic
# firewall is refused, and the error names the policy rather than the mismatch.
resource "azurerm_firewall_policy" "landing_zone" {
  count = var.deploy_firewall ? 1 : 0

  name                = "afwp-lz-dev-prod-scus-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  sku                 = var.firewall_sku_tier
  base_policy_id      = azurerm_firewall_policy.platform[0].id
  tags                = merge(local.common_tags, { cost-center = "platform-lab" })
}

# Parent rules: what every landing zone gets whether it wants it or not.
resource "azurerm_firewall_policy_rule_collection_group" "platform_baseline" {
  count = var.deploy_firewall ? 1 : 0

  name               = "rcg-platform-baseline"
  firewall_policy_id = azurerm_firewall_policy.platform[0].id
  priority           = 200

  application_rule_collection {
    name     = "arc-allow-azure-essentials"
    priority = 200
    action   = "Allow"

    rule {
      name = "allow-windows-update"
      protocols {
        type = "Https"
        port = 443
      }
      source_addresses  = [var.spoke_address_space]
      destination_fqdns = ["*.windowsupdate.com", "*.update.microsoft.com"]
    }
  }
}

# Child rules: the landing zone's own, evaluated after the parent's.
resource "azurerm_firewall_policy_rule_collection_group" "landing_zone" {
  count = var.deploy_firewall ? 1 : 0

  name               = "rcg-lz-dev"
  firewall_policy_id = azurerm_firewall_policy.landing_zone[0].id
  priority           = 300

  application_rule_collection {
    name     = "arc-lz-dev-allow"
    priority = 300
    action   = "Allow"

    rule {
      name = "allow-github"
      protocols {
        type = "Https"
        port = 443
      }
      source_addresses  = [var.spoke_address_space]
      destination_fqdns = ["github.com", "*.github.com"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  count = var.deploy_firewall ? 1 : 0

  name                = "afw-hub-prod-scus-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  sku_name           = "AZFW_VNet"
  sku_tier           = var.firewall_sku_tier
  firewall_policy_id = azurerm_firewall_policy.landing_zone[0].id

  ip_configuration {
    name                 = "data"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall_data[0].id
  }

  # Required for Basic. The block is named `management_ip_configuration` and is
  # a sibling of ip_configuration, not a field inside it.
  management_ip_configuration {
    name                 = "management"
    subnet_id            = azurerm_subnet.firewall_management.id
    public_ip_address_id = azurerm_public_ip.firewall_management[0].id
  }

  tags = merge(local.common_tags, { cost-center = "platform-lab" })
}

# ── Routing: the thing that makes the firewall load-bearing ─────────────────
#
# Without this, the firewall exists and carries no traffic. The spoke's default
# route has to point at it, and the route table is created whether or not the
# firewall is — but the route itself only exists when there is something to
# point at. A 0.0.0.0/0 route to a next hop that does not exist blackholes the
# subnet.
resource "azurerm_route_table" "spoke" {
  provider = azurerm.spoke

  name                = "rt-spoke-lab-dev-scus-001"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = azurerm_resource_group.spoke.location
  tags                = merge(local.common_tags, { env = "dev", cost-center = "platform-lab" })
}

resource "azurerm_route" "spoke_default_via_firewall" {
  provider = azurerm.spoke
  count    = var.deploy_firewall ? 1 : 0

  name                   = "udr-default-to-firewall"
  resource_group_name    = azurerm_resource_group.spoke.name
  route_table_name       = azurerm_route_table.spoke.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.hub[0].ip_configuration[0].private_ip_address
}

resource "azurerm_subnet_route_table_association" "workload" {
  provider = azurerm.spoke

  subnet_id      = azurerm_subnet.workload.id
  route_table_id = azurerm_route_table.spoke.id
}
