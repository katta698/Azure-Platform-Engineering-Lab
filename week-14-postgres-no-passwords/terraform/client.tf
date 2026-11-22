# The client. A private database cannot be reached from a laptop, so proving
# the connection and measuring failover downtime both have to happen from
# inside the virtual network.
#
# It is reached through the Azure control plane with `az vm run-command`, so
# it has no public IP and no open port. Azure still insists a Linux VM carry
# a credential, so one is generated and never used -- which is the contrast
# the week is about: the VM must have a key it does not need, and the
# database has nothing at all.

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-app-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags
}

resource "tls_private_key" "unused" {
  algorithm = "ED25519"
}

resource "azurerm_network_interface" "app" {
  name                = "nic-app-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id. Deliberate, and the reason the NAT gateway
    # exists for outbound.
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app-${local.suffix}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.app.id]
  custom_data                     = base64encode(local.cloud_init)
  tags                            = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.unused.public_key_openssh
  }

  # User-assigned: the identity is the database's administrator, so it has to
  # be creatable and grantable BEFORE the VM exists. A system-assigned
  # identity does not exist until the VM does, which would make the Entra
  # admin assignment depend on the thing that needs it.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

locals {
  # Written as a file rather than inline in the validate script so the
  # writer's own clock is the one being read. Measuring failover from the
  # laptop would include the round trip to Azure and back.
  cloud_init = <<-CLOUDINIT
    #cloud-config
    write_files:
      - path: /usr/local/bin/wk14-token.sh
        permissions: '0755'
        content: |
          #!/usr/bin/env bash
          # A database password that nobody chose, nobody stores and nobody
          # can reuse: an Entra access token for the PostgreSQL audience,
          # minted for this VM's user-assigned identity by the instance
          # metadata service. Valid up to 24 hours for a managed identity.
          set -euo pipefail
          curl -sS -H Metadata:true --max-time 10 \
            "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fossrdbms-aad.database.windows.net&client_id=${azurerm_user_assigned_identity.app.client_id}" \
            | jq -r .access_token

      - path: /usr/local/bin/wk14-writer.sh
        permissions: '0755'
        content: |
          #!/usr/bin/env bash
          # Writes one row every quarter second and logs the outcome with a
          # millisecond timestamp. The failover gap is the difference between
          # the last OK before the outage and the first OK after it --
          # measured from the client, which is what Microsoft's own guidance
          # says to do, because the end-to-end failover runs for minutes
          # after the application is already writing again.
          set -uo pipefail
          HOST="$1"
          LOG="/var/log/wk14-writer.log"
          PGUSER_NAME="${azurerm_user_assigned_identity.app.name}"
          export PGPASSWORD="$(/usr/local/bin/wk14-token.sh)"
          TOKEN_AT=$SECONDS
          psql "host=$HOST user=$PGUSER_NAME dbname=orders sslmode=require" -v ON_ERROR_STOP=1 -q -c \
            "create table if not exists heartbeat (id bigserial primary key, at timestamptz default now())" \
            >>"$LOG" 2>&1
          while true; do
            if [ $((SECONDS - TOKEN_AT)) -gt 1800 ]; then
              export PGPASSWORD="$(/usr/local/bin/wk14-token.sh)"; TOKEN_AT=$SECONDS
            fi
            NOW=$(date -u +%s.%3N)
            if psql "host=$HOST user=$PGUSER_NAME dbname=orders sslmode=require connect_timeout=2" \
                 -v ON_ERROR_STOP=1 -qtAX -c "insert into heartbeat default values" >/dev/null 2>&1; then
              echo "OK $NOW"
            else
              echo "FAIL $NOW"
            fi >>"$LOG"
            sleep 0.25
          done

    runcmd:
      # cloud-init's runcmd runs late in boot, which is not a promise that
      # egress through the NAT gateway is up yet. Week 11 failed here at
      # 132 seconds against a network that came up shortly afterwards.
      - |
        for i in $(seq 1 30); do
          getent hosts archive.ubuntu.com >/dev/null 2>&1 && break
          sleep 10
        done
      - |
        for i in $(seq 1 5); do
          DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
          DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client jq && \
          break
          sleep 20
        done
      - touch /var/log/wk14-ready
  CLOUDINIT
}
