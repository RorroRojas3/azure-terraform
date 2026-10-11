locals {
  # Hash of the resource group ID: stable across state loss and re-applies, yet unique per subscription and environment.
  suffix = substr(sha1(data.azurerm_resource_group.this.id), 0, 4)

  names = {
    log_analytics   = "${var.name_prefix}-log-${var.environment}"
    app_insights    = "${var.name_prefix}-appi-${var.environment}"
    api_identity    = "${var.name_prefix}-id-api-${var.environment}"
    vnet            = "${var.name_prefix}-vnet-${var.environment}"
    api_subnet      = "${var.name_prefix}-snet-api-${var.environment}"
    service_plan    = "${var.name_prefix}-asp-${var.environment}"
    api_app         = "${var.name_prefix}-api-${var.environment}-${local.suffix}"
    ui_app          = "${var.name_prefix}-ui-${var.environment}-${local.suffix}"
    key_vault       = "${var.name_prefix}-kv-${var.environment}-${local.suffix}"
    storage_account = "${var.name_prefix}st${var.environment}${local.suffix}"
    sql_server      = "${var.name_prefix}-sql-${var.environment}-${local.suffix}"
    sql_database    = "${var.name_prefix}-sqldb-${var.environment}"
    cosmos_account  = "${var.name_prefix}-cosmos-${var.environment}-${local.suffix}"
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
