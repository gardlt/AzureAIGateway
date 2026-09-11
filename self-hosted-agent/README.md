# Self-hosted A2A agent

Agent Framework agent, self-hosted on Azure Container Apps, exposed over
A2A (doc 9 §9.2) so a Microsoft Foundry agent can call it (doc 9 §9.4). No
client secret anywhere — identity is a federated credential from the
Container App's user-assigned managed identity to a secret-free Entra
application (doc 8 §8.3 pattern; `terraform/modules/agent/main.tf`
provisions both).

## Build and push

```bash
# Terraform output from the repo root
ACR=$(terraform -chdir=../terraform output -raw self_hosted_agent_acr_login_server)

az acr build --registry "$ACR" --image self-hosted-a2a-agent:latest .
```

Then update `self_hosted_agent_container_image` in `terraform.tfvars` to
`<ACR>/self-hosted-a2a-agent:latest` and re-apply so the Container App picks
up the real image (it starts from a bootstrap placeholder until then, same
as the MCP server in doc 2).

## Configuration

Set by Terraform as Container App env vars — nothing to configure by hand
except the two below:

| Var | Set by | Purpose |
|---|---|---|
| `AZURE_CLIENT_ID` | Terraform | UAMI client_id — which identity `DefaultAzureCredential`/`ManagedIdentityCredential` should pick. |
| `AZURE_TENANT_ID` | Terraform | Tenant for token issuer/JWKS validation. |
| `AGENT_APP_ID_URI` | Terraform | This agent's own audience — inbound tokens must be issued for it. |
| `ALLOWED_CALLER_CLIENT_IDS` | Terraform, from `foundry_agent_client_ids` | Comma-separated allowlist of caller `client_id`s (checked against the token's `azp`/`appid` claim). |
| `AZURE_OPENAI_ENDPOINT` | `terraform.tfvars` (`self_hosted_agent_aoai_endpoint`) | Not set by default — pick an Azure OpenAI endpoint (directly, with a role assignment for the UAMI, or via the AI Gateway's `llm_gateway_path` through APIM) and set it. |
| `AZURE_OPENAI_DEPLOYMENT_NAME` | `terraform.tfvars` (`self_hosted_agent_aoai_deployment_name`) | Deployment name to call. |

If pointing directly at an Azure OpenAI resource (not through APIM), grant
the UAMI (`self_hosted_agent_uami_principal_id` output) the **Cognitive
Services OpenAI User** role on it — not automated here, to avoid coupling
this module to a specific OpenAI resource choice.

## Wiring up the Foundry side

Once deployed, give Foundry Agent Service an outbound A2A connection to
this endpoint, authenticated with its own agent identity (doc 9 §9.4):

```bash
azd ai connection create self-hosted-agent \
  --kind remote-a2a \
  --target "https://$(terraform -chdir=../terraform output -raw self_hosted_agent_fqdn)" \
  --auth-type agentic-identity \
  --audience "$(terraform -chdir=../terraform output -raw self_hosted_agent_app_id_uri)"
```

Add the calling Foundry agent's `client_id` to `foundry_agent_client_ids` in
`terraform.tfvars` and re-apply — this repo's self-hosted agent rejects any
caller not on that list, same allowlist mechanism doc 3/7 use for the MCP
server's `validate-azure-ad-token` policy.

## Local dev

```bash
export AZURE_TENANT_ID=<tenant>
export AGENT_APP_ID_URI=api://self-hosted-a2a-agent-dev
export ALLOWED_CALLER_CLIENT_IDS=<a-test-client-id>
export AZURE_OPENAI_ENDPOINT=https://<resource>.openai.azure.com/
export AZURE_OPENAI_DEPLOYMENT_NAME=gpt-4o-mini
az login  # local credential fallback — see main.py's ChainedTokenCredential

pip install -r requirements.txt
python main.py
```

Agent card: `GET http://localhost:8080/.well-known/agent-card.json`
(unauthenticated — see doc 9 §9.4's note on agent-card fetches). Everything
else under `/` requires a bearer token whose `aud` matches
`AGENT_APP_ID_URI` and whose `azp`/`appid` is allowlisted.
