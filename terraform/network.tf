# Outbound-only: the API's VNet integration lets the data services admit it through service endpoints.
# Azure Storage IP rules cannot match a same-region App Service, so IP allowlisting alone would lock the API out.
resource "azurerm_virtual_network" "this" {
  name                = local.names.vnet
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "api" {
  name                 = local.names.api_subnet
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_address_space, 2, 0)]

  delegation {
    name = "app-service"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }

  dynamic "service_endpoint" {
    for_each = ["Microsoft.AzureCosmosDB", "Microsoft.KeyVault", "Microsoft.Sql", "Microsoft.Storage"]

    content {
      service = service_endpoint.value
    }
  }
}
