output "resource_group_name" {
  description = "Environment resource group."
  value       = data.azurerm_resource_group.this.name
}

output "api_url" {
  description = "Public URL of the API web app."
  value       = "https://${azurerm_linux_web_app.api.default_hostname}"
}

output "api_web_app_name" {
  description = "API web app name, for the application deployment pipeline."
  value       = azurerm_linux_web_app.api.name
}

output "ui_url" {
  description = "Public URL of the UI web app."
  value       = "https://${azurerm_linux_web_app.ui.default_hostname}"
}

output "ui_web_app_name" {
  description = "UI web app name, for the application deployment pipeline."
  value       = azurerm_linux_web_app.ui.name
}

output "api_identity" {
  description = "User-assigned identity used by the API for every data service."
  value = {
    name         = azurerm_user_assigned_identity.api.name
    client_id    = azurerm_user_assigned_identity.api.client_id
    principal_id = azurerm_user_assigned_identity.api.principal_id
  }
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = azurerm_key_vault.this.vault_uri
}

output "storage_blob_endpoint" {
  description = "Primary blob endpoint of the environment storage account."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "cosmos" {
  description = "Cosmos DB endpoint and database."
  value = {
    endpoint      = azurerm_cosmosdb_account.this.endpoint
    database_name = azurerm_cosmosdb_sql_database.this.name
  }
}

output "sql" {
  description = "Azure SQL server FQDN and database."
  value = {
    server_fqdn   = azurerm_mssql_server.this.fully_qualified_domain_name
    database_name = azurerm_mssql_database.this.name
  }
}

# Consumed by the pipeline's SQL access stage (scripts/Grant-SqlManagedIdentityAccess.ps1).
output "sql_access" {
  description = "Inputs for creating the API identity's contained database user."
  value = {
    resource_group_name = data.azurerm_resource_group.this.name
    server_name         = azurerm_mssql_server.this.name
    database_name       = azurerm_mssql_database.this.name
    principal_name      = azurerm_user_assigned_identity.api.name
    principal_client_id = azurerm_user_assigned_identity.api.client_id
  }
}

output "application_insights_connection_string" {
  description = "Shared Application Insights connection string, needed by the Angular build."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}
