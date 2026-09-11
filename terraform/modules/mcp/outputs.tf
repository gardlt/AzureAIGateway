output "mcp_server_url" {
  description = "This must equal var.mcp_url exactly (doc 3 prereqs)."
  value       = "${var.apim_gateway_url}/${var.mcp_base_path}/mcp"
}

output "mcp_container_app_fqdn" {
  value = azurerm_container_app.mcp_server.ingress[0].fqdn
}

output "acr_login_server" {
  description = "Build/push with: az acr build --registry <this> --image mcp-server:latest ../mcp-server"
  value       = azurerm_container_registry.gateway.login_server
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
