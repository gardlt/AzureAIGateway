# Agent module — docs 4, 7, 8, 9. Two things live here:
#
# 1. The original passthrough: foundry_agent_client_ids, the allowlist the
#    mcp module's validate-azure-ad-token policy uses to accept tokens from
#    Foundry-managed (or self-hosted) agent identities. Actual Foundry-managed
#    Entra Agent ID provisioning (doc 7) is still manual Graph API / az cli
#    work — no supported azurerm/azuread resource for Agent ID blueprints/
#    instances as of this writing. See README.md.
#
# 2. A real, Terraform-managed self-hosted A2A agent (doc 8 + doc 9 §9.2):
#    an Azure Container App running the Microsoft Agent Framework's A2A
#    server (self-hosted-agent/ at repo root), identified by a secret-free
#    Microsoft Entra application whose token-issuing trust is a federated
#    identity credential pointed at the Container App's own user-assigned
#    managed identity (doc 8 §8.3's FIC recipe, applied to a plain
#    azuread_application here rather than an Entra Agent ID instance, since
#    that preview object still isn't Terraform-managed — swap it in later
#    without touching the FIC/UAMI trust chain).

# ---- Entra identity for the self-hosted A2A agent (no secret) ----

locals {
  self_hosted_agent_app_id_uri = "api://self-hosted-a2a-agent-${var.environment}"
}

resource "azuread_application" "self_hosted_agent" {
  display_name = "self-hosted-a2a-agent-${var.environment}"

  identifier_uris = [local.self_hosted_agent_app_id_uri]

  app_role {
    id                   = "8f6a9e3e-9e2a-4b7a-9b5e-2a6a2b6b5b0a"
    allowed_member_types = ["Application"]
    display_name         = "A2A.Invoke"
    description          = "Callers may invoke this agent's A2A endpoint."
    value                = "A2A.Invoke"
    enabled              = true
  }
}

resource "azuread_service_principal" "self_hosted_agent" {
  client_id = azuread_application.self_hosted_agent.client_id
}

# The Container App's own identity — this is what actually requests tokens
# at runtime (via DefaultAzureCredential / ManagedIdentityCredential inside
# the agent process). The federated credential below is what lets it mint
# those tokens *as* azuread_application.self_hosted_agent, with no secret
# ever stored anywhere.
resource "azurerm_user_assigned_identity" "self_hosted_agent" {
  name                = "id-self-hosted-a2a-agent-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azuread_application_federated_identity_credential" "self_hosted_agent" {
  application_id = azuread_application.self_hosted_agent.id
  display_name   = "aca-workload-identity-${var.environment}"
  description    = "Federates the self-hosted-a2a-agent Container App's user-assigned identity — doc 8 §8.3 pattern, no client secret."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
  subject        = azurerm_user_assigned_identity.self_hosted_agent.principal_id
}

# ---- Compute: its own ACR + Container App Environment, deliberately not
# shared with the mcp module's, to avoid a agent<->mcp dependency cycle
# (mcp already depends on this module's foundry_agent_client_ids output). ----

resource "azurerm_container_registry" "agent" {
  name                = "acragent${var.environment}${random_string.acr_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

resource "random_string" "acr_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_role_assignment" "self_hosted_agent_acr_pull" {
  scope                = azurerm_container_registry.agent.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.self_hosted_agent.principal_id
}

resource "azurerm_container_app_environment" "agent" {
  name                       = "cae-self-hosted-agent-${var.environment}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = var.log_analytics_workspace_id
  tags                       = var.tags
}

resource "azurerm_container_app" "self_hosted_agent" {
  name                         = "ca-self-hosted-a2a-agent-${var.environment}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.agent.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.self_hosted_agent.id]
  }

  registry {
    server   = azurerm_container_registry.agent.login_server
    identity = azurerm_user_assigned_identity.self_hosted_agent.id
  }

  ingress {
    external_enabled = true
    target_port      = var.self_hosted_agent_target_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "self-hosted-a2a-agent"
      image  = var.self_hosted_agent_container_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.self_hosted_agent.client_id
      }
      env {
        name  = "AZURE_TENANT_ID"
        value = var.tenant_id
      }
      env {
        name  = "AGENT_APP_ID_URI"
        value = local.self_hosted_agent_app_id_uri
      }
      env {
        name  = "ALLOWED_CALLER_CLIENT_IDS"
        value = join(",", var.foundry_agent_client_ids)
      }
      env {
        name  = "AZURE_OPENAI_ENDPOINT"
        value = var.aoai_endpoint
      }
      env {
        name  = "AZURE_OPENAI_DEPLOYMENT_NAME"
        value = var.aoai_deployment_name
      }
    }
  }

  depends_on = [azurerm_role_assignment.self_hosted_agent_acr_pull]
}
