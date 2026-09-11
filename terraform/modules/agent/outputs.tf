output "foundry_agent_client_ids" {
  value = var.foundry_agent_client_ids
}

output "self_hosted_agent_app_id_uri" {
  description = "audience Foundry's outbound A2A connection (--audience) must request tokens for — doc 9 §9.4."
  value       = local.self_hosted_agent_app_id_uri
}

output "self_hosted_agent_client_id" {
  value = azuread_application.self_hosted_agent.client_id
}

output "self_hosted_agent_uami_client_id" {
  value = azurerm_user_assigned_identity.self_hosted_agent.client_id
}

output "self_hosted_agent_uami_principal_id" {
  value = azurerm_user_assigned_identity.self_hosted_agent.principal_id
}

output "self_hosted_agent_fqdn" {
  value = azurerm_container_app.self_hosted_agent.ingress[0].fqdn
}

output "self_hosted_agent_acr_login_server" {
  description = "Build/push with: az acr build --registry <this> --image self-hosted-a2a-agent:latest ../self-hosted-agent"
  value       = azurerm_container_registry.agent.login_server
}
