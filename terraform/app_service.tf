resource "azurerm_service_plan" "this" {
  name                = local.names.service_plan
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  os_type             = "Windows"
  sku_name            = var.app_service_plan_sku
  tags                = local.tags
}

resource "azurerm_windows_web_app" "api" {
  name                                           = local.names.api_app
  location                                       = var.location
  resource_group_name                            = data.azurerm_resource_group.this.name
  service_plan_id                                = azurerm_service_plan.this.id
  https_only                                     = true
  virtual_network_subnet_id                      = azurerm_subnet.api.id
  key_vault_reference_identity_id                = azurerm_user_assigned_identity.api.id
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  tags                                           = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api.id]
  }

  site_config {
    always_on                         = true
    ftps_state                        = "Disabled"
    http2_enabled                     = true
    minimum_tls_version               = "1.2"
    scm_minimum_tls_version           = "1.2"
    health_check_path                 = var.api_health_check_path
    health_check_eviction_time_in_min = var.api_health_check_path == null ? null : 10
    vnet_route_all_enabled            = true

    # The provider defaults Windows workers to 32-bit, on which a win-x64 publish fails to start.
    use_32_bit_worker = false

    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v10.0"
    }

    # Built from the name rather than azurerm_windows_web_app.ui.default_hostname: that value is unknown until the
    # UI app exists, and azurerm 5.9 then fails the apply with "inconsistent final plan" on this block.
    cors {
      allowed_origins = concat(["https://${local.names.ui_app}.azurewebsites.net"], var.api_cors_allowed_origins)
    }
  }

  # No secrets: every data service is reached with the user-assigned identity selected by AZURE_CLIENT_ID.
  app_settings = {
    ASPNETCORE_ENVIRONMENT                = var.aspnetcore_environment
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
    AZURE_CLIENT_ID                       = azurerm_user_assigned_identity.api.client_id
    KeyVault__Uri                         = azurerm_key_vault.this.vault_uri
    Storage__BlobEndpoint                 = azurerm_storage_account.this.primary_blob_endpoint
    Cosmos__Endpoint                      = azurerm_cosmosdb_account.this.endpoint
    Cosmos__DatabaseName                  = azurerm_cosmosdb_sql_database.this.name
  }

  connection_string {
    name  = "Sql"
    type  = "SQLAzure"
    value = "Server=tcp:${azurerm_mssql_server.this.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.this.name};Authentication=Active Directory Managed Identity;User Id=${azurerm_user_assigned_identity.api.client_id};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  }

  lifecycle {
    # Set by the application deployment pipeline (zip deploy), not by infrastructure.
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]]
  }
}

# IIS serves the static Angular build, so the deployed package must include a web.config whose URL Rewrite
# rule sends unknown paths to index.html; without it, deep links and refreshes return 404.
resource "azurerm_windows_web_app" "ui" {
  name                                           = local.names.ui_app
  location                                       = var.location
  resource_group_name                            = data.azurerm_resource_group.this.name
  service_plan_id                                = azurerm_service_plan.this.id
  https_only                                     = true
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  tags                                           = local.tags

  site_config {
    always_on               = true
    ftps_state              = "Disabled"
    http2_enabled           = true
    minimum_tls_version     = "1.2"
    scm_minimum_tls_version = "1.2"

    # Node never serves requests here; the stack is set because the provider warns that omitting it misbehaves.
    application_stack {
      current_stack = "node"
      node_version  = "~24"
    }
  }

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
  }

  lifecycle {
    # Set by the application deployment pipeline (zip deploy), not by infrastructure.
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]]
  }
}
