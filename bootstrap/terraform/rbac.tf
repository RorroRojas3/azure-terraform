locals {
  # Both of an environment's pipeline identities, which its apply identity must never grant roles to.
  pipeline_principal_ids = {
    for env in keys(var.environments) : env => join(", ", sort([
      azurerm_user_assigned_identity.pipeline["${env}-plan"].principal_id,
      azurerm_user_assigned_identity.pipeline["${env}-apply"].principal_id,
    ]))
  }

  state_contributors = merge([
    for env, config in var.environments : {
      for object_id in config.state_contributor_object_ids : "${env}-${object_id}" => {
        environment = env
        object_id   = object_id
      }
    }
  ]...)
}

# Plan identity: reads everything terraform/ refreshes, writes nothing, and can't lease state. Reader alone fails:
# azurerm 5.9 refreshes web apps and Cosmos DB accounts through these POST list calls and doesn't tolerate a 403.
# They return publishing credentials and Cosmos keys that basic auth and local auth being off make unusable, and
# that the state this identity already reads holds anyway. Storage and Log Analytics key listing is left out
# because the provider tolerates the 403, which keeps those keys out of plans.
resource "azurerm_role_definition" "plan_reader" {
  name        = "${var.name_prefix}-terraform-plan-reader"
  scope       = data.azurerm_subscription.current.id
  description = "Read-only access for terraform plan, plus the list actions the azurerm provider calls while refreshing."

  permissions {
    actions = [
      "*/read",
      "Microsoft.DocumentDB/databaseAccounts/listConnectionStrings/action",
      "Microsoft.DocumentDB/databaseAccounts/listKeys/action",
      "Microsoft.DocumentDB/databaseAccounts/readonlykeys/action",
      "Microsoft.Web/sites/config/list/action",
    ]
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

resource "azurerm_role_assignment" "plan_reader" {
  for_each = var.environments

  scope              = azurerm_resource_group.environment[each.key].id
  role_definition_id = azurerm_role_definition.plan_reader.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.pipeline["${each.key}-plan"].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "plan_state_reader" {
  for_each = var.environments

  scope                = azurerm_storage_container.state[each.key].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.pipeline["${each.key}-plan"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apply_contributor" {
  for_each = var.environments

  scope                = azurerm_resource_group.environment[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.pipeline["${each.key}-apply"].principal_id
  principal_type       = "ServicePrincipal"
}

# Constrained delegation: only the allowlisted roles, and never to the environment's own pipeline identities, so
# the pipeline can't grant itself Owner, Contributor, User Access Administrator or data-plane access.
resource "azurerm_role_assignment" "apply_rbac_administrator" {
  for_each = var.environments

  scope                = azurerm_resource_group.environment[each.key].id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.pipeline["${each.key}-apply"].principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition = trimspace(<<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_role_ids}}
      AND
      @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {${local.pipeline_principal_ids[each.key]}}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_role_ids}}
      AND
      @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {${local.pipeline_principal_ids[each.key]}}
     )
    )
  EOT
  )
}

resource "azurerm_role_assignment" "apply_state_contributor" {
  for_each = var.environments

  scope                = azurerm_storage_container.state[each.key].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.pipeline["${each.key}-apply"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "state_contributor" {
  for_each = local.state_contributors

  scope                = azurerm_storage_container.state[each.value.environment].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value.object_id
}
