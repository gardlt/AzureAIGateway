output "resource_group_name" {
  value = azurerm_resource_group.gateway.name
}

output "resource_group_id" {
  value = azurerm_resource_group.gateway.id
}

output "location" {
  value = azurerm_resource_group.gateway.location
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.gateway.id
}

output "apim_id" {
  value = azurerm_api_management.gateway.id
}

output "apim_name" {
  value = azurerm_api_management.gateway.name
}

output "apim_gateway_url" {
  value = azurerm_api_management.gateway.gateway_url
}

output "apim_public_ip" {
  description = "Null on Basic v2 / Standard v2 — no static public IP without Premium v2 + NAT Gateway. See the mcp module for how the MCP container app handles this."
  value       = try(azurerm_api_management.gateway.public_ip_addresses[0], null)
}

output "apim_identity_principal_id" {
  value = azurerm_api_management.gateway.identity[0].principal_id
}

output "apim_budget_id" {
  value = azurerm_consumption_budget_resource_group.apim.id
}

output "openai_endpoint" {
  value = var.enable_llm_gateway ? azurerm_cognitive_account.openai[0].endpoint : null
}

output "llm_gateway_path" {
  value = var.enable_llm_gateway ? "${azurerm_api_management.gateway.gateway_url}/llm" : null
}

output "a2a_gateway_path" {
  value = var.enable_a2a_gateway ? "${azurerm_api_management.gateway.gateway_url}/${var.a2a_base_path}" : null
}
