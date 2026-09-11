# Root — wires the three ARB-topic modules together. See arb/ for the
# decision briefs behind this split: ai-gateway (docs 1, 5, 6), mcp (docs 2,
# 3), agent (docs 4, 7, 8).

module "ai_gateway" {
  source = "./modules/ai-gateway"

  resource_group_name = var.resource_group_name
  location            = var.location
  environment         = var.environment
  tags                = var.tags

  apim_name                = var.apim_name
  apim_publisher_name      = var.apim_publisher_name
  apim_publisher_email     = var.apim_publisher_email
  apim_sku_name            = var.apim_sku_name
  apim_monthly_budget_usd  = var.apim_monthly_budget_usd
  apim_budget_alert_emails = var.apim_budget_alert_emails

  enable_llm_gateway         = var.enable_llm_gateway
  openai_account_name        = var.openai_account_name
  openai_sku_name            = var.openai_sku_name
  openai_deployment_name     = var.openai_deployment_name
  openai_model_name          = var.openai_model_name
  openai_model_version       = var.openai_model_version
  llm_tokens_per_minute      = var.llm_tokens_per_minute
  llm_token_quota_per_period = var.llm_token_quota_per_period
  llm_token_quota_period     = var.llm_token_quota_period

  enable_a2a_gateway            = var.enable_a2a_gateway
  a2a_agent_runtime_url         = var.a2a_agent_runtime_url
  a2a_base_path                 = var.a2a_base_path
  a2a_rate_limit_calls          = var.a2a_rate_limit_calls
  a2a_rate_limit_period_seconds = var.a2a_rate_limit_period_seconds
}

module "agent" {
  source = "./modules/agent"

  resource_group_name        = module.ai_gateway.resource_group_name
  location                   = module.ai_gateway.location
  environment                = var.environment
  tags                       = var.tags
  tenant_id                  = module.ai_gateway.tenant_id
  log_analytics_workspace_id = module.ai_gateway.log_analytics_workspace_id

  foundry_agent_client_ids          = var.foundry_agent_client_ids
  self_hosted_agent_container_image = var.self_hosted_agent_container_image
  self_hosted_agent_target_port     = var.self_hosted_agent_target_port
  aoai_endpoint                     = var.self_hosted_agent_aoai_endpoint
  aoai_deployment_name              = var.self_hosted_agent_aoai_deployment_name
}

module "mcp" {
  source = "./modules/mcp"

  resource_group_name        = module.ai_gateway.resource_group_name
  location                   = module.ai_gateway.location
  environment                = var.environment
  tags                       = var.tags
  apim_name                  = module.ai_gateway.apim_name
  apim_gateway_url           = module.ai_gateway.apim_gateway_url
  tenant_id                  = module.ai_gateway.tenant_id
  log_analytics_workspace_id = module.ai_gateway.log_analytics_workspace_id
  apim_public_ip             = module.ai_gateway.apim_public_ip

  mcp_url                          = var.mcp_url
  mcp_base_path                    = var.mcp_base_path
  interactive_client_redirect_uris = var.interactive_client_redirect_uris
  mcp_container_image              = var.mcp_container_image
  mcp_target_port                  = var.mcp_target_port
  mcp_cors_allowed_origins         = var.mcp_cors_allowed_origins
  foundry_agent_client_ids         = module.agent.foundry_agent_client_ids
}
