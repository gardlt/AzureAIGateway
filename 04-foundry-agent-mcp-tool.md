# 4. Microsoft Foundry: self-hosted agent runners using the MCP server as a tool

> Part 4. Requires the APIM instance from [01-api-management-ai-gateway.md](01-api-management-ai-gateway.md), the MCP server exposed through it from [02-mcp-remote-server.md](02-mcp-remote-server.md) (`$MCP_URL`), and the service-to-service Entra ID app from [03-entra-id-oauth2.md](03-entra-id-oauth2.md) (`$AGENT_CLIENT_ID`, `$AGENT_CLIENT_SECRET`, `$TENANT_ID`). See [README.md](README.md) for the full read order.

This covers the case where your agent's **compute is self-hosted** — it runs on infrastructure you manage (a VM, a container, a self-hosted runner), not inside Foundry's managed Agent Service — and you register it into Foundry Control Plane for governance/observability, while the agent itself calls the MCP server as a tool using the same service-to-service pattern from doc 3.

If instead your agent runs *inside* Foundry Agent Service (fully managed), skip to §4.6 — Foundry has a simpler built-in "Add tool > Custom > MCP" flow that acquires the token for you.

## Architecture

```
Self-hosted agent runner (your compute)
        |  1. calls MCP tool: client-credentials token via $AGENT_CLIENT_ID
        v
Azure API Management (doc 1/2)  <-- validates token, routes to MCP server
        |
        v
Azure Container Apps (MCP server, doc 2)

Foundry Control Plane
        |  registers the runner as a custom agent (inbound governance/observability only)
        v
Self-hosted agent runner  <-- clients call the agent through Foundry's generated proxy URL
```

Two separate relationships, easy to conflate: Foundry Control Plane governs **inbound** calls to your agent (clients → Foundry proxy → your runner). The MCP tool call is **outbound** from your runner (your runner → APIM → MCP server), using the doc 3 service-to-service app — Foundry Control Plane isn't in that path at all.

## Prerequisites

- A Foundry resource and project, in **Foundry (new)** portal (`https://ai.azure.com/nextgen` — look for the "New Foundry" banner).
- Your self-hosted agent runner deployed at a reachable HTTPS endpoint (any compute — this guide doesn't prescribe how you host it).
- `$MCP_URL`, `$TENANT_ID`, `$AGENT_CLIENT_ID`, `$AGENT_CLIENT_SECRET` from doc 3.
- Application Insights connected to your Foundry project (for agent tracing).

## 4.1 Attach the APIM instance from doc 1 as Foundry's AI Gateway

Foundry Control Plane requires an AI gateway on the Foundry resource — reuse the same APIM instance from [01-api-management-ai-gateway.md](01-api-management-ai-gateway.md) rather than standing up a second one.

Requirements for reusing an existing APIM instance:

- Same Microsoft Entra tenant and same subscription as the Foundry resource.
- At least **API Management Service Contributor** (or Owner) role on the APIM instance.
- APIM instance on a **v2 tier** (already satisfied — doc 1 created Standard v2/Premium v2).

Steps:

1. In the Foundry portal, go to your Foundry resource > **Manage** > **AI Gateway**.
2. Select **Add AI Gateway** > **Use existing APIM**.
3. Select the `$APIM_NAME` instance from doc 1. If it doesn't appear, re-check the requirements above.
4. Save.

## 4.2 Register the self-hosted runner as a custom agent

This gives you centralized observability and access control over calls *into* your agent — independent of the MCP tool wiring in §4.3.

1. In your Foundry project, select **Manage** > **Project details** > **Connected resources**, and confirm an **Application Insights** connection exists (add one if not).
2. Select **Operate** > **Assets** > **Register asset**.
3. Fill in the agent's platform details:
   - **Agent URL**: your runner's base endpoint (e.g. `https://your-runner.example.com/v1/`, without a trailing operation path).
   - **Protocol**: `HTTP` (or `A2A` if your runner implements the [A2A protocol](https://a2a-protocol.org/latest/) and serves an agent card at `/.well-known/agent-card.json`).
   - **OpenTelemetry agent ID**: optional — set this if your runner emits OpenTelemetry GenAI traces under a specific `gen_ai.agent.id`.
4. Fill in how it should appear in Foundry:
   - **Project**: the project from §4.1 (must have the AI gateway attached).
   - **Agent name**: e.g. `self-hosted-runner-1`.
5. Save. Foundry Control Plane generates a **new proxy URL** — copy it from the **Assets** pane (select the agent's radio button, not its name, to see the info pane).

Distribute the **new proxy URL** to whatever calls your agent going forward, instead of the original runner endpoint — Foundry now sits in front of it for access control and tracing. The original authentication your runner already requires (if any) still applies; Foundry just proxies the call.

### Instrument the runner for tracing (recommended)

If your runner is custom code, emit traces per the [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) to the same Application Insights resource as your Foundry project (its connection string is under **Manage** > **Project details**). This is what makes tool calls to the MCP server (§4.3) show up as spans in Foundry's **Traces** view rather than opaque HTTP calls.

## 4.3 Wire the self-hosted runner's MCP tool call

Since the runner isn't inside Foundry Agent Service, Foundry can't acquire the MCP token on your behalf — your runner's own code does it, using the **agent client app** from doc 3 §3.3 (client credentials, no user present).

```python
import os
import httpx

TENANT_ID = os.environ["TENANT_ID"]
AGENT_CLIENT_ID = os.environ["AGENT_CLIENT_ID"]
AGENT_CLIENT_SECRET = os.environ["AGENT_CLIENT_SECRET"]
MCP_URL = os.environ["MCP_URL"]  # e.g. https://<apim-name>.azure-api.net/mcp-server/mcp

def get_mcp_token() -> str:
    resp = httpx.post(
        f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token",
        data={
            "client_id": AGENT_CLIENT_ID,
            "client_secret": AGENT_CLIENT_SECRET,
            "scope": f"{MCP_URL}/.default",
            "grant_type": "client_credentials",
        },
    )
    resp.raise_for_status()
    return resp.json()["access_token"]
    # Cache this token and refresh only after it expires (check `exp`) —
    # don't request a new one on every tool call.

def call_mcp_tool(method: str, params: dict) -> dict:
    token = get_mcp_token()
    resp = httpx.post(
        MCP_URL,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
    )
    resp.raise_for_status()
    return resp.json()
```

Call `call_mcp_tool("tools/list", {})` to discover available tools, and `call_mcp_tool("tools/call", {"name": "<tool>", "arguments": {...}})` to invoke one — wire this into wherever your runner's orchestration/agent loop decides to use a tool (LangGraph, Semantic Kernel, a hand-rolled loop, etc. — the MCP call itself is the same regardless of framework).

Prefer a **managed identity + federated credential** over the static `$AGENT_CLIENT_SECRET` if your runner's compute supports it (e.g. it runs on Azure Container Apps, VMs, or AKS with workload identity) — same recommendation as doc 3's security notes, avoids a long-lived secret in the runner's environment.

## 4.4 Least-privilege: scope what the agent can call

The agent client's token carries `roles: ["Tools.Invoke.All"]` (doc 3 §3.1) — every tool the MCP server exposes. If this runner should only reach a subset of tools, either:

- Define additional, narrower app roles on the `mcp-server` app registration (e.g. `Tools.Read.All` vs `Tools.Invoke.All`), assign the runner's client app only the role(s) it needs, and branch APIM's MCP server policy on the `roles` claim (doc 2 §2.6) to gate specific tool operations per role.
- Or split tools across multiple MCP servers exposed through APIM, each with its own scope, if the tool sets are cleanly separable.

## 4.5 Verify end to end

1. Call your runner through the **Foundry proxy URL** from §4.2 with a prompt that should trigger a tool call.
2. In Foundry portal, **Operate** > **Assets** > select the agent > **Traces**. Confirm an entry for the inbound call, and (if instrumented per §4.2) a nested span for the outbound MCP tool call.
3. In the APIM instance (doc 1 §1.5), check **Monitoring** > **Metrics** > **Requests**, or the `ApiManagementGatewayLogs` Kusto query, for a hit against the MCP server API around the same timestamp — confirms the tool call actually reached APIM and not just your runner's logs.
4. If the tool call fails, check in order: the token's `roles` claim (§4.3/§4.4), APIM's `validate-azure-ad-token` policy (doc 2 §2.6), then the container app logs (`az containerapp logs show`).

## 4.6 Alternative: agent runs inside Foundry Agent Service (not self-hosted)

If your agent is fully managed by Foundry Agent Service rather than self-hosted, Foundry has a built-in MCP tool connector that acquires the token for you — no code in §4.3 needed:

1. In Foundry portal, open your project > **Build** > **Tools** (or Agent Builder).
2. **Add tool** > **Custom** > **Model Context Protocol** > **Create**.
3. Enter:
   - **Name**: e.g. `mcp-server`.
   - **Remote MCP Server endpoint**: `$MCP_URL`.
   - **Authentication**: **Microsoft Entra**.
   - **Type**: **Project Managed Identity** (the Foundry project's own identity) or **Agent identity**, depending on which identity you want to appear in the token.
   - **Audience**: `$MCP_URL` (the Application ID URI from doc 3 §3.1).
4. Select **Connect**, then **Save** on the agent.

For this path, grant the identity you selected (project managed identity or agent identity) the `Tools.Invoke.All` app role on the `mcp-server` app registration (doc 3 §3.1), the same way §3.3 grants it to `mcp-client-agent` — just against a managed identity's service principal instead of a client-secret app.

## Next

You now have the full chain end to end: AI Gateway (doc 1) → MCP server secured with both interactive and service-to-service OAuth2 (docs 2–3) → a self-hosted agent runner, governed by Foundry Control Plane, calling that MCP server as a tool (this doc).
