# Doc 2 — MCP server on Container Apps, exposed through APIM, secured with the
# Entra ID apps from entra.tf.

# ---- 2.1 Container Apps environment + app ----

resource "azurerm_container_app_environment" "mcp" {
  name                       = "cae-mcp-${var.environment}"
  resource_group_name        = azurerm_resource_group.gateway.name
  location                   = azurerm_resource_group.gateway.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.gateway.id
  tags                       = var.tags
}

resource "azurerm_container_app" "mcp_server" {
  name                         = "mcp-server"
  resource_group_name          = azurerm_resource_group.gateway.name
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
    # validate-azure-ad-token at the APIM edge (mcp-server.tf policy) as the
    # actual security boundary. Upgrade to Premium v2 + NAT Gateway, or use
    # Container Apps VNet integration, for network-level isolation too.
    dynamic "ip_security_restriction" {
      for_each = local.apim_public_ip != null ? [local.apim_public_ip] : []
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
  apim_public_ip  = try(azurerm_api_management.gateway.public_ip_addresses[0], null)
}

# ---- 2.4 Expose the MCP server through APIM ----

resource "azurerm_api_management_api" "mcp_server" {
  name                  = "mcp-server"
  resource_group_name   = azurerm_resource_group.gateway.name
  api_management_name   = azurerm_api_management.gateway.name
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
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "MCP JSON-RPC"
  method              = "POST"
  url_template        = "/mcp"
}

# 2.5 — PRM document, served anonymously (RFC 9728). This is what triggers
# the automatic browser redirect to Entra ID sign-in for interactive clients.
resource "azurerm_api_management_api_operation" "prm" {
  operation_id        = "oauth-protected-resource"
  api_name            = azurerm_api_management_api.mcp_server.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
  display_name        = "OAuth Protected Resource Metadata"
  method              = "GET"
  url_template        = "/.well-known/oauth-protected-resource"
}

# ---- Named values referenced by policies ----

resource "azurerm_api_management_named_value" "mcp_url" {
  name                = "mcp-url"
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "mcp-url"
  value               = var.mcp_url
}

resource "azurerm_api_management_named_value" "tenant_id" {
  name                = "tenant-id"
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "tenant-id"
  value               = data.azurerm_client_config.current.tenant_id
}

resource "azurerm_api_management_named_value" "interactive_client_id" {
  name                = "interactive-client-id"
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "interactive-client-id"
  value               = azuread_application.mcp_client_interactive.client_id
}

resource "azurerm_api_management_named_value" "agent_client_id" {
  name                = "agent-client-id"
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "agent-client-id"
  value               = azuread_application.mcp_client_agent.client_id
}

# Entra v2 access tokens always set aud to the resource app's client_id
# (GUID), never the App ID URI in identifier_uris — regardless of the
# resource requested at the token endpoint. validate-azure-ad-token must
# check against that GUID, not mcp-url.
resource "azurerm_api_management_named_value" "resource_app_id" {
  name                = "resource-app-id"
  resource_group_name = azurerm_resource_group.gateway.name
  api_management_name = azurerm_api_management.gateway.name
  display_name        = "resource-app-id"
  value               = azuread_application.mcp_server.client_id
}

# ---- 2.6 API-level policy: validate-azure-ad-token on everything except PRM ----

resource "azurerm_api_management_api_policy" "mcp_server" {
  api_name            = azurerm_api_management_api.mcp_server.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="{{tenant-id}}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Access token is missing or invalid.">
      <client-application-ids>
        <application-id>{{interactive-client-id}}</application-id>
        <application-id>{{agent-client-id}}</application-id>
      </client-application-ids>
      <audiences>
        <audience>{{resource-app-id}}</audience>
      </audiences>
    </validate-azure-ad-token>
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
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.gateway.name
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
