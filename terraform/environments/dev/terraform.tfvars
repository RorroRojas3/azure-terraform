subscription_id = "290386d7-b5ac-433a-8c4c-db95cc6c36b4"
location        = "eastus2"
environment     = "dev"

# allowed_ip_addresses is deliberately not set here: it comes from TF_VAR_allowed_ip_addresses
# (your shell locally, the andes-vg-dev variable group in the pipeline).

# Printed by bootstrap/New-AppEnvironment.ps1 -Environment dev.
sql_admin_group_name      = "andes-sg-sql-admins-dev"
sql_admin_group_object_id = "REPLACE-WITH-BOOTSTRAP-OUTPUT"

developer_principal_ids = ["4ee09cb0-d7e7-4be4-b82f-2674695eb9df"]

vnet_address_space     = "10.10.0.0/24"
app_service_plan_sku   = "B1"
aspnetcore_environment = "Development"

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
