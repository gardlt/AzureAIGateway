# Doc 5 — expose an LLM model through the same APIM instance, with per-consumer
# token budgets, rate limits, and metric emission. Independent of the MCP server.

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
