# Agent module

Two things live here now:

1. **`foundry_agent_client_ids` passthrough.** The allowlist the `mcp`
   module's `validate-azure-ad-token` policy uses to accept tokens from
   Foundry-managed (or self-hosted) agent identities alongside
   `mcp-client-agent`.

   Actual Foundry-managed agent-identity provisioning — creating a
   Microsoft Entra Agent ID blueprint + instance for a Foundry-managed
   agent (doc 7) — is manual Graph API / `az` CLI work today, not
   Terraform-managed. There is no supported `azurerm`/`azuread` provider
   resource for Entra Agent ID blueprints/instances as of this writing.
   Once one is provisioned, add its `client_id` to `foundry_agent_client_ids`
   in `terraform.tfvars` and re-apply so APIM accepts its tokens.

2. **The self-hosted A2A agent (doc 8 + doc 9 §9.2/§9.4) — real resources.**
   An Azure Container App running `self-hosted-agent/` (repo root), plus its
   own ACR and Container App Environment. Its identity is a plain
   `azuread_application` (no secret) federated to the Container App's
   user-assigned managed identity — the doc 8 §8.3 FIC recipe, just applied
   to a regular app registration instead of an Entra Agent ID instance,
   since that preview object still isn't Terraform-managed. Swap it in
   later without touching the FIC/UAMI trust chain.

   Own ACR/environment (not shared with the `mcp` module's) is deliberate:
   `mcp` already depends on this module's `foundry_agent_client_ids` output,
   so sharing `mcp`'s ACR/environment here would create a dependency cycle.

   See `self-hosted-agent/README.md` for build/deploy/Foundry-connection
   steps. Outputs: `self_hosted_agent_app_id_uri` (the audience Foundry's
   outbound A2A connection targets), `self_hosted_agent_fqdn`,
   `self_hosted_agent_acr_login_server`.
