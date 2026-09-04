# Doc 6 §6.3–6.5 — import an existing A2A agent as an APIM API, subscription-key
# secured, rate-limited. Optional, standalone (no Foundry project required).

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
