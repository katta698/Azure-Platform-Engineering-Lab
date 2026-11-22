locals {
  suffix = "wk14-dev-scus-001"

  tags = {
    week       = "14"
    env        = "dev"
    managed-by = "terraform"
  }
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-pgnopass-lab-dev-scus-001"
  location = var.location
  tags     = local.tags
}

# ── network ────────────────────────────────────────────────────────────────
# Two subnets, neither delegated. A flexible server is reached one of two
# ways and they are mutually exclusive at creation: injected into a delegated
# subnet, or left in public-access mode and fronted by a private endpoint.
# This week takes the second -- Microsoft's documented recommendation, the
# only one that can be reached from a peered network later, and the only one
# an existing server can be moved to.
resource "azurerm_virtual_network" "lab" {
  name                = "vnet-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  address_space       = ["10.60.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.60.1.0/24"]
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.60.2.0/24"]
}

# Nothing in this week accepts an inbound connection from the internet. The
# rule is written down rather than relied on: the VM has no public IP, and
# the subnet refuses inbound anyway.
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# ── egress ─────────────────────────────────────────────────────────────────
# The explicit egress path, and it is outbound only -- a NAT gateway has no
# inbound listener. Default outbound access is an implicit platform behaviour
# Microsoft recommends against relying on: the portal already creates private
# subnets, and for API versions after 31 March 2026 new virtual networks set
# defaultOutboundAccess = false. Building it explicitly means the client's
# internet access does not depend on which API version created the subnet.
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "egress" {
  name                = "nat-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "egress" {
  nat_gateway_id       = azurerm_nat_gateway.egress.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "app" {
  subnet_id      = azurerm_subnet.app.id
  nat_gateway_id = azurerm_nat_gateway.egress.id
}

# ── private DNS ────────────────────────────────────────────────────────────
# The server's public FQDN becomes a CNAME to a record in this zone, so the
# client uses the same hostname and resolves it to a private address. The
# zone name is fixed by Azure; any other name resolves nothing.
resource "azurerm_private_dns_zone" "psql" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "psql" {
  # azurerm 5.x takes the zone ID; the 4.x resource_group_name +
  # private_dns_zone_name pair fails validate on both arguments.
  name                = "link-vnet-${local.suffix}"
  private_dns_zone_id = azurerm_private_dns_zone.psql.id
  virtual_network_id  = azurerm_virtual_network.lab.id
  tags                = local.tags
}
