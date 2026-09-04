# Terraform — Azure AI Gateway (MCP + LLM + A2A)

Terraform port of the 6-doc manual walkthrough in this repo. Maps 1:1 to the docs:

| File | Doc | Covers |
|---|---|---|
| `apim.tf` | 01 | APIM v2-tier instance, App Insights logger/diagnostic |
| `budget.tf` | — | $100/month cost budget on the gateway resource group, 80%/100% alerts |
| `entra.tf` | 03 | 3 Entra ID app registrations (server, interactive client, agent client), scope, app role, admin consent |
| `mcp-server.tf` | 02 | Container App MCP server, CORS, IP restriction to APIM, APIM API + PRM operation + `validate-azure-ad-token` policy |
| `llm-gateway.tf` | 05 | Azure OpenAI backend, APIM API, Product with `llm-token-limit` (rate + quota) and `llm-emit-token-metric` |
| `agent-gateway.tf` | 06 | A2A agent API import, subscription auth, `rate-limit-by-key` |

**Not covered — stays manual:** doc 04 (Foundry Control Plane self-hosted agent runner registration) is a portal/Foundry-project flow with no clean `azurerm` resource; do it after this stack is up, reusing `mcp_client_agent_id`/secret from the outputs.

## Prerequisites

- Terraform >= 1.7, `azurerm` ~> 4.0, `azuread` ~> 3.0.
- `az login`, same tenant/subscription as the target deployment.
- Identity applying this needs: Contributor on the target subscription/RG, and **Application Administrator** (Entra ID admin-consent grants in `entra.tf` need Global Administrator or Privileged Role Administrator if your tenant restricts consent).
- An MCP server container image already pushed to a registry (`var.mcp_container_image`) — building it is out of scope, same as doc 2.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — apim_name must be globally unique, mcp_url must match apim_name

terraform init
terraform plan
terraform apply
```

`mcp_url` is circular by construction (doc 3 requires deciding the APIM URL before registering apps, doc 1/2 requires the APIM name first) — set it manually to `https://<apim_name>.azure-api.net/<mcp_base_path>/mcp` before first apply; `outputs.mcp_server_url` confirms it matches after.

## After apply

- Register the interactive client's real redirect URI once you know which MCP client (Claude Desktop, VS Code) is connecting — `var.interactive_client_redirect_uris` only ships a VS Code loopback default (doc 3 §3.2).
- Point Claude / VS Code at `output.mcp_server_url`; first call gets a `401` → PRM → Entra sign-in redirect automatically (doc 2 §2.7).
- Agent callers use `output.mcp_client_agent_id` + `output.mcp_client_agent_secret` (sensitive) with the client-credentials flow in doc 3 §3.4.
- LLM gateway: create an `azurerm_api_management_subscription` against the `llm-gateway` product (or via portal) to hand a caller a key.
- A2A: set `enable_a2a_gateway = true` and `a2a_agent_runtime_url` once you have a backend agent; adjust `a2a_jsonrpc`'s `url_template` if your agent's JSON-RPC endpoint isn't at the API root.

## Cost budget

`budget.tf` caps `apim_monthly_budget_usd` (default $100) on the whole `azurerm_resource_group.gateway` — azurerm has no per-resource consumption budget, only management-group/RG/subscription scopes, and APIM dominates spend in this RG. Alerts (not enforcement — Azure budgets never auto-stop a resource) fire to `apim_budget_alert_emails` at 80% actual, 100% actual, 100% forecasted. Keep `apim_sku_name = "BasicV2_1"` to stay well under $100/month; StandardV2/PremiumV2 cost more baseline and will blow the cap faster if other resources in the RG (Container Apps, OpenAI, Log Analytics) add up.

## Known gaps / judgment calls

- **No static public IP on Basic v2 / Standard v2 APIM.** Confirmed against a live `apim-example` deployment (`az apim show` returns `publicIpAddresses: null`) — only classic tiers and Premium v2 + NAT Gateway get one. `mcp-server.tf`'s IP-allowlist (doc 2 §2.3) is skipped when it's null; `validate-azure-ad-token` at the APIM edge is the real boundary in that case.

- APIM's portal "MCP servers" and "A2A Agent" import wizards do manifest/agent-card rewriting and automatic `gen_ai.*` OpenTelemetry tagging behind the scenes; `azurerm_api_management_api` gives you the same policy surface (auth, rate limits, quotas) but not that wizard-side rewriting. If you need the wizard's exact behavior, run it once in the portal and re-import the resulting API into state (`terraform import`), or use `azapi_resource` against `Microsoft.ApiManagement/service/apis` with the wizard's API type.
- `mcp_client_agent` secret rotates via `azuread_application_password.end_date_relative` (1 year default) — doc 3 recommends a federated identity credential or managed identity instead for production; swap the password resource for `azuread_application_federated_identity_credential` if your agent runtime supports workload identity federation.
- CORS on `mcp-server` container app uses `azurerm_container_app`'s native `cors` ingress block — functionally equivalent to `az containerapp ingress cors update` in doc 2 §2.2.
