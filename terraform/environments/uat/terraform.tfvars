subscription_id = "290386d7-b5ac-433a-8c4c-db95cc6c36b4"
# East US 2 refuses new Azure SQL servers and has no App Service Basic quota for this subscription.
location    = "centralus"
environment = "uat"

allowed_ip_addresses = ["136.55.198.208"]

# From the sql_admin_group_object_ids output of bootstrap/terraform.
sql_admin_group_name      = "andes-softsol-sg-sql-admins-uat"
sql_admin_group_object_id = "439b2a7c-4fb9-4e44-861e-be385078b8d6"

developer_principal_ids = []

# 10.100-10.104 avoid every Windows App Service worker infrastructure range Microsoft lists
# (overview-vnet-integration#windows-worker-ip-address-overlap); 10.10/10.11 would break private endpoints on B1.
vnet_address_space     = "10.102.0.0/24"
app_service_plan_sku   = "B1"
aspnetcore_environment = "UAT"

log_analytics_daily_quota_gb = 1

key_vault_soft_delete_retention_days = 7
key_vault_purge_protection_enabled   = false

storage_replication_type = "GRS"
storage_containers       = []
# storage_containers = ["uploads"]

sql_database_sku              = "Basic"
sql_database_max_size_gb      = 2
sql_backup_storage_redundancy = "Local"

cosmos_serverless    = true
cosmos_database_name = "andes"
cosmos_containers    = {}
# cosmos_containers = {
#   orders = { partition_key_paths = ["/customerId"] }
# }

# monthly_budget_amount = 50
# budget_start_date     = "2026-10-01T00:00:00Z"
# budget_alert_emails   = ["someone@example.com"]
