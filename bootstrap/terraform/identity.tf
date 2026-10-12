# Plan and apply identities per environment. They live in the tfstate resource group, outside the environment they
# manage, so a pipeline can't modify or delete its own identity.
resource "azurerm_user_assigned_identity" "pipeline" {
  for_each = local.pipeline_identities

  name                = "${var.name_prefix}-id-ado-${each.key}"
  location            = data.azurerm_storage_account.state.location
  resource_group_name = local.state_resource_group_name
  tags                = merge(local.tags, { environment = each.value.environment })

  lifecycle {
    prevent_destroy = true
  }
}

# The subject embeds the service connection's GUID, so it can only come from the connection's computed outputs.
resource "azurerm_federated_identity_credential" "pipeline" {
  for_each = local.pipeline_identities

  name                      = "ado-${azuredevops_serviceendpoint_azurerm.pipeline[each.key].service_endpoint_name}"
  user_assigned_identity_id = azurerm_user_assigned_identity.pipeline[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azuredevops_serviceendpoint_azurerm.pipeline[each.key].workload_identity_federation_issuer
  subject                   = azuredevops_serviceendpoint_azurerm.pipeline[each.key].workload_identity_federation_subject
}
