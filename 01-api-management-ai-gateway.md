# 1. Set up the AI Gateway (Azure API Management)

> Part 1 of 3. See [README.md](README.md) for the full architecture and read order.

This sets up an Azure API Management (APIM) instance as the front door for MCP tool traffic in this architecture, using standard APIM **AI gateway capabilities** (MCP servers, policies, token validation) available on any v2 tier. The MCP server itself is deployed in [02-mcp-remote-server.md](02-mcp-remote-server.md); Entra ID app registrations used later are in [03-entra-id-oauth2.md](03-entra-id-oauth2.md).

> **Not the same thing:** Azure also has a standalone **AI Gateway tier (preview)** — a separate SKU with its own setup wizard, currently limited to East US 2 and Sweden Central, with pricing not yet announced. This guide doesn't require it — everything docs 2–4 use (MCP servers, `validate-azure-ad-token`) works on a normal v2-tier instance, everywhere v2 tiers are available. If you want the standalone preview tier's model/tool auto-discovery wizard instead, see §1.3 below, but it's optional.

## Prerequisites

- Azure subscription ([free account](https://azure.microsoft.com/free/) if needed).
- Azure CLI v2.60.0+: `az --version`, then `az login`.
- Sufficient permissions to create resource groups and APIM instances (Contributor or Owner on the target subscription).

## 1.1 Create a resource group

```bash
RESOURCE_GROUP="rg-ai-gateway"
LOCATION="centralus" # standing default for this project — keep every resource in this doc set in Central US

az group create --name $RESOURCE_GROUP --location $LOCATION
```

## 1.2 Create the APIM instance (v2 tier)

MCP server support and Entra ID token validation (`validate-azure-ad-token`) both require a **v2 SKU**. **Basic v2 is the cheapest tier that supports everything this guide needs** — it's also what Microsoft Foundry itself provisions by default when you create a new AI Gateway from the Foundry portal (doc 4 §4.1). Upgrade to Standard v2 or Premium v2 only if you need network-isolated backends, higher scale units, or (Premium v2 only) availability zones — see [feature comparison](https://learn.microsoft.com/azure/api-management/api-management-features).

Consumption tier is cheaper still (no fixed cost) but doesn't support Entra ID integration at all — not usable for this architecture.

```bash
APIM_NAME="apim-ai-gateway-$RANDOM"

az apim create \
  --name $APIM_NAME \
  --resource-group $RESOURCE_GROUP \
  --publisher-name "Your Org" \
  --publisher-email "you@example.com" \
  --sku-name BasicV2 \
  --sku-capacity 1
```

This provisions in several minutes. Portal alternative: **Create a resource** > **API Management** > choose **Basic v2** (or **Standard v2**/**Premium v2** for production). Check current pricing at [azure.microsoft.com/pricing/details/api-management](https://azure.microsoft.com/pricing/details/api-management/) — it varies by region and changes over time, so don't rely on a number written into this doc.

## 1.3 (Optional) Run the standalone AI Gateway tier setup wizard

Skip this section if you created a normal Basic v2/Standard v2/Premium v2 instance in §1.2 — it's for the separate, region-limited **AI Gateway tier (preview)** SKU mentioned above, and isn't required for docs 2–4. The setup wizard imports and registers assets on that gateway. In the Azure portal:

1. Open your APIM instance.
2. Under **Home** > **Configure your gateway**, select **Get started** (or navigate directly to the `/settings/start` route on the resource).

### Import models (optional at this stage)

3. Select **Import Foundry models** if you have Microsoft Foundry model deployments to govern through this gateway.
   - Select subscriptions/resource groups to scan.
   - Choose backend authentication: **Key-based** (gateway stores the account's API key) or **Managed identity** (gateway authenticates with its own Entra ID identity; the wizard grants it the **Foundry User** role on each account).
   - Select **Import**.
   - To connect a non-Foundry provider (AWS Bedrock, Google Vertex, OpenAI, Anthropic), use **Add a custom model** instead.

### MCP servers — skip auto-discovery for now

4. The wizard's **Discover MCP servers** step scans your subscriptions for existing MCP-capable resources (API Center, existing APIM MCP APIs, Azure Functions with the MCP extension, Logic Apps, Container Apps session pools). **Skip this for now** — the MCP server built in this guide doesn't exist yet. You'll expose it manually in [02-mcp-remote-server.md](02-mcp-remote-server.md) using **Expose an existing MCP server**, which is not part of this auto-discovery flow.

5. Select **Close** to finish the wizard.

## 1.4 AI gateway capabilities available on this instance

The AI Gateway tier layers the following on top of standard APIM policies — configure as needed once traffic is flowing (not required to complete this guide):

- **Token limits & quota** — cap tokens-per-minute or total quota per product/subscription.
- **Semantic caching** — cache LLM responses by semantic similarity to cut cost/latency.
- **Content safety** — integrate Azure AI Content Safety to screen prompts/completions.
- **Rate limiting** — standard `rate-limit-by-key` policies, also used later for MCP tool calls.

See [AI gateway capabilities in Azure API Management](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities) for policy syntax.

> **Note:** The AI Gateway tier (preview) and its setup wizard are subject to change while in preview.

## 1.5 Verify the gateway is working

1. In the portal, open your APIM instance > **Monitoring** > **Metrics**. Set **Metric** to **Requests**.
2. Make a test call to an imported model deployment (or, once MCP is wired up in doc 2, an MCP tool call) and confirm the request count increments.
3. For detailed logs: **Monitoring** > **Diagnostic settings** > **Add diagnostic setting** > select **Logs related to ApiManagement Gateway** > send to a Log Analytics workspace as **Resource specific**.
4. Query the logs:

```kusto
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
```

Look for `200` responses under the API name matching your gateway.

## Next

Go to [03-entra-id-oauth2.md](03-entra-id-oauth2.md) to register the Entra ID apps the MCP server and APIM will use, then [02-mcp-remote-server.md](02-mcp-remote-server.md) to deploy and wire the MCP server through this APIM instance.
