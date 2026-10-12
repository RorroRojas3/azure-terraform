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

# Checks live on the apply connection rather than the Environment: YAML can skip an Environment, but it can't
# use a service connection without passing that connection's checks.
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

resource "azuredevops_check_approval" "apply" {
  for_each = { for env, config in var.environments : env => config if length(config.approver_emails) > 0 }

  project_id            = data.azuredevops_project.this.id
  target_resource_id    = azuredevops_serviceendpoint_azurerm.pipeline["${each.key}-apply"].id
  target_resource_type  = "endpoint"
  approvers             = [for email in each.value.approver_emails : one(data.azuredevops_users.approver[email].users).id]
  requester_can_approve = each.value.requester_can_approve
}

resource "azuredevops_environment" "this" {
  for_each = var.environments

  project_id  = data.azuredevops_project.this.id
  name        = "${var.name_prefix}-${each.key}"
  description = "Deployment history for ${each.key}. Approvals live on the apply service connection."
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
