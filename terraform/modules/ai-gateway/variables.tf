variable "resource_group_name" {
  description = "Resource group for the whole gateway stack."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "environment" {
  description = "Short env tag used in resource names (dev/stage/prod)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
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
