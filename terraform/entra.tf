# Doc 3 — three Entra ID apps: server (resource), interactive public client,
# agent confidential client. Requires Application Administrator (or Global
# Administrator, for the admin-consent grants below) on the identity applying this.

resource "random_uuid" "mcp_scope_id" {}
resource "random_uuid" "mcp_role_id" {}

# ---- 3.1 Server app: the MCP server as a protected resource ----

resource "azuread_application" "mcp_server" {
  display_name     = "mcp-server"
  sign_in_audience = "AzureADMyOrg"
  identifier_uris  = [var.mcp_url]

  # v2 access tokens — required, see doc 3 §3.1 (AADSTS9010010 if skipped).
  api {
    requested_access_token_version = 2

    oauth2_permission_scope {
      id                         = random_uuid.mcp_scope_id.result
      admin_consent_description  = "Invoke MCP tools on behalf of the signed-in user"
      admin_consent_display_name = "Invoke MCP tools"
      enabled                    = true
      type                       = "User"
      user_consent_description   = "Invoke MCP tools on your behalf"
      user_consent_display_name  = "Invoke MCP tools"
      value                      = "mcp.tools.invoke"
    }
  }

  app_role {
    id                   = random_uuid.mcp_role_id.result
    display_name         = "Tools.Invoke.All"
    description          = "Invoke MCP tools as an autonomous agent"
    value                = "Tools.Invoke.All"
    allowed_member_types = ["Application"]
    enabled              = true
  }

  tags = ["mcp-server"]
}

resource "azuread_service_principal" "mcp_server" {
  client_id = azuread_application.mcp_server.client_id
}

# ---- 3.2 Interactive public client (Claude / VS Code) ----

resource "azuread_application" "mcp_client_interactive" {
  display_name     = "mcp-client-interactive"
  sign_in_audience = "AzureADMyOrg"

  public_client {
    redirect_uris = var.interactive_client_redirect_uris
  }

  # "Allow public client flows" = Yes
  fallback_public_client_enabled = true

  required_resource_access {
    resource_app_id = azuread_application.mcp_server.client_id

    resource_access {
      id   = random_uuid.mcp_scope_id.result
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "mcp_client_interactive" {
  client_id = azuread_application.mcp_client_interactive.client_id
}

# Admin consent for the delegated scope (doc 3 §3.2 step 7).
resource "azuread_service_principal_delegated_permission_grant" "interactive_consent" {
  service_principal_object_id          = azuread_service_principal.mcp_client_interactive.object_id
  resource_service_principal_object_id = azuread_service_principal.mcp_server.object_id
  claim_values                         = ["mcp.tools.invoke"]
}

# ---- 3.3 Agent (service-to-service) confidential client ----

resource "azuread_application" "mcp_client_agent" {
  display_name     = "mcp-client-agent"
  sign_in_audience = "AzureADMyOrg"

  required_resource_access {
    resource_app_id = azuread_application.mcp_server.client_id

    resource_access {
      id   = random_uuid.mcp_role_id.result
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "mcp_client_agent" {
  client_id = azuread_application.mcp_client_agent.client_id
}

# Computed once at creation and frozen in state — using timestamp() directly
# in end_date would recompute (and force a destroy/recreate of the secret)
# on every plan.
resource "time_offset" "agent_secret_expiry" {
  offset_days = 365
}

resource "azuread_application_password" "mcp_client_agent" {
  application_id = azuread_application.mcp_client_agent.id
  display_name   = "terraform-managed"
  # Rotate by tainting this resource, or replace with a federated identity
  # credential / managed identity for production agent callers (doc 3).
  end_date = time_offset.agent_secret_expiry.rfc3339
}

# Admin consent for the app role (doc 3 §3.3 step 2).
resource "azuread_app_role_assignment" "agent_role" {
  app_role_id         = random_uuid.mcp_role_id.result
  principal_object_id = azuread_service_principal.mcp_client_agent.object_id
  resource_object_id  = azuread_service_principal.mcp_server.object_id
}
