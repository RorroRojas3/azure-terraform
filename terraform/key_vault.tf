# Terraform writes no secrets here, so pipeline agents never need data-plane access through the firewall.
resource "azurerm_key_vault" "this" {
  name                          = local.names.key_vault
  location                      = var.location
  resource_group_name           = data.azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  public_network_access_enabled = true
  tags                          = local.tags

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    ip_rules                   = local.firewall_ip_rules
    virtual_network_subnet_ids = [azurerm_subnet.api.id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }
}
