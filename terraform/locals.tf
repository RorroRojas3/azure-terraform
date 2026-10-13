locals {
  # Web app, Key Vault, Storage, SQL server and Cosmos DB names are globally unique across Azure; check a new
  # environment's names are free before adding it (andes-kv-uat, for one, is already taken).
  names = {
    log_analytics   = "${var.name_prefix}-log-${var.environment}"
    app_insights    = "${var.name_prefix}-appi-${var.environment}"
    api_identity    = "${var.name_prefix}-id-api-${var.environment}"
    vnet            = "${var.name_prefix}-vnet-${var.environment}"
    api_subnet      = "${var.name_prefix}-snet-api-${var.environment}"
    service_plan    = "${var.name_prefix}-asp-${var.environment}"
    api_app         = "${var.name_prefix}-api-${var.environment}"
    ui_app          = "${var.name_prefix}-ui-${var.environment}"
    key_vault       = "${var.name_prefix}-kv-${var.environment}"
    storage_account = "${var.name_prefix}st${var.environment}"
    sql_server      = "${var.name_prefix}-sql-${var.environment}"
    sql_database    = "${var.name_prefix}-sqldb-${var.environment}"
    cosmos_account  = "${var.name_prefix}-cosmos-${var.environment}"
    budget          = "${var.name_prefix}-budget-${var.environment}"
  }

  tags = merge(var.tags, {
    company     = var.name_prefix
    environment = var.environment
    managed-by  = "terraform"
  })

  allowed_cidrs = [for ip in var.allowed_ip_addresses : strcontains(ip, "/") ? ip : "${ip}/32"]

  # Key Vault, Storage and Cosmos DB store single addresses without "/32" (Storage rejects it), so this avoids perpetual diffs.
  firewall_ip_rules = [for cidr in local.allowed_cidrs : trimsuffix(cidr, "/32")]

  sql_firewall_rules = {
    for cidr in local.allowed_cidrs : replace(replace(cidr, ".", "-"), "/", "_") => {
      start = cidrhost(cidr, 0)
      end   = cidrhost(cidr, -1)
    }
  }
}
