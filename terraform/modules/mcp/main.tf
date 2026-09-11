# MCP module — docs 2, 3. Owns the three Entra ID app registrations, the MCP
# server on Container Apps exposed through APIM, the container registry, and
# the OAuth authorization-server facade at the APIM root.

# ==== Doc 3 — three Entra ID apps: server (resource), interactive public
# client, agent confidential client. Requires Application Administrator (or
# Global Administrator, for the admin-consent grants below) on the identity
# applying this. ====

resource "random_uuid" "mcp_scope_id" {}
resource "random_uuid" "mcp_role_id" {}

# ---- 3.1 Server app: the MCP server as a protected resource ----

resource "azuread_application" "mcp_server" {
  display_name     = "mcp-server"
  sign_in_audience = "AzureADMyOrg"
  identifier_uris  = [var.mcp_url]

  # v2 access tokens — required, see doc 3 §3.1 (AADSTS90010001 if skipped).
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

# ==== Doc 2 — MCP server on Container Apps, exposed through APIM, secured
# with the Entra ID apps above. ====

# ---- 2.1 Container Apps environment + app ----

resource "azurerm_container_app_environment" "mcp" {
  name                       = "cae-mcp-${var.environment}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = var.log_analytics_workspace_id
  tags                       = var.tags
}

resource "azurerm_container_app" "mcp_server" {
  name                         = "mcp-server"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.mcp.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type = "SystemAssigned"
  }

  registry {
    server   = azurerm_container_registry.gateway.login_server
    identity = "System"
  }

  template {
    min_replicas = 1

    container {
      name   = "mcp-server"
      image  = var.mcp_container_image
      cpu    = 0.5
      memory = "1Gi"

      liveness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = var.mcp_target_port
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = var.mcp_target_port
    transport        = "auto" # streamable HTTP runs over plain HTTP — doc 2 §2.1

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }

    # 2.3 — restrict the app to APIM's public IP so the MCP endpoint can't be
    # reached by bypassing APIM. Only possible when APIM has a static public IP
    # (classic tier, or Premium v2 + NAT Gateway) — Basic v2/Standard v2
    # (var.apim_sku_name default) route through shared infra with no fixed IP,
    # so this block is skipped and the container app relies solely on
    # validate-azure-ad-token at the APIM edge (mcp-server policy below) as the
    # actual security boundary. Upgrade to Premium v2 + NAT Gateway, or use
    # Container Apps VNet integration, for network-level isolation too.
    dynamic "ip_security_restriction" {
      for_each = var.apim_public_ip != null ? [var.apim_public_ip] : []
      content {
        name             = "allow-apim"
        action           = "Allow"
        ip_address_range = "${ip_security_restriction.value}/32"
        description      = "APIM gateway public IP"
      }
    }

    cors {
      allowed_origins    = var.mcp_cors_allowed_origins
      allowed_methods    = ["GET", "POST", "OPTIONS"]
      allowed_headers    = ["Content-Type", "Authorization", "Mcp-Session-Id"]
      max_age_in_seconds = 3600
    }
  }
}

locals {
  # Bare origin only — the mcp_invoke operation's url_template ("/mcp")
  # is appended by APIM to this service_url, so including /mcp here would
  # double it up into .../mcp/mcp on the backend request.
  mcp_backend_url = "https://${azurerm_container_app.mcp_server.ingress[0].fqdn}"
}

# ---- 2.4 Expose the MCP server through APIM ----

resource "azurerm_api_management_api" "mcp_server" {
  name                  = "mcp-server"
  resource_group_name   = var.resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "mcp-server"
  path                  = var.mcp_base_path
  protocols             = ["https"]
  service_url           = local.mcp_backend_url
  subscription_required = false # auth is via validate-azure-ad-token, not a subscription key
}

# MCP JSON-RPC passthrough operation.
resource "azurerm_api_management_api_operation" "mcp_invoke" {
  operation_id        = "mcp-invoke"
  api_name            = azurerm_api_management_api.mcp_server.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  display_name        = "MCP JSON-RPC"
  method              = "POST"
  url_template        = "/mcp"
}

# 2.5 — PRM document, served anonymously (RFC 9728). This is what triggers
# the automatic browser redirect to Entra ID sign-in for interactive clients.
resource "azurerm_api_management_api_operation" "prm" {
  operation_id        = "oauth-protected-resource"
  api_name            = azurerm_api_management_api.mcp_server.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  display_name        = "OAuth Protected Resource Metadata"
  method              = "GET"
  url_template        = "/.well-known/oauth-protected-resource"
}

# ---- Named values referenced by policies ----

resource "azurerm_api_management_named_value" "mcp_url" {
  name                = "mcp-url"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "mcp-url"
  value               = var.mcp_url
}

resource "azurerm_api_management_named_value" "tenant_id" {
  name                = "tenant-id"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "tenant-id"
  value               = var.tenant_id
}

resource "azurerm_api_management_named_value" "interactive_client_id" {
  name                = "interactive-client-id"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "interactive-client-id"
  value               = azuread_application.mcp_client_interactive.client_id
}

resource "azurerm_api_management_named_value" "agent_client_id" {
  name                = "agent-client-id"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "agent-client-id"
  value               = azuread_application.mcp_client_agent.client_id
}

# Entra v2 access tokens always set aud to the resource app's client_id
# (GUID), never the App ID URI in identifier_uris — regardless of the
# resource requested at the token endpoint. validate-azure-ad-token must
# check against that GUID, not mcp-url.
resource "azurerm_api_management_named_value" "resource_app_id" {
  name                = "resource-app-id"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "resource-app-id"
  value               = azuread_application.mcp_server.client_id
}

# ---- 2.6 API-level policy: validate-azure-ad-token on everything except PRM ----

resource "azurerm_api_management_api_policy" "mcp_server" {
  api_name            = azurerm_api_management_api.mcp_server.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="{{tenant-id}}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Access token is missing or invalid." output-token-variable-name="jwt">
      <client-application-ids>
        <application-id>{{interactive-client-id}}</application-id>
        <application-id>{{agent-client-id}}</application-id>
%{for id in var.foundry_agent_client_ids~}
        <application-id>${id}</application-id>
%{endfor~}
      </client-application-ids>
      <audiences>
        <audience>{{resource-app-id}}</audience>
      </audiences>
    </validate-azure-ad-token>
    <!-- Per-caller rate limit: MCP best practices (github.com/microsoft/mcp-for-beginners,
         08-BestPractices) call for throttling tool invocations to prevent abuse/runaway
         agent loops. Keyed on the validated token's sub claim (unique per human sign-in
         and, for client-credentials tokens, per calling app), never on the shared
         client_id, so one noisy caller can't starve others sharing mcp-client-agent /
         foundry_agent_client_ids. -->
    <rate-limit-by-key calls="60" renewal-period="60"
      counter-key="@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("sub", new[] { "anon" })[0])"
      remaining-calls-variable-name="remainingCalls" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
    <choose>
      <when condition="@(context.Response.StatusCode == 401)">
        <set-header name="WWW-Authenticate" exists-action="override">
          <value>Bearer resource_metadata="{{mcp-url}}/.well-known/oauth-protected-resource"</value>
        </set-header>
      </when>
    </choose>
  </on-error>
</policies>
XML

  depends_on = [
    azurerm_api_management_named_value.mcp_url,
    azurerm_api_management_named_value.tenant_id,
    azurerm_api_management_named_value.interactive_client_id,
    azurerm_api_management_named_value.agent_client_id,
    azurerm_api_management_named_value.resource_app_id,
  ]
}

# PRM operation must stay anonymous — no <base/>, so it does not inherit
# validate-azure-ad-token from the API policy above.
resource "azurerm_api_management_api_operation_policy" "prm" {
  api_name            = azurerm_api_management_api.mcp_server.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  operation_id        = azurerm_api_management_api_operation.prm.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <return-response>
      <set-status code="200" reason="OK" />
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-body>{
  "resource": "{{mcp-url}}",
  "authorization_servers": ["https://login.microsoftonline.com/{{tenant-id}}/v2.0"],
  "scopes_supported": ["mcp.tools.invoke"],
  "bearer_methods_supported": ["header"]
}</set-body>
    </return-response>
  </inbound>
</policies>
XML
}

# ==== Container registry for the Go MCP server image (../mcp-server). Built
# with `az acr build` (cloud-side, no local Docker daemon needed) — see
# mcp-server/README.md. ====

resource "azurerm_container_registry" "gateway" {
  name                = replace("acr${var.apim_name}", "-", "")
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# Container App pulls via its own system-assigned identity (above).
# NOTE: on a first-time apply this role assignment and the container app are
# created together — if the very first revision fails to pull with a 401,
# re-run `terraform apply` once role propagation (usually <2min) finishes.
resource "azurerm_role_assignment" "mcp_acr_pull" {
  scope                = azurerm_container_registry.gateway.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app.mcp_server.identity[0].principal_id
}

# ==== OAuth authorization-server facade at the APIM root ====
# Entra ID does not serve RFC 8414 metadata (.well-known/oauth-authorization-server
# 404s — only the OIDC discovery document works). Some MCP clients (VS Code observed
# doing this) fail AS metadata discovery against the PRM's authorization_servers
# entry and fall back to treating the MCP resource's own origin as the authorization
# server, guessing conventional /authorize and /token paths there. This facade
# mounts at the APIM service root (empty path) so those guesses land on real
# endpoints: metadata returns Entra's real endpoints directly, and /authorize
# and /token proxy through to Entra for clients that skip metadata entirely.

resource "azurerm_api_management_named_value" "entra_authorize_endpoint" {
  name                = "entra-authorize-endpoint"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "entra-authorize-endpoint"
  value               = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/authorize"
}

resource "azurerm_api_management_named_value" "entra_token_endpoint" {
  name                = "entra-token-endpoint"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "entra-token-endpoint"
  value               = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/token"
}

resource "azurerm_api_management_named_value" "entra_issuer" {
  name                = "entra-issuer"
  resource_group_name = var.resource_group_name
  api_management_name = var.apim_name
  display_name        = "entra-issuer"
  value               = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
}

resource "azurerm_api_management_api" "oauth_facade" {
  name                  = "oauth-facade"
  resource_group_name   = var.resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "oauth-facade"
  path                  = ""
  protocols             = ["https"]
  service_url           = "https://login.microsoftonline.com"
  subscription_required = false
}

resource "azurerm_api_management_api_operation" "oauth_metadata" {
  operation_id        = "oauth-authorization-server-metadata"
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  display_name        = "OAuth Authorization Server Metadata"
  method              = "GET"
  url_template        = "/.well-known/oauth-authorization-server"
}

resource "azurerm_api_management_api_operation_policy" "oauth_metadata" {
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  operation_id        = azurerm_api_management_api_operation.oauth_metadata.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <return-response>
      <set-status code="200" reason="OK" />
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-body>{
  "issuer": "{{entra-issuer}}",
  "authorization_endpoint": "{{entra-authorize-endpoint}}",
  "token_endpoint": "{{entra-token-endpoint}}",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "client_credentials"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none", "client_secret_post"]
}</set-body>
    </return-response>
  </inbound>
</policies>
XML
}

resource "azurerm_api_management_api_operation" "oauth_authorize" {
  operation_id        = "oauth-authorize"
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  display_name        = "OAuth Authorize (proxy to Entra)"
  method              = "GET"
  url_template        = "/authorize"
}

resource "azurerm_api_management_api_operation_policy" "oauth_authorize" {
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  operation_id        = azurerm_api_management_api_operation.oauth_authorize.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <return-response>
      <set-status code="302" reason="Found" />
      <set-header name="Location" exists-action="override">
        <value>@{
          var qs = context.Request.OriginalUrl.QueryString;
          var extra = qs.Contains("scope=") ? "" : "&scope=" + System.Net.WebUtility.UrlEncode("{{resource-app-id}}/.default offline_access openid profile");
          return "{{entra-authorize-endpoint}}" + qs + extra;
        }</value>
      </set-header>
    </return-response>
  </inbound>
</policies>
XML

  depends_on = [
    azurerm_api_management_named_value.resource_app_id,
  ]
}

resource "azurerm_api_management_api_operation" "oauth_token" {
  operation_id        = "oauth-token"
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  display_name        = "OAuth Token (proxy to Entra)"
  method              = "POST"
  url_template        = "/token"
}

resource "azurerm_api_management_api_operation_policy" "oauth_token" {
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group_name
  operation_id        = azurerm_api_management_api_operation.oauth_token.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <set-backend-service base-url="https://login.microsoftonline.com" />
    <rewrite-uri template="/${var.tenant_id}/oauth2/v2.0/token" />
    <set-body>@{
      var body = context.Request.Body.As<string>(preserveContent: true);
      if (body == null || !body.Contains("scope="))
      {
        var sep = string.IsNullOrEmpty(body) ? "" : "&";
        body = body + sep + "scope=" + System.Net.WebUtility.UrlEncode("{{resource-app-id}}/.default offline_access openid profile");
      }
      return body;
    }</set-body>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
</policies>
XML

  depends_on = [
    azurerm_api_management_named_value.resource_app_id,
  ]
}
