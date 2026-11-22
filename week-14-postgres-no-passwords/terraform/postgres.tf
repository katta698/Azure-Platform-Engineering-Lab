# The claim of the week: a database with no password in existence.
#
# administrator_login and administrator_password are both optional on this
# resource, and both are omitted here. There is no local account to leak, to
# rotate, or to find in a connection string -- not a strong one, not one in a
# key vault, none. The only way in is a Microsoft Entra token.
resource "azurerm_postgresql_flexible_server" "db" {
  name                = "psql-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location

  version    = var.postgres_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  # No public endpoint. With no delegated subnet the server is created in
  # private-endpoint-capable mode, and this closes the internet side of it.
  public_network_access_enabled = false

  zone = "1"

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = var.tenant_id
  }

  # The standby doubles the compute bill and is the only reason a failover
  # can be performed at all. Burstable supports no HA, which is what forced
  # General Purpose and the price with it.
  high_availability {
    mode                      = var.ha_mode
    standby_availability_zone = var.ha_mode == "ZoneRedundant" ? "2" : null
  }

  tags = local.tags

  # Creating a server with HA takes most of ten minutes, and the provider's
  # default would give up while Azure is still working.
  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

# Password authentication is off, so this is not an extra administrator --
# it is the ONLY administrator. It is the client VM's identity rather than a
# person, which is what makes the connection in validate.sh a real
# application login and not a human borrowing one.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "app" {
  server_name         = azurerm_postgresql_flexible_server.db.name
  resource_group_name = azurerm_resource_group.lab.name
  tenant_id           = var.tenant_id
  object_id           = azurerm_user_assigned_identity.app.principal_id
  principal_name      = azurerm_user_assigned_identity.app.name
  principal_type      = "ServicePrincipal"
}

resource "azurerm_postgresql_flexible_server_database" "orders" {
  name      = "orders"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  # The Entra extension has to be live before a database is created into a
  # server whose only administrator is an Entra principal.
  depends_on = [azurerm_postgresql_flexible_server_active_directory_administrator.app]
}

# One private endpoint, in the database subnet, joined to the private zone.
# The DNS group is what rewrites the server's own FQDN to a private address,
# so the client connects to the documented hostname and never learns an IP.
resource "azurerm_private_endpoint" "db" {
  name                = "pe-psql-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  subnet_id           = azurerm_subnet.db.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-psql-${local.suffix}"
    private_connection_resource_id = azurerm_postgresql_flexible_server.db.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-psql"
    private_dns_zone_ids = [azurerm_private_dns_zone.psql.id]
  }
}
