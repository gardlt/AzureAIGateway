# State-address remaps for the module split into ai-gateway/mcp/agent
# (ARB-topic grouping). No resource is destroyed/recreated — every block here
# only tells Terraform the same object now lives at a new address. Safe to
# delete once everyone's state has picked up the move (next `terraform apply`
# after this ships), but harmless to leave in place.

# ---- ai-gateway ----

moved {
  from = data.azurerm_client_config.current
  to   = module.ai_gateway.data.azurerm_client_config.current
}

moved {
  from = azurerm_resource_group.gateway
  to   = module.ai_gateway.azurerm_resource_group.gateway
}

moved {
  from = azurerm_log_analytics_workspace.gateway
  to   = module.ai_gateway.azurerm_log_analytics_workspace.gateway
}

moved {
  from = azurerm_application_insights.gateway
  to   = module.ai_gateway.azurerm_application_insights.gateway
}

moved {
  from = azurerm_api_management.gateway
  to   = module.ai_gateway.azurerm_api_management.gateway
}

moved {
  from = azurerm_api_management_logger.app_insights
  to   = module.ai_gateway.azurerm_api_management_logger.app_insights
}

moved {
  from = azurerm_api_management_diagnostic.app_insights
  to   = module.ai_gateway.azurerm_api_management_diagnostic.app_insights
}

moved {
  from = azurerm_consumption_budget_resource_group.apim
  to   = module.ai_gateway.azurerm_consumption_budget_resource_group.apim
}

moved {
  from = azurerm_cognitive_account.openai
  to   = module.ai_gateway.azurerm_cognitive_account.openai
}

moved {
  from = azurerm_cognitive_deployment.model
  to   = module.ai_gateway.azurerm_cognitive_deployment.model
}

moved {
  from = azurerm_role_assignment.apim_openai_user
  to   = module.ai_gateway.azurerm_role_assignment.apim_openai_user
}

moved {
  from = azurerm_api_management_api.llm
  to   = module.ai_gateway.azurerm_api_management_api.llm
}

moved {
  from = azurerm_api_management_api_operation.llm_chat_completions
  to   = module.ai_gateway.azurerm_api_management_api_operation.llm_chat_completions
}

moved {
  from = azurerm_api_management_product.llm
  to   = module.ai_gateway.azurerm_api_management_product.llm
}

moved {
  from = azurerm_api_management_product_api.llm
  to   = module.ai_gateway.azurerm_api_management_product_api.llm
}

moved {
  from = azurerm_api_management_product_policy.llm
  to   = module.ai_gateway.azurerm_api_management_product_policy.llm
}

moved {
  from = azurerm_api_management_api_policy.llm
  to   = module.ai_gateway.azurerm_api_management_api_policy.llm
}

moved {
  from = azurerm_api_management_api.a2a
  to   = module.ai_gateway.azurerm_api_management_api.a2a
}

moved {
  from = azurerm_api_management_api_operation.a2a_agent_card
  to   = module.ai_gateway.azurerm_api_management_api_operation.a2a_agent_card
}

moved {
  from = azurerm_api_management_api_operation.a2a_jsonrpc
  to   = module.ai_gateway.azurerm_api_management_api_operation.a2a_jsonrpc
}

moved {
  from = azurerm_api_management_product.a2a
  to   = module.ai_gateway.azurerm_api_management_product.a2a
}

moved {
  from = azurerm_api_management_product_api.a2a
  to   = module.ai_gateway.azurerm_api_management_product_api.a2a
}

moved {
  from = azurerm_api_management_api_policy.a2a
  to   = module.ai_gateway.azurerm_api_management_api_policy.a2a
}

# ---- mcp ----

moved {
  from = random_uuid.mcp_scope_id
  to   = module.mcp.random_uuid.mcp_scope_id
}

moved {
  from = random_uuid.mcp_role_id
  to   = module.mcp.random_uuid.mcp_role_id
}

moved {
  from = azuread_application.mcp_server
  to   = module.mcp.azuread_application.mcp_server
}

moved {
  from = azuread_service_principal.mcp_server
  to   = module.mcp.azuread_service_principal.mcp_server
}

moved {
  from = azuread_application.mcp_client_interactive
  to   = module.mcp.azuread_application.mcp_client_interactive
}

moved {
  from = azuread_service_principal.mcp_client_interactive
  to   = module.mcp.azuread_service_principal.mcp_client_interactive
}

moved {
  from = azuread_service_principal_delegated_permission_grant.interactive_consent
  to   = module.mcp.azuread_service_principal_delegated_permission_grant.interactive_consent
}

moved {
  from = azuread_application.mcp_client_agent
  to   = module.mcp.azuread_application.mcp_client_agent
}

moved {
  from = azuread_service_principal.mcp_client_agent
  to   = module.mcp.azuread_service_principal.mcp_client_agent
}

moved {
  from = time_offset.agent_secret_expiry
  to   = module.mcp.time_offset.agent_secret_expiry
}

moved {
  from = azuread_application_password.mcp_client_agent
  to   = module.mcp.azuread_application_password.mcp_client_agent
}

moved {
  from = azuread_app_role_assignment.agent_role
  to   = module.mcp.azuread_app_role_assignment.agent_role
}

moved {
  from = azurerm_container_app_environment.mcp
  to   = module.mcp.azurerm_container_app_environment.mcp
}

moved {
  from = azurerm_container_app.mcp_server
  to   = module.mcp.azurerm_container_app.mcp_server
}

moved {
  from = azurerm_api_management_api.mcp_server
  to   = module.mcp.azurerm_api_management_api.mcp_server
}

moved {
  from = azurerm_api_management_api_operation.mcp_invoke
  to   = module.mcp.azurerm_api_management_api_operation.mcp_invoke
}

moved {
  from = azurerm_api_management_api_operation.prm
  to   = module.mcp.azurerm_api_management_api_operation.prm
}

moved {
  from = azurerm_api_management_named_value.mcp_url
  to   = module.mcp.azurerm_api_management_named_value.mcp_url
}

moved {
  from = azurerm_api_management_named_value.tenant_id
  to   = module.mcp.azurerm_api_management_named_value.tenant_id
}

moved {
  from = azurerm_api_management_named_value.interactive_client_id
  to   = module.mcp.azurerm_api_management_named_value.interactive_client_id
}

moved {
  from = azurerm_api_management_named_value.agent_client_id
  to   = module.mcp.azurerm_api_management_named_value.agent_client_id
}

moved {
  from = azurerm_api_management_named_value.resource_app_id
  to   = module.mcp.azurerm_api_management_named_value.resource_app_id
}

moved {
  from = azurerm_api_management_api_policy.mcp_server
  to   = module.mcp.azurerm_api_management_api_policy.mcp_server
}

moved {
  from = azurerm_api_management_api_operation_policy.prm
  to   = module.mcp.azurerm_api_management_api_operation_policy.prm
}

moved {
  from = azurerm_container_registry.gateway
  to   = module.mcp.azurerm_container_registry.gateway
}

moved {
  from = azurerm_role_assignment.mcp_acr_pull
  to   = module.mcp.azurerm_role_assignment.mcp_acr_pull
}

moved {
  from = azurerm_api_management_named_value.entra_authorize_endpoint
  to   = module.mcp.azurerm_api_management_named_value.entra_authorize_endpoint
}

moved {
  from = azurerm_api_management_named_value.entra_token_endpoint
  to   = module.mcp.azurerm_api_management_named_value.entra_token_endpoint
}

moved {
  from = azurerm_api_management_named_value.entra_issuer
  to   = module.mcp.azurerm_api_management_named_value.entra_issuer
}

moved {
  from = azurerm_api_management_api.oauth_facade
  to   = module.mcp.azurerm_api_management_api.oauth_facade
}

moved {
  from = azurerm_api_management_api_operation.oauth_metadata
  to   = module.mcp.azurerm_api_management_api_operation.oauth_metadata
}

moved {
  from = azurerm_api_management_api_operation_policy.oauth_metadata
  to   = module.mcp.azurerm_api_management_api_operation_policy.oauth_metadata
}

moved {
  from = azurerm_api_management_api_operation.oauth_authorize
  to   = module.mcp.azurerm_api_management_api_operation.oauth_authorize
}

moved {
  from = azurerm_api_management_api_operation_policy.oauth_authorize
  to   = module.mcp.azurerm_api_management_api_operation_policy.oauth_authorize
}

moved {
  from = azurerm_api_management_api_operation.oauth_token
  to   = module.mcp.azurerm_api_management_api_operation.oauth_token
}

moved {
  from = azurerm_api_management_api_operation_policy.oauth_token
  to   = module.mcp.azurerm_api_management_api_operation_policy.oauth_token
}
