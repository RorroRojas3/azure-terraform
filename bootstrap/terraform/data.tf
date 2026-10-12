data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

data "azuredevops_project" "this" {
  name = var.azure_devops_project
}

# Created by bootstrap/New-TfStateBackend.ps1, which has to exist before any Terraform state can.
data "azurerm_storage_account" "state" {
  name                = local.state_storage_account_name
  resource_group_name = local.state_resource_group_name
}

data "azurerm_role_definition" "assignable" {
  for_each = toset(var.assignable_role_names)

  name  = each.value
  scope = data.azurerm_subscription.current.id
}

data "azuredevops_users" "approver" {
  for_each = toset(flatten([for env in values(var.environments) : env.approver_emails]))

  principal_name = each.value
}

# The pipeline is created once by hand (it needs the Azure Pipelines GitHub app); after that, resources are
# pre-authorized for it so runs don't stop at "needs permission".
data "azuredevops_build_definition" "infra" {
  count = var.infra_pipeline_name == null ? 0 : 1

  project_id = data.azuredevops_project.this.id
  name       = var.infra_pipeline_name
}
