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
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "entra-authorize-endpoint"
  value               = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/oauth2/v2.0/authorize"
}

resource "azurerm_api_management_named_value" "entra_token_endpoint" {
  name                = "entra-token-endpoint"
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "entra-token-endpoint"
  value               = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/oauth2/v2.0/token"
}

resource "azurerm_api_management_named_value" "entra_issuer" {
  name                = "entra-issuer"
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "entra-issuer"
  value               = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
}

resource "azurerm_api_management_api" "oauth_facade" {
  name                  = "oauth-facade"
  resource_group_name   = azurerm_resource_group.gateway.name
  api_management_name   = azurerm_api_management.gateway.name
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
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "OAuth Authorization Server Metadata"
  method              = "GET"
  url_template        = "/.well-known/oauth-authorization-server"
}

resource "azurerm_api_management_api_operation_policy" "oauth_metadata" {
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
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
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "OAuth Authorize (proxy to Entra)"
  method              = "GET"
  url_template        = "/authorize"
}

resource "azurerm_api_management_api_operation_policy" "oauth_authorize" {
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  operation_id        = azurerm_api_management_api_operation.oauth_authorize.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <return-response>
      <set-status code="302" reason="Found" />
      <set-header name="Location" exists-action="override">
        <value>@("{{entra-authorize-endpoint}}" + context.Request.OriginalUrl.QueryString)</value>
      </set-header>
    </return-response>
  </inbound>
</policies>
XML
}

resource "azurerm_api_management_api_operation" "oauth_token" {
  operation_id        = "oauth-token"
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "OAuth Token (proxy to Entra)"
  method              = "POST"
  url_template        = "/token"
}

resource "azurerm_api_management_api_operation_policy" "oauth_token" {
  api_name            = azurerm_api_management_api.oauth_facade.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  operation_id        = azurerm_api_management_api_operation.oauth_token.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <set-backend-service base-url="https://login.microsoftonline.com" />
    <rewrite-uri template="/${data.azurerm_client_config.current.tenant_id}/oauth2/v2.0/token" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
</policies>
XML
}
