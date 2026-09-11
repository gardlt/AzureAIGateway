# Agent module

Thin on purpose. This module owns no Azure resources — it exists only to
declare and pass through `foundry_agent_client_ids`, the allowlist the `mcp`
module's `validate-azure-ad-token` policy uses to accept tokens from
Foundry-managed (or self-hosted) agent identities alongside `mcp-client-agent`.

Actual agent-identity provisioning — creating a Microsoft Entra Agent ID
blueprint + instance for a Foundry-managed agent (doc 7), or federating a
self-hosted Container Apps/AKS workload identity to a no-secret Entra Agent
ID (doc 8) — is manual Graph API / `az` CLI work today, not Terraform-managed.
There is no supported `azurerm`/`azuread` provider resource for Entra Agent ID
blueprints/instances as of this writing.

Once an agent identity is provisioned, add its `client_id` to
`foundry_agent_client_ids` in `terraform.tfvars` and re-apply so APIM accepts
its tokens.
