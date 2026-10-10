# Entra-only authentication: there is no SQL login or password to store anywhere.
# The API's contained database user is created by scripts/Grant-SqlManagedIdentityAccess.ps1 after apply,
# because T-SQL is outside what the azurerm provider can manage.
resource "azurerm_mssql_server" "this" {
  name                          = local.names.sql_server
  location                      = var.location
  resource_group_name           = data.azurerm_resource_group.this.name
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags

  azuread_administrator {
    login_username              = var.sql_admin_group_name
    object_id                   = var.sql_admin_group_object_id
    azuread_authentication_only = true
  }
}

resource "azurerm_mssql_firewall_rule" "allowed" {
  # Indexed rather than keyed by address: sensitive values can't be instance keys, and keys would leak the IPs.
  count = nonsensitive(length(local.allowed_cidrs))

  name             = "allow-ip-${count.index}"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = cidrhost(local.allowed_cidrs[count.index], 0)
  end_ip_address   = cidrhost(local.allowed_cidrs[count.index], -1)
}

resource "azurerm_mssql_virtual_network_rule" "api" {
  name      = "allow-api-subnet"
  server_id = azurerm_mssql_server.this.id
  subnet_id = azurerm_subnet.api.id
}

resource "azurerm_mssql_database" "this" {
  name                 = local.names.sql_database
  server_id            = azurerm_mssql_server.this.id
  sku_name             = var.sql_database_sku
  max_size_gb          = var.sql_database_max_size_gb
  storage_account_type = var.sql_backup_storage_redundancy
  zone_redundant       = false
  tags                 = local.tags

  short_term_retention_policy {
    retention_days = var.sql_short_term_retention_days
  }
}
