resource "azurerm_user_assigned_identity" "api" {
  name                = local.names.api_identity
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}
