resource "azurerm_consumption_budget_resource_group" "this" {
  count = var.monthly_budget_amount > 0 ? 1 : 0

  name              = local.names.budget
  resource_group_id = data.azurerm_resource_group.this.id
  amount            = var.monthly_budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  lifecycle {
    precondition {
      condition     = var.budget_start_date != null && length(var.budget_alert_emails) > 0
      error_message = "budget_start_date and at least one budget_alert_emails entry are required when monthly_budget_amount is set."
    }
  }
}
