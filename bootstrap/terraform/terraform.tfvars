subscription_id = "290386d7-b5ac-433a-8c4c-db95cc6c36b4"
location        = "eastus2"

azure_devops_org_url = "https://dev.azure.com/REPLACE-WITH-ORGANIZATION"
azure_devops_project = "REPLACE-WITH-PROJECT"

# Uncomment once the pipeline exists in Azure DevOps, then apply again to pre-authorize it.
# infra_pipeline_name = "andes-infra"

entra_group_owner_object_ids = ["4ee09cb0-d7e7-4be4-b82f-2674695eb9df"]

environments = {
  dev = {
    sql_admin_member_object_ids  = ["4ee09cb0-d7e7-4be4-b82f-2674695eb9df"]
    state_contributor_object_ids = ["4ee09cb0-d7e7-4be4-b82f-2674695eb9df"]
  }

  # prod = {
  #   sql_admin_member_object_ids = ["4ee09cb0-d7e7-4be4-b82f-2674695eb9df"]
  #   approver_emails             = ["rorro.irg@gmail.com"]
  #   requester_can_approve       = true
  # }
}
