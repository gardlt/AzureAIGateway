output "apim_gateway_url" {
  value = module.ai_gateway.apim_gateway_url
}

output "apim_public_ip" {
  description = "Null on Basic v2 / Standard v2 — no static public IP without Premium v2 + NAT Gateway. See mcp-server.tf for how the MCP container app handles this."
  value       = module.ai_gateway.apim_public_ip
}

output "apim_budget_id" {
  value = module.ai_gateway.apim_budget_id
}

output "mcp_server_url" {
  description = "This must equal var.mcp_url exactly (doc 3 prereqs)."
  value       = module.mcp.mcp_server_url
}

output "mcp_container_app_fqdn" {
  value = module.mcp.mcp_container_app_fqdn
}

output "acr_login_server" {
  description = "Build/push with: az acr build --registry <this> --image mcp-server:latest ../mcp-server"
  value       = module.mcp.acr_login_server
}

output "tenant_id" {
  value = module.ai_gateway.tenant_id
}

output "mcp_server_app_id" {
  description = "$APP_ID from doc 3 — the MCP server's Application (client) ID."
  value       = module.mcp.mcp_server_app_id
}

output "mcp_client_interactive_id" {
  value = module.mcp.mcp_client_interactive_id
}

output "mcp_client_agent_id" {
  value = module.mcp.mcp_client_agent_id
}

output "mcp_client_agent_secret" {
  sensitive = true
  value     = module.mcp.mcp_client_agent_secret
}

output "openai_endpoint" {
  value = module.ai_gateway.openai_endpoint
}

output "llm_gateway_path" {
  value = module.ai_gateway.llm_gateway_path
}

output "a2a_gateway_path" {
  value = module.ai_gateway.a2a_gateway_path
}
