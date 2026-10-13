locals {
  # Must match Get-TfStateStorageAccountName and Get-TfStateResourceGroupName in bootstrap/BootstrapCommon.ps1.
  state_storage_account_name = "${var.name_prefix}sttfstate"
  state_resource_group_name  = "${var.name_prefix}-rg-tfstate"

  tags = {
    company    = var.name_prefix
    managed-by = "terraform-bootstrap"
  }

  # One identity and service connection per environment and role, keyed "<env>-plan" and "<env>-apply".
  pipeline_identities = {
    for pair in setproduct(keys(var.environments), ["plan", "apply"]) :
    "${pair[0]}-${pair[1]}" => {
      environment = pair[0]
      role        = pair[1]
    }
  }

  assignable_role_ids = join(", ", sort([for role in data.azurerm_role_definition.assignable : role.role_definition_id]))
}
