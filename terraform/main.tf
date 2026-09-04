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
