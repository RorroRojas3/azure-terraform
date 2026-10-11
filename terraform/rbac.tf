# Every Azure RBAC role used here must be in the allowlist of the apply identity's ABAC-constrained
# "Role Based Access Control Administrator" assignment (assignable_role_names in bootstrap/terraform).

locals {
  cosmos_data_contributor_role_id = "${azurerm_cosmosdb_account.this.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  cosmos_database_scope           = "${azurerm_cosmosdb_account.this.id}/dbs/${azurerm_cosmosdb_sql_database.this.name}"
  developer_principal_ids         = toset(var.developer_principal_ids)
}

resource "azurerm_role_assignment" "api_key_vault_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "api_storage_blob_data_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_cosmosdb_sql_role_assignment" "api_data_contributor" {
  resource_group_name = data.azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this.name
  role_definition_id  = local.cosmos_data_contributor_role_id
  principal_id        = azurerm_user_assigned_identity.api.principal_id
  scope               = local.cosmos_database_scope
}

resource "azurerm_role_assignment" "developer_key_vault_secrets_officer" {
  for_each = local.developer_principal_ids

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "developer_storage_blob_data_contributor" {
  for_each = local.developer_principal_ids

  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

resource "azurerm_cosmosdb_sql_role_assignment" "developer_data_contributor" {
  for_each = local.developer_principal_ids

  resource_group_name = data.azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this.name
  role_definition_id  = local.cosmos_data_contributor_role_id
  principal_id        = each.value
  scope               = local.cosmos_database_scope
}
