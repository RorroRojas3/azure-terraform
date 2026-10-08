resource "azurerm_storage_account" "this" {
  name                             = local.names.storage_account
  location                         = var.location
  resource_group_name              = data.azurerm_resource_group.this.name
  account_kind                     = "StorageV2"
  account_tier                     = "Standard"
  account_replication_type         = var.storage_replication_type
  access_tier                      = "Hot"
  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  local_user_enabled               = false
  public_network_access            = "Enabled"
  tags                             = local.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    ip_rules                   = local.firewall_ip_rules
    virtual_network_subnet_ids = [azurerm_subnet.api.id]
  }
}

resource "azurerm_storage_container" "this" {
  for_each = toset(var.storage_containers)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}
