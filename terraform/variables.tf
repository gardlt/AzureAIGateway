variable "resource_group_name" {
  description = "Resource group for the whole gateway stack."
  type        = string
  default     = "rg-ai-gateway"
}

variable "location" {
  description = "Azure region. Central US is the standing default for this repo."
  type        = string
  default     = "centralus"
}

variable "environment" {
  description = "Short env tag used in resource names (dev/stage/prod)."
  type        = string
  default     = "dev"
}

# ---- APIM (doc 1) ----

variable "apim_name" {
  description = "Globally unique APIM service name."
  type        = string
}

variable "apim_publisher_name" {
  type    = string
  default = "AI Gateway"
}

variable "apim_publisher_email" {
  type = string
}

variable "apim_sku_name" {
  description = "v2-tier SKU, e.g. BasicV2_1, StandardV2_1, PremiumV2_1. VNet-isolated backends (doc 2 §2.3 defense-in-depth) require Standard v2 or Premium v2."
  type        = string
  default     = "BasicV2_1"
}

variable "apim_monthly_budget_usd" {
  description = "Hard cost cap for the APIM instance, USD/month. Alerts fire at 80%/100% actual spend and 100% forecasted; Azure does not auto-stop the resource at the cap."
  type        = number
  default     = 100
}

variable "apim_budget_alert_emails" {
  description = "Emails notified when the APIM budget threshold fires. Defaults to apim_publisher_email if left empty."
  type        = list(string)
  default     = []
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

# ---- LLM gateway (doc 5) ----

variable "enable_llm_gateway" {
  description = "Deploy the Azure OpenAI backend + APIM product with token budgets/rate limits (doc 5). Independent of the MCP server."
  type        = bool
  default     = true
}

variable "openai_account_name" {
  type    = string
  default = ""
}

variable "openai_sku_name" {
  type    = string
  default = "S0"
}

variable "openai_deployment_name" {
  type    = string
  default = "gpt-4o"
}

variable "openai_model_name" {
  type    = string
  default = "gpt-4o"
}

variable "openai_model_version" {
  type    = string
  default = "2024-08-06"
}

variable "llm_tokens_per_minute" {
  description = "llm-token-limit ceiling per subscription (doc 5 §5.3)."
  type        = number
  default     = 10000
}

variable "llm_token_quota_per_period" {
  description = "Product-level token budget for the LLM product (doc 5 §5.4)."
  type        = number
  default     = 1000000
}

variable "llm_token_quota_period" {
  description = "Quota renewal period: Weekly, Monthly, etc."
  type        = string
  default     = "Monthly"
}

# ---- A2A agent gateway (doc 6) ----

variable "enable_a2a_gateway" {
  description = "Import an existing A2A agent as an APIM API with rate limiting (doc 6 §6.3, §6.5)."
  type        = bool
  default     = false
}

variable "a2a_agent_runtime_url" {
  description = "JSON-RPC runtime URL of the backend A2A agent."
  type        = string
  default     = ""
}

variable "a2a_base_path" {
  type    = string
  default = "agents/a2a-agent"
}

variable "a2a_rate_limit_calls" {
  type    = number
  default = 30
}

variable "a2a_rate_limit_period_seconds" {
  type    = number
  default = 60
}

variable "tags" {
  type    = map(string)
  default = {}
}
