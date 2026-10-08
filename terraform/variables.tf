variable "subscription_id" {
  description = "Subscription that hosts this environment."
  type        = string
}

variable "location" {
  description = "Azure region for every resource in this environment."
  type        = string
}

variable "name_prefix" {
  description = "Company prefix that starts every resource name."
  type        = string
  default     = "andes"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.name_prefix))
    error_message = "name_prefix must be 2-8 lowercase letters or digits so Key Vault and Storage names stay within 24 characters."
  }
}

variable "environment" {
  description = "Environment name, e.g. dev, qa, uat, staging, prod."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2,7}$", var.environment))
    error_message = "environment must be 2-7 lowercase letters so Key Vault and Storage names stay within 24 characters."
  }
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "allowed_ip_addresses" {
  description = "Public IPv4 addresses or CIDR ranges allowed through the Key Vault, Storage, SQL and Cosmos DB firewalls. Supplied through TF_VAR_allowed_ip_addresses, never tfvars, so personal IPs stay out of the repo; use [] to allow none."
  type        = list(string)
  sensitive   = true

  validation {
    condition = alltrue([
      for ip in var.allowed_ip_addresses :
      can(cidrnetmask(strcontains(ip, "/") ? ip : "${ip}/32")) && !endswith(ip, "/31")
    ])
    error_message = "Each entry must be an IPv4 address or CIDR range; /31 is rejected by Azure Storage."
  }

  # The value is hidden from plans, so this is the only review it gets. SQL and Cosmos DB read 0.0.0.0 as
  # "all Azure datacenters", and Storage rejects private ranges at apply time.
  validation {
    condition = alltrue([
      for ip in var.allowed_ip_addresses :
      !can(regex("^(0|10|127)\\.|^169\\.254\\.|^172\\.(1[6-9]|2[0-9]|3[01])\\.|^192\\.168\\.", ip))
    ])
    error_message = "Entries must be public addresses: 0.0.0.0/8, loopback, link-local and private (RFC 1918) ranges are not allowed."
  }
}

variable "sql_admin_group_name" {
  description = "Display name of the Entra security group that is the SQL server's Entra admin (created by bootstrap/New-AppEnvironment.ps1)."
  type        = string
}

variable "sql_admin_group_object_id" {
  description = "Object ID of the SQL admin Entra group."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.sql_admin_group_object_id))
    error_message = "sql_admin_group_object_id must be a GUID; copy it from the output of bootstrap/New-AppEnvironment.ps1."
  }
}

variable "developer_principal_ids" {
  description = "Entra object IDs granted data-plane access to Key Vault, Blob Storage and Cosmos DB for local debugging. Keep empty outside dev."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.developer_principal_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "developer_principal_ids must contain Entra object IDs (GUIDs)."
  }
}

variable "vnet_address_space" {
  description = "Address space of the environment VNet. Use a distinct /24 per environment so VNets can be peered later."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vnet_address_space)) && tonumber(split("/", var.vnet_address_space)[1]) <= 24
    error_message = "vnet_address_space must be an IPv4 CIDR of /24 or larger."
  }
}

variable "app_service_plan_sku" {
  description = "Linux App Service plan SKU shared by the API and UI. B1 is the cheapest tier with VNet integration and always-on."
  type        = string
  default     = "B1"
}

variable "aspnetcore_environment" {
  description = "Value of ASPNETCORE_ENVIRONMENT for the API."
  type        = string
}

variable "api_health_check_path" {
  description = "Health check path probed by App Service on the API. Set to null to disable."
  type        = string
  default     = "/health"
}

variable "api_cors_allowed_origins" {
  description = "Extra CORS origins for the API; the UI web app's own origin is always allowed."
  type        = list(string)
  default     = []
}

variable "ui_app_command_line" {
  description = "Startup command for the Angular UI web app."
  type        = string
  default     = "pm2 serve /home/site/wwwroot --no-daemon --spa"
}

variable "log_analytics_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

variable "log_analytics_daily_quota_gb" {
  description = "Daily ingestion cap in GB for Log Analytics; -1 means no cap."
  type        = number
  default     = -1
}

variable "key_vault_soft_delete_retention_days" {
  description = "Key Vault soft-delete retention (7-90 days)."
  type        = number
  default     = 90
}

variable "key_vault_purge_protection_enabled" {
  description = "Prevents permanent deletion of the vault during its retention period. Cannot be turned off once enabled."
  type        = bool
  default     = true
}

variable "storage_replication_type" {
  description = "Replication for the environment storage account."
  type        = string
  default     = "GRS"

  validation {
    condition     = contains(["GRS", "RAGRS", "GZRS", "RAGZRS"], var.storage_replication_type)
    error_message = "storage_replication_type must be geo-redundant: GRS, RAGRS, GZRS or RAGZRS."
  }
}

variable "storage_containers" {
  description = "Private blob containers to create in the environment storage account."
  type        = list(string)
  default     = []
}

variable "sql_database_sku" {
  description = "Azure SQL database SKU."
  type        = string
  default     = "Basic"
}

variable "sql_database_max_size_gb" {
  description = "Azure SQL database max size in GB (Basic allows up to 2)."
  type        = number
  default     = 2
}

variable "sql_backup_storage_redundancy" {
  description = "Backup storage redundancy for the SQL database: Local, Zone, Geo or GeoZone."
  type        = string
  default     = "Geo"
}

variable "sql_short_term_retention_days" {
  description = "Point-in-time restore retention in days (Basic allows 1-7)."
  type        = number
  default     = 7
}

variable "cosmos_serverless" {
  description = "Use Cosmos DB serverless capacity. When false, the database uses autoscale throughput."
  type        = bool
  default     = true
}

variable "cosmos_autoscale_max_throughput" {
  description = "Autoscale max RU/s shared by the database when cosmos_serverless is false."
  type        = number
  default     = 1000
}

variable "cosmos_database_name" {
  description = "Cosmos DB SQL database name."
  type        = string
}

variable "cosmos_containers" {
  description = "Cosmos DB containers keyed by name. Entra data-plane RBAC cannot create containers, so they must be declared here."
  type = map(object({
    partition_key_paths = list(string)
    default_ttl         = optional(number)
  }))
  default = {}
}

variable "monthly_budget_amount" {
  description = "Monthly cost budget for the environment resource group; 0 disables the budget."
  type        = number
  default     = 0
}

variable "budget_start_date" {
  description = "First day of the budget's first month, e.g. 2026-10-01T00:00:00Z."
  type        = string
  default     = null

  validation {
    condition     = var.budget_start_date == null || can(regex("^\\d{4}-\\d{2}-01T00:00:00Z$", var.budget_start_date))
    error_message = "budget_start_date must be the first day of a month in the form YYYY-MM-01T00:00:00Z."
  }
}

variable "budget_alert_emails" {
  description = "Recipients of budget alerts."
  type        = list(string)
  default     = []
}
