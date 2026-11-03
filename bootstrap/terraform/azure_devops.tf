resource "azuredevops_serviceendpoint_azurerm" "pipeline" {
  for_each = local.pipeline_identities

  project_id                             = data.azuredevops_project.this.id
  service_endpoint_name                  = "${var.name_prefix}-sc-${each.key}"
  description                            = "Terraform ${each.value.role} for ${each.value.environment}. Managed by bootstrap/terraform."
  service_endpoint_authentication_scheme = "WorkloadIdentityFederation"
  azurerm_spn_tenantid                   = data.azurerm_client_config.current.tenant_id
  azurerm_subscription_id                = data.azurerm_subscription.current.subscription_id
  azurerm_subscription_name              = data.azurerm_subscription.current.display_name

  credentials {
    serviceprincipalid = azurerm_user_assigned_identity.pipeline[each.key].client_id
  }

  # Verification needs the federated credential, which can only be created from this connection's outputs.
  features {
    validate = false
  }
}

# Branch control and the lock live on the apply connection rather than the Environment: YAML can skip an Environment,
# but it can't use a service connection without passing that connection's checks.
resource "azuredevops_check_branch_control" "apply" {
  for_each = var.environments

  project_id           = data.azuredevops_project.this.id
  display_name         = "Only main can apply"
  target_resource_id   = azuredevops_serviceendpoint_azurerm.pipeline["${each.key}-apply"].id
  target_resource_type = "endpoint"
  allowed_branches     = "refs/heads/main"

  # Branch protection lives in GitHub, which this check can't inspect.
  verify_branch_protection = false
}

resource "azuredevops_check_exclusive_lock" "apply" {
  for_each = var.environments

  project_id           = data.azuredevops_project.this.id
  target_resource_id   = azuredevops_serviceendpoint_azurerm.pipeline["${each.key}-apply"].id
  target_resource_type = "endpoint"
}

# Approvers are deliberately not managed here: they're set in Azure DevOps on each Environment's Approvals and checks.
resource "azuredevops_environment" "this" {
  for_each = var.environments

  project_id  = data.azuredevops_project.this.id
  name        = "${var.name_prefix}-${each.key}"
  description = "Deployment target for ${each.key}. Approvers are set here in Azure DevOps, not in Terraform."
}

resource "azuredevops_pipeline_authorization" "service_connection" {
  for_each = var.infra_pipeline_name == null ? {} : local.pipeline_identities

  project_id  = data.azuredevops_project.this.id
  resource_id = azuredevops_serviceendpoint_azurerm.pipeline[each.key].id
  type        = "endpoint"
  pipeline_id = data.azuredevops_build_definition.infra[0].id
}

resource "azuredevops_pipeline_authorization" "environment" {
  for_each = var.infra_pipeline_name == null ? {} : var.environments

  project_id  = data.azuredevops_project.this.id
  resource_id = azuredevops_environment.this[each.key].id
  type        = "environment"
  pipeline_id = data.azuredevops_build_definition.infra[0].id
}
