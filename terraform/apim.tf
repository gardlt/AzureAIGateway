# Doc 1 — APIM instance, v2 tier (AI Gateway capabilities: MCP servers, LLM APIs, A2A APIs).

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
