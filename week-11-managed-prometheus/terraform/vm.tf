# ─────────────────────────────────────────────────────────────────────────────
# The Prometheus host.
#
# The only reason this VM exists is that remote-write needs something to write
# FROM. It is deliberately dull: one subnet, no inbound port, and a public IP
# used purely for egress.
#
# Why a public IP at all: the VM must reach the ingestion endpoint over HTTPS,
# and Azure's default outbound access is retired - a VM with no explicit
# egress path has no internet. The two honest options are a public IP
# (~$0.005/hour) or a NAT gateway (~$0.045/hour, nine times the price for the
# same outbound). The cheap one wins here because nothing inbound is allowed
# to reach it anyway.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "prometheus" {
  name                = "vnet-wk11-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
  address_space       = ["10.11.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "prometheus" {
  name                 = "snet-prometheus"
  resource_group_name  = azurerm_resource_group.metrics.name
  virtual_network_name = azurerm_virtual_network.prometheus.name
  address_prefixes     = ["10.11.1.0/24"]
}

# No allow rule for inbound anywhere in here. Azure's default rules already
# deny inbound from the internet; this adds an explicit deny at the lowest
# usable priority so that the intent is written down rather than inherited.
resource "azurerm_network_security_group" "prometheus" {
  name                = "nsg-wk11-prometheus-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
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

resource "azurerm_subnet_network_security_group_association" "prometheus" {
  subnet_id                 = azurerm_subnet.prometheus.id
  network_security_group_id = azurerm_network_security_group.prometheus.id
}

resource "azurerm_public_ip" "prometheus" {
  name                = "pip-wk11-prometheus-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "prometheus" {
  name                = "nic-wk11-prometheus-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.prometheus.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.prometheus.id
  }
}

resource "azurerm_linux_virtual_machine" "prometheus" {
  name                = "vm-wk11-prometheus-dev-scus-001"
  resource_group_name = azurerm_resource_group.metrics.name
  location            = azurerm_resource_group.metrics.location
  size                = var.vm_size
  admin_username      = "azureuser"
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.prometheus.id]

  # Azure requires a key or a password on a Linux VM. The key is supplied, not
  # generated: generating one here would put its private half in Terraform
  # state. No inbound port is open, so nothing can use it until someone
  # deliberately opens one.
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  # This is what makes the whole week work. The identity is attached to the
  # VM, so Prometheus can ask the instance metadata service for a token and
  # never holds a credential of its own.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.prometheus.id]
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    remote_write_url   = local.remote_write_url
    identity_client_id = azurerm_user_assigned_identity.prometheus.client_id
    prometheus_version = var.prometheus_version
  }))

  # The role assignment is not a dependency Terraform can infer, and the VM
  # starts writing the moment it boots. Ordering it after the grant does not
  # remove the ~30 minute propagation wait, but it does mean the wait starts
  # as early as possible.
  depends_on = [azurerm_role_assignment.prometheus_publisher]
}
