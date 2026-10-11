output "service_connection_ids" {
  description = "Plan and apply service connection IDs per environment, for pipelines/infra-pipeline.yml."
  value = {
    for env in keys(var.environments) : env => {
      plan  = azuredevops_serviceendpoint_azurerm.pipeline["${env}-plan"].id
      apply = azuredevops_serviceendpoint_azurerm.pipeline["${env}-apply"].id
    }
  }
}

output "sql_admin_group_object_ids" {
  description = "SQL admin Entra group object ID per environment, for sql_admin_group_object_id in terraform/environments/<env>/terraform.tfvars."
  value       = { for env, group in azuread_group.sql_admins : env => group.object_id }
}
