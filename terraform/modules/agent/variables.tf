variable "foundry_agent_client_ids" {
  description = <<-EOT
    client_id (instance_identity.client_id) of each Foundry-managed agent
    identity (doc 7) allowed to call the MCP server through APIM, in
    addition to mcp-client-interactive and mcp-client-agent. Each Foundry
    agent gets its own auto-provisioned agent identity/client_id — add it
    here (not to mcp_client_agent) so validate-azure-ad-token's
    client-application-ids allowlist accepts its tokens. Also used, as-is,
    as the self-hosted A2A agent's own inbound-caller allowlist (doc 9 §9.4).
  EOT
  type        = list(string)
  default     = []
}

variable "resource_group_name" {
  description = "See the ai-gateway module's output of the same name."
  type        = string
}

variable "location" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "tenant_id" {
  description = "See the ai-gateway module's output of the same name."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "See the ai-gateway module's output of the same name."
  type        = string
}

variable "self_hosted_agent_container_image" {
  description = "Image for the self-hosted A2A agent Container App. Defaults to a bootstrap placeholder — build/push self-hosted-agent/ to the module's ACR (output self_hosted_agent_acr_login_server) and update this to the real tag, same pattern doc 2 uses for the MCP server."
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "self_hosted_agent_target_port" {
  type    = number
  default = 8080
}

variable "aoai_endpoint" {
  description = "Azure OpenAI endpoint the self-hosted agent's chat client points at (e.g. the ai-gateway module's openai_endpoint output, called directly, or the AI Gateway's llm_gateway_path through APIM). Left blank by default — set once an endpoint/auth path is chosen."
  type        = string
  default     = ""
}

variable "aoai_deployment_name" {
  type    = string
  default = ""
}
