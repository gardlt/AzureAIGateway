variable "foundry_agent_client_ids" {
  description = <<-EOT
    client_id (instance_identity.client_id) of each Foundry-managed agent
    identity (doc 7) allowed to call the MCP server through APIM, in
    addition to mcp-client-interactive and mcp-client-agent. Each Foundry
    agent gets its own auto-provisioned agent identity/client_id — add it
    here (not to mcp_client_agent) so validate-azure-ad-token's
    client-application-ids allowlist accepts its tokens.
  EOT
  type        = list(string)
  default     = []
}
