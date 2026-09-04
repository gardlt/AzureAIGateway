output "apim_gateway_url" {
  value = azurerm_api_management.gateway.gateway_url
}

output "apim_public_ip" {
  description = "Null on Basic v2 / Standard v2 — no static public IP without Premium v2 + NAT Gateway. See mcp-server.tf for how the MCP container app handles this."
  value       = try(azurerm_api_management.gateway.public_ip_addresses[0], null)
}

output "apim_budget_id" {
  value = azurerm_consumption_budget_resource_group.apim.id
}

output "mcp_server_url" {
  description = "This must equal var.mcp_url exactly (doc 3 prereqs)."
  value       = "${azurerm_api_management.gateway.gateway_url}/${var.mcp_base_path}/mcp"
}

output "mcp_container_app_fqdn" {
  value = azurerm_container_app.mcp_server.ingress[0].fqdn
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "mcp_server_app_id" {
  description = "$APP_ID from doc 3 — the MCP server's Application (client) ID."
  value       = azuread_application.mcp_server.client_id
}

output "mcp_client_interactive_id" {
  value = azuread_application.mcp_client_interactive.client_id
}

output "mcp_client_agent_id" {
  value = azuread_application.mcp_client_agent.client_id
}

output "mcp_client_agent_secret" {
  sensitive = true
  value     = azuread_application_password.mcp_client_agent.value
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
