# Container registry for the Go MCP server image (../mcp-server). Built with
# `az acr build` (cloud-side, no local Docker daemon needed) — see
# mcp-server/README.md.

resource "azurerm_container_registry" "gateway" {
  name                = replace("acr${var.apim_name}", "-", "")
  resource_group_name = azurerm_resource_group.gateway.name
  location            = azurerm_resource_group.gateway.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# Container App pulls via its own system-assigned identity (mcp-server.tf).
# NOTE: on a first-time apply this role assignment and the container app are
# created together — if the very first revision fails to pull with a 401,
# re-run `terraform apply` once role propagation (usually <2min) finishes.
resource "azurerm_role_assignment" "mcp_acr_pull" {
  scope                = azurerm_container_registry.gateway.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app.mcp_server.identity[0].principal_id
}
