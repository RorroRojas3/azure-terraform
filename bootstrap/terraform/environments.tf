resource "azurerm_resource_group" "environment" {
  for_each = var.environments

  name     = "${var.name_prefix}-rg-${each.key}"
  location = var.location
  tags     = merge(local.tags, { environment = each.key })

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  for_each = var.environments

  name                  = "tfstate-${each.key}"
  storage_account_id    = data.azurerm_storage_account.state.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}
