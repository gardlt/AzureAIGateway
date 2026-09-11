# AI Gateway module — docs 1, 5, 6. Owns the shared resource group, log
# analytics/app insights, the APIM instance itself, its cost budget, the LLM
# gateway (doc 5), and the A2A agent gateway (doc 6).

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "gateway" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "gateway" {
  name                = "log-ai-gateway-${var.environment}"
  resource_group_name = azurerm_resource_group.gateway.name
  location            = azurerm_resource_group.gateway.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "gateway" {
  name                = "appi-ai-gateway-${var.environment}"
  resource_group_name = azurerm_resource_group.gateway.name
  location            = azurerm_resource_group.gateway.location
  workspace_id        = azurerm_log_analytics_workspace.gateway.id
  application_type    = "web"
  tags                = var.tags
}

# ---- Doc 1 — APIM instance, v2 tier ----

resource "azurerm_api_management" "gateway" {
  name                = var.apim_name
  resource_group_name = azurerm_resource_group.gateway.name
  location            = azurerm_resource_group.gateway.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku_name
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Doc 1 §1.5 — Application Insights logger + diagnostic, so MCP/LLM/A2A traffic
# (gen_ai.* attributes, llm-emit-token-metric) lands in the same workbook.
resource "azurerm_api_management_logger" "app_insights" {
  name                = "appi-logger"
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name

  application_insights {
    instrumentation_key = azurerm_application_insights.gateway.instrumentation_key
  }
}

resource "azurerm_api_management_diagnostic" "app_insights" {
  identifier               = "applicationinsights"
  resource_group_name      = azurerm_resource_group.gateway.name
  api_management_name      = azurerm_api_management.gateway.name
  api_management_logger_id = azurerm_api_management_logger.app_insights.id

  sampling_percentage       = 100.0
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"

  # doc 2 troubleshooting table: response-body logging breaks MCP streaming.
  frontend_response {
    body_bytes     = 0
    headers_to_log = ["Content-Type"]
  }
}

# ---- Cost cap on the AI gateway resource group — $100/month default ----
# azurerm has no resource-scoped consumption budget (only management-group/
# RG/subscription), and APIM is the dominant cost driver in this RG, so the
# budget is scoped to azurerm_resource_group.gateway. Consumption Budgets
# alert, they don't auto-stop the resource — a notification tripwire, not
# enforcement. Pair with a low apim_sku_name (BasicV2_1) to keep baseline
# spend under the cap.

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

# ---- Doc 5 — LLM gateway: expose an Azure OpenAI model through the same
# APIM instance, with per-consumer token budgets, rate limits, and metric
# emission. Independent of the MCP server. ----

resource "azurerm_cognitive_account" "openai" {
  count                 = var.enable_llm_gateway ? 1 : 0
  name                  = var.openai_account_name != "" ? var.openai_account_name : "aoai-${var.apim_name}"
  resource_group_name   = azurerm_resource_group.gateway.name
  location              = azurerm_resource_group.gateway.location
  kind                  = "OpenAI"
  sku_name              = var.openai_sku_name
  custom_subdomain_name = var.openai_account_name != "" ? var.openai_account_name : "aoai-${var.apim_name}"
  tags                  = var.tags
}

resource "azurerm_cognitive_deployment" "model" {
  count                = var.enable_llm_gateway ? 1 : 0
  name                 = var.openai_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai[0].id

  model {
    format  = "OpenAI"
    name    = var.openai_model_name
    version = var.openai_model_version
  }

  sku {
    name = "Standard"
  }
}

# APIM's managed identity calls the backend — no static key in policy XML.
resource "azurerm_role_assignment" "apim_openai_user" {
  count                = var.enable_llm_gateway ? 1 : 0
  scope                = azurerm_cognitive_account.openai[0].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.gateway.identity[0].principal_id
}

resource "azurerm_api_management_api" "llm" {
  count                 = var.enable_llm_gateway ? 1 : 0
  name                  = "llm-openai"
  resource_group_name   = azurerm_resource_group.gateway.name
  api_management_name   = azurerm_api_management.gateway.name
  revision              = "1"
  display_name          = "LLM (Azure OpenAI)"
  path                  = "llm"
  protocols             = ["https"]
  service_url           = azurerm_cognitive_account.openai[0].endpoint
  subscription_required = true
}

resource "azurerm_api_management_api_operation" "llm_chat_completions" {
  count               = var.enable_llm_gateway ? 1 : 0
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.llm[0].name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "Chat completions"
  method              = "POST"
  url_template        = "/openai/deployments/{deployment-id}/chat/completions"

  template_parameter {
    name     = "deployment-id"
    type     = "string"
    required = true
  }
}

# Product = the budget/rate-limit boundary per consumer/app/team (doc 5 §5.2).
resource "azurerm_api_management_product" "llm" {
  count                 = var.enable_llm_gateway ? 1 : 0
  product_id            = "llm-gateway"
  resource_group_name   = azurerm_resource_group.gateway.name
  api_management_name   = azurerm_api_management.gateway.name
  display_name          = "LLM Gateway"
  subscription_required = true
  approval_required     = true
  published             = true
}

resource "azurerm_api_management_product_api" "llm" {
  count               = var.enable_llm_gateway ? 1 : 0
  product_id          = azurerm_api_management_product.llm[0].product_id
  api_name            = azurerm_api_management_api.llm[0].name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
}

# 5.3–5.4 — token-aware rate limit + product-level token budget.
resource "azurerm_api_management_product_policy" "llm" {
  count               = var.enable_llm_gateway ? 1 : 0
  product_id          = azurerm_api_management_product.llm[0].product_id
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <llm-token-limit
        counter-key="@(context.Subscription.Id)"
        tokens-per-minute="${var.llm_tokens_per_minute}"
        estimate-prompt-tokens="true"
        remaining-tokens-variable-name="remainingTokens" />
    <llm-token-limit
        counter-key="@(context.Subscription.Id)"
        token-quota="${var.llm_token_quota_per_period}"
        token-quota-period="${var.llm_token_quota_period}" />
    <llm-emit-token-metric namespace="llm-metrics">
      <dimension name="Product" value="@(context.Product.Name)" />
      <dimension name="Subscription" value="@(context.Subscription.Id)" />
      <dimension name="API" value="@(context.Api.Id)" />
    </llm-emit-token-metric>
  </inbound>
</policies>
XML
}

resource "azurerm_api_management_api_policy" "llm" {
  count               = var.enable_llm_gateway ? 1 : 0
  api_name            = azurerm_api_management_api.llm[0].name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
  </inbound>
</policies>
XML
}

# ---- Doc 6 §6.3–6.5 — import an existing A2A agent as an APIM API,
# subscription-key secured, rate-limited. Optional, standalone (no Foundry
# project required). ----

resource "azurerm_api_management_api" "a2a" {
  count                 = var.enable_a2a_gateway ? 1 : 0
  name                  = "a2a-agent"
  resource_group_name   = azurerm_resource_group.gateway.name
  api_management_name   = azurerm_api_management.gateway.name
  revision              = "1"
  display_name          = "A2A Agent"
  path                  = var.a2a_base_path
  protocols             = ["https"]
  service_url           = var.a2a_agent_runtime_url
  subscription_required = true
}

resource "azurerm_api_management_api_operation" "a2a_agent_card" {
  count               = var.enable_a2a_gateway ? 1 : 0
  operation_id        = "agent-card"
  api_name            = azurerm_api_management_api.a2a[0].name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "Agent card"
  method              = "GET"
  url_template        = "/.well-known/agent-card.json"
}

resource "azurerm_api_management_api_operation" "a2a_jsonrpc" {
  count               = var.enable_a2a_gateway ? 1 : 0
  operation_id        = "jsonrpc"
  api_name            = azurerm_api_management_api.a2a[0].name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "JSON-RPC"
  method              = "POST"
  url_template        = "/"
}

resource "azurerm_api_management_product" "a2a" {
  count                 = var.enable_a2a_gateway ? 1 : 0
  product_id            = "a2a-gateway"
  resource_group_name   = azurerm_resource_group.gateway.name
  api_management_name   = azurerm_api_management.gateway.name
  display_name          = "A2A Gateway"
  subscription_required = true
  approval_required     = true
  published             = true
}

resource "azurerm_api_management_product_api" "a2a" {
  count               = var.enable_a2a_gateway ? 1 : 0
  product_id          = azurerm_api_management_product.a2a[0].product_id
  api_name            = azurerm_api_management_api.a2a[0].name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
}

# 6.5 — rate limiting. Add <llm-content-safety> here if the target agent's
# backend accepts a content-safety backend-id.
resource "azurerm_api_management_api_policy" "a2a" {
  count               = var.enable_a2a_gateway ? 1 : 0
  api_name            = azurerm_api_management_api.a2a[0].name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <rate-limit-by-key calls="${var.a2a_rate_limit_calls}" renewal-period="${var.a2a_rate_limit_period_seconds}" counter-key="@(context.Subscription.Id)" />
  </inbound>
</policies>
XML
}
