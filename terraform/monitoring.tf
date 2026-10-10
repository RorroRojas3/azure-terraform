resource "azurerm_log_analytics_workspace" "this" {
  name                = local.names.log_analytics
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  daily_quota_gb      = var.log_analytics_daily_quota_gb
  tags                = local.tags
}

# Shared by the API and the UI. Local auth stays enabled because the Angular browser SDK can only send
# telemetry with the connection string; Microsoft does not treat that connection string as a secret.
resource "azurerm_application_insights" "this" {
  name                = local.names.app_insights
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = local.tags
}
