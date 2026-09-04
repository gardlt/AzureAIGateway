# Cost cap on the AI gateway resource group — $100/month default. azurerm has
# no resource-scoped consumption budget (only management-group/RG/subscription),
# and APIM is the dominant cost driver in this RG, so the budget is scoped
# to azurerm_resource_group.gateway. Consumption Budgets alert, they don't
# auto-stop the resource — this is a notification tripwire, not enforcement.
# Pair with a low apim_sku_name (BasicV2_1) to keep baseline spend under the cap.

locals {
  budget_alert_emails = length(var.apim_budget_alert_emails) > 0 ? var.apim_budget_alert_emails : [var.apim_publisher_email]
  # First day of the current month, UTC — azurerm requires a month-aligned start_date.
  budget_start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())
}

resource "azurerm_consumption_budget_resource_group" "apim" {
  name              = "budget-apim-${var.environment}"
  resource_group_id = azurerm_resource_group.gateway.id

  amount     = var.apim_monthly_budget_usd
  time_grain = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = local.budget_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = local.budget_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = local.budget_alert_emails
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}
