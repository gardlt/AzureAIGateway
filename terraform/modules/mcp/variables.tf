variable "resource_group_name" {
  type = string
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

variable "apim_name" {
  description = "Name of the APIM instance from the ai-gateway module."
  type        = string
}

variable "apim_gateway_url" {
  description = "gateway_url output of the ai-gateway module's APIM instance."
  type        = string
}

variable "tenant_id" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "apim_public_ip" {
  description = "APIM's static public IP, if the SKU has one (see ai-gateway module output apim_public_ip). Null skips the ip_security_restriction block."
  type        = string
  default     = null
}

# ---- Entra ID apps (doc 3) ----

variable "mcp_url" {
  description = "Canonical MCP server URL through APIM, e.g. https://<apim-name>.azure-api.net/mcp-server/mcp. Must match the APIM MCP API's resulting URL exactly (doc 3 §prereqs)."
  type        = string
}

variable "mcp_base_path" {
  description = "APIM route/base path for the MCP server API (doc 2 §2.4)."
  type        = string
  default     = "mcp-server"
}

variable "interactive_client_redirect_uris" {
  description = "Loopback/custom-scheme redirect URIs for the interactive (Claude/VS Code) public client (doc 3 §3.2). VS Code typically needs http://127.0.0.1:<port>/; add Claude's documented callback too."
  type        = list(string)
  default     = ["http://127.0.0.1:33418/", "https://vscode.dev/redirect"]
}

# ---- MCP server container app (doc 2) ----

variable "mcp_container_image" {
  description = "Container image implementing MCP streamable HTTP transport at /mcp and health at /healthz."
  type        = string
}

variable "mcp_target_port" {
  type    = number
  default = 3000
}

variable "mcp_cors_allowed_origins" {
  description = "Trusted browser origins for MCP CORS (doc 2 §2.2). Only needed for browser-based MCP clients (VS Code for the Web)."
  type        = list(string)
  default     = ["https://vscode.dev", "https://github.dev"]
}

# ---- Agent identities (doc 7) ----

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
