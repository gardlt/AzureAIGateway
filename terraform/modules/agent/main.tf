# Agent module — docs 4, 7, 8. Intentionally thin: this module declares no
# resources. Actual agent-identity provisioning (Foundry-managed Entra Agent
# ID instances, or the self-hosted Container Apps/AKS federated-credential
# pattern) is manual Graph API / az cli work today, not Terraform-managed —
# see README.md in this directory and docs 7/8. This module exists only to
# hold and pass through the foundry_agent_client_ids allowlist consumed by
# the mcp module's validate-azure-ad-token policy.
