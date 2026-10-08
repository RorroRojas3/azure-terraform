data "azurerm_client_config" "current" {}

# Created by bootstrap/New-AppEnvironment.ps1; the pipeline identity can only work inside it.
data "azurerm_resource_group" "this" {
  name = "${var.name_prefix}-rg-${var.environment}"
}
