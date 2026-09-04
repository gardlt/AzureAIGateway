# 6. Agent gateway: what APIM can do for AI agents

> Part 6. Builds on the APIM instance from [01-api-management-ai-gateway.md](01-api-management-ai-gateway.md). Complements [04-foundry-agent-mcp-tool.md](04-foundry-agent-mcp-tool.md) (Foundry Control Plane agent registration) with APIM-native Agent2Agent (A2A) protocol support, and ties together every governance capability from docs 1–5 under one gateway.

"AI gateway" in APIM isn't only models (doc 5) and tools (docs 1–4) — the same policy engine, on the same instance, also mediates **agent-to-agent (A2A) traffic**: one agent calling another across a service, team, or organizational boundary. This doc is a capability inventory plus the one piece not yet covered — importing and securing an A2A agent API directly in APIM.

## 6.1 Capability inventory

| Capability | What it gives you | Where in this doc set |
|---|---|---|
| **Traffic mediation** | Proxies A2A JSON-RPC, MCP tool calls, and LLM model calls through one instance, one policy engine | Docs 1 (gateway), 2–4 (MCP), 5 (LLM), 6 (A2A) |
| **Inbound auth** | `validate-azure-ad-token` (OAuth2/Entra ID) or subscription keys, uniformly across API types | Doc 3 (Entra apps), §6.4 below |
| **Outbound auth** | Managed identity to backends (no static secrets); credential manager for third-party OAuth backends | Doc 2 §2.3, doc 5 §5.1 |
| **Rate limiting** | `rate-limit-by-key` (raw calls), `llm-token-limit` (token-aware) | Doc 5 §5.3–5.4 |
| **Budgets** | `token-quota`/`token-quota-period` per Product | Doc 5 §5.4 |
| **Observability** | OpenTelemetry GenAI semantic-convention attributes (`gen_ai.agent.id`, `gen_ai.agent.name`), Application Insights, built-in analytics workbook | Doc 1 §1.5, doc 4 §4.2, §6.6 below |
| **Governance** | Products as access/budget boundaries, content safety on prompts, block/unblock inbound access (via Foundry Control Plane) | Doc 4 §4.2, doc 5 §5.6, §6.5 below |
| **Discovery** | Agent card rewritten and re-hosted through APIM's own hostname | §6.3 below |
| **Interop** | A2A is framework-agnostic — a .NET agent behind APIM can be called by a Python/LangChain/any-framework agent, and vice versa | §6.3 below |

## 6.1a Protocol landscape — what's first-class, what isn't

There are several agent interoperability protocols in the wild — **MCP** (agent-to-tool), **A2A** (agent-to-agent, Google/Linux Foundation), **ACP** (Agent Communication Protocol), **ANP** (Agent Network Protocol), among others. As of this writing, **APIM has protocol-aware, first-class support for exactly two: MCP and A2A** — both get dedicated import wizards, automatic manifest/agent-card rewriting, and built-in OpenTelemetry GenAI attribute tagging (docs 2–4 for MCP, §6.3 for A2A).

ACP, ANP, and any other agent protocol have **no native APIM support** today. If you need to front one of them, your options are:

- Import it as a generic REST/OpenAPI API (if it has an OpenAPI spec) or a plain passthrough backend (same mechanism as doc 2's "Expose an existing MCP server," minus the MCP-specific tooling) — you get standard APIM policies (rate limiting, auth, content safety), but no protocol-specific manifest rewriting or automatic `gen_ai.*` tagging; you'd add those yourself via policy expressions if needed.
- Wrap it behind an adapter that translates to MCP or A2A, and get the first-class treatment on the adapter's surface instead.

Check [AI gateway capabilities in Azure API Management](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities) periodically — this is an actively developing area and protocol support has expanded before (A2A support itself is comparatively recent).

## 6.2 Two ways APIM sits in front of an agent — pick based on what you need

| | **Foundry Control Plane registration** (doc 4 §4.2) | **A2A agent API import** (this doc, §6.3) |
|---|---|---|
| Protocol | HTTP (general) or A2A | A2A (JSON-RPC) only |
| What you get | Foundry portal asset inventory, traces, block/unblock UI | APIM-native policy control: rate limits, quotas, content safety, on the agent-to-agent call itself |
| Agent card handling | Foundry discovers it, generates its own proxy URL | APIM rewrites and re-serves the agent card at its own hostname |
| Requires Foundry project | Yes | No — plain APIM feature, works standalone |

They're not mutually exclusive — Foundry Control Plane's agent registration uses API Management under the hood to register agents as APIs, so registering an agent in Foundry (doc 4) can create exactly the kind of API this doc configures directly. Use §6.3 when you want an A2A agent governed by APIM without going through Foundry at all, or when you need policy control (rate limits, content safety) that Foundry's registration flow doesn't expose.

## 6.3 Import an A2A agent API into APIM

### Prerequisites

- An existing A2A-compatible agent with JSON-RPC operations and an agent card (default path `/.well-known/agent-card.json`).
- The APIM instance from doc 1 (any tier — A2A import is available on all APIM tiers, same as MCP server support).

### Steps

1. In your APIM instance, **APIs** > **+ Add API** > select the **A2A Agent** tile.
2. **Agent card**: enter the URL to your agent's agent card JSON document. Select **Next**.
3. **Create an A2A agent API**:
   - **Runtime URL** / **Agent ID**: auto-populated from the agent card if present; otherwise supply the JSON-RPC runtime URL and the agent ID your agent uses in its `gen_ai.agent.id` OpenTelemetry attribute.
   - **Display name** / **Description**: as you like.
   - **Base path**: route prefix, e.g. `agents/travel-booking`.
4. Select **Create**.

What APIM does automatically:

- Proxies JSON-RPC runtime operations to the backend agent, so policies (rate limiting, auth, content safety) apply to every call.
- Rewrites and re-serves the **agent card**: hostname replaced with the APIM instance's hostname, preferred transport set to JSON-RPC, other transports in `additionalInterfaces` stripped, and security requirements updated to include the APIM subscription key requirement.
- Emits `gen_ai.agent.id` and `gen_ai.agent.name` attributes on traces when Application Insights observability is enabled (§6.6) — no extra instrumentation needed on your side for this baseline.

Other agents discover and call your agent through APIM's URLs from here on — the **Runtime base URL** for JSON-RPC calls and the **Agent card URL** (both shown on the API's **Overview** page after creation) — instead of the original backend endpoint.

### Enable subscription key authentication

API > **Settings** > **Subscription** > enable **Subscription required**. Once enabled, callers must present a valid key in `Ocp-Apim-Subscription-Key` (header or `subscription-key` query param) to call the agent **or** to fetch its agent card through APIM.

### Test

```bash
# Agent card (through APIM)
curl "https://<apim-name>.azure-api.net/agents/travel-booking/.well-known/agent-card.json" \
  -H "Ocp-Apim-Subscription-Key: <key>"

# JSON-RPC call
curl -X POST "https://<apim-name>.azure-api.net/agents/travel-booking" \
  -H "Ocp-Apim-Subscription-Key: <key>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"message/send","params":{...}}'
```

### Limitations

- Only JSON-RPC-based A2A agent APIs are supported (not other transports).
- Deserialization of outgoing response bodies isn't supported — policies that need to inspect/transform the response body have limited reach here.

## 6.4 Secure agent-to-agent calls with Entra ID (reuse doc 3's pattern)

Subscription keys (§6.3) are the simplest inbound control, but the same `validate-azure-ad-token` approach from docs 2–3 applies here too, and maps directly onto the two auth scenarios agent-to-agent calls actually need:

- **Shared authentication** — the calling agent authenticates as itself, not on behalf of a specific end user (e.g. an internal orchestrator agent calling a shared "compliance-review" agent that treats every caller identically). This is exactly doc 3's **service-to-service pattern** (§3.3): a confidential client app, client-credentials grant, an app role like `Agent.Invoke.All` on the target agent's app registration, validated the same way as `mcp-client-agent` in doc 2 §2.6.
- **Individual authentication** — the target agent needs to act with the *calling user's own* permissions (e.g. a coding agent that should only see repos the calling user can see). This needs an on-behalf-of exchange, same caveat as doc 3 §3.4 — advanced, not built out step-by-step in this guide; see [Deploy Azure MCP Server with on-behalf-of authentication](https://learn.microsoft.com/azure/developer/azure-mcp-server/how-to/deploy-remote-mcp-server-on-behalf-of) for the underlying pattern, which generalizes to A2A the same way.

Apply `validate-azure-ad-token` on the A2A API's inbound policy (API > **A2A** > **Policies**) exactly as in doc 2 §2.6, swapping the audience for this agent's own Application ID URI and app role.

## 6.5 Apply governance policies

Same policy surface as MCP servers (doc 2 §2.5) and LLM models (doc 5) — configured under the A2A API's **A2A** > **Policies** blade:

```xml
<inbound>
    <base />
    <rate-limit-by-key calls="30" renewal-period="60" counter-key="@(context.Subscription.Id)" />
    <llm-content-safety backend-id="content-safety-backend" shield-prompt="true" />
</inbound>
```

Global (all-APIs) policies evaluate before this API's own policies — same rule as doc 2. If the target agent's backend is itself token-metered (e.g. it's a thin wrapper over an LLM), `llm-token-limit`/`llm-emit-token-metric` from doc 5 apply here too.

## 6.6 Observability

With Application Insights enabled on the APIM instance (doc 1 §1.5), the A2A API type automatically tags traces with:

- `gen_ai.agent.id` — the agent ID from the API's settings (§6.3).
- `gen_ai.agent.name` — the API's display name.

This is the same OpenTelemetry GenAI semantic convention Foundry Control Plane expects (doc 4 §4.2) — if this agent is also registered there, its traces line up under the same conventions whether the call went through Foundry's proxy or straight through this A2A API.

## 6.7 Verify end to end

1. Call the agent card URL through APIM (§6.3) and confirm the hostname is APIM's, not the backend's.
2. Make a JSON-RPC call through APIM with a valid subscription key or Entra ID token (§6.4) and confirm a response.
3. Exceed the rate limit (§6.5) and confirm `429`.
4. In Application Insights, confirm traces carry `gen_ai.agent.id`/`gen_ai.agent.name` and correlate with calls made in step 2.

## Next

At this point, one APIM instance (doc 1) governs models (doc 5), MCP tools (docs 2–4), and agent-to-agent traffic (this doc) — all under the same Entra ID identity patterns (doc 3), the same Product-based budget/rate-limit boundaries, and the same observability pipeline into Application Insights.
