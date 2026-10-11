variable "subscription_id" {
  description = "Subscription that hosts the environments and the Terraform state account."
  type        = string
}

variable "location" {
  description = "Azure region for the environment resource groups."
  type        = string
}

variable "name_prefix" {
  description = "Company prefix that starts every resource name; must match the environments' name_prefix."
  type        = string
  default     = "andes"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.name_prefix))
    error_message = "name_prefix must be 2-8 lowercase letters or digits."
  }
}

variable "azure_devops_org_url" {
  description = "Azure DevOps organization URL, e.g. https://dev.azure.com/contoso."
  type        = string

  validation {
    condition     = can(regex("^https://dev[.]azure[.]com/[^/]+/?$", var.azure_devops_org_url))
    error_message = "azure_devops_org_url must look like https://dev.azure.com/<organization>."
  }
}

variable "azure_devops_project" {
  description = "Azure DevOps project that runs pipelines/infra-pipeline.yml."
  type        = string
}

variable "infra_pipeline_name" {
  description = "Name of the infrastructure pipeline in Azure DevOps. Set it once the pipeline exists to pre-authorize its service connections, variable groups and environments; null skips authorization."
  type        = string
  default     = null
}

variable "entra_group_owner_object_ids" {
  description = "Owners of the SQL admin Entra groups. Without explicit owners, whoever runs apply becomes the sole owner."
  type        = list(string)

  validation {
    condition     = length(var.entra_group_owner_object_ids) > 0 && alltrue([for id in var.entra_group_owner_object_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "entra_group_owner_object_ids must contain at least one Entra object ID (GUID)."
  }
}

variable "assignable_role_names" {
  description = "The only Azure roles an environment's apply identity may assign. Every role terraform/ assigns must be listed here."
  type        = list(string)
  default = [
    "Key Vault Secrets Officer",
    "Key Vault Secrets User",
    "Monitoring Metrics Publisher",
    "Storage Blob Data Contributor",
    "Storage Blob Data Reader",
  ]
}

variable "environments" {
  description = <<-EOT
    Environments keyed by name (dev, qa, uat, staging, prod). Per environment:
    sql_admin_member_object_ids: people added to the SQL admin Entra group (the apply identity is always a member).
    state_contributor_object_ids: people who may run Terraform locally against the environment's state.
    approver_emails: Azure DevOps users who must approve each apply; empty means no approval (fine for dev).
    requester_can_approve: let whoever triggered the run approve it; needed when one person both merges and approves.
  EOT
  type = map(object({
    sql_admin_member_object_ids  = optional(list(string), [])
    state_contributor_object_ids = optional(list(string), [])
    approver_emails              = optional(list(string), [])
    requester_can_approve        = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for env in keys(var.environments) : can(regex("^[a-z]{2,7}$", env))])
    error_message = "Environment names must be 2-7 lowercase letters so Key Vault and Storage names stay within 24 characters."
  }
}
