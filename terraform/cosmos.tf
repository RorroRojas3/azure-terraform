resource "azurerm_cosmosdb_account" "this" {
  name                = local.names.cosmos_account
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  # Keys disabled: only Entra identities with Cosmos data-plane role assignments can read or write.
  local_authentication_enabled       = false
  access_key_metadata_writes_enabled = false

  minimal_tls_version               = "Tls12"
  public_network_access_enabled     = true
  ip_range_filter                   = local.firewall_ip_rules
  is_virtual_network_filter_enabled = true
  tags                              = local.tags

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = false
  }

  dynamic "capabilities" {
    for_each = var.cosmos_serverless ? ["EnableServerless"] : []

    content {
      name = capabilities.value
    }
  }

  backup {
    type = "Continuous"
    tier = "Continuous7Days"
  }

  virtual_network_rule {
    id = azurerm_subnet.api.id
  }
}

resource "azurerm_cosmosdb_sql_database" "this" {
  name                = var.cosmos_database_name
  resource_group_name = data.azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this.name

  dynamic "autoscale_settings" {
    for_each = var.cosmos_serverless ? [] : [var.cosmos_autoscale_max_throughput]

    content {
      max_throughput = autoscale_settings.value
    }
  }
}

resource "azurerm_cosmosdb_sql_container" "this" {
  for_each = var.cosmos_containers

  name                  = each.key
  resource_group_name   = data.azurerm_resource_group.this.name
  account_name          = azurerm_cosmosdb_account.this.name
  database_name         = azurerm_cosmosdb_sql_database.this.name
  partition_key_paths   = each.value.partition_key_paths
  partition_key_kind    = length(each.value.partition_key_paths) > 1 ? "MultiHash" : "Hash"
  partition_key_version = 2
  default_ttl           = each.value.default_ttl
}
