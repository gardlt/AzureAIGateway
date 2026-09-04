# Azure AI Gateway + Remote MCP Server + Entra ID OAuth2

Step-by-step guide for standing up an Azure API Management (APIM) AI gateway, deploying a remote MCP server to Azure Container Apps, securing the whole path with Microsoft Entra ID OAuth2, connecting a self-hosted Microsoft Foundry agent runner to the MCP server as a tool, exposing LLM models through the same gateway with budgets and rate limits, and governing agent-to-agent (A2A) traffic through the same instance.

## Architecture

Three callers, one APIM-fronted MCP server, two OAuth2 patterns. Each caller's path is shown separately below; all three converge on the same `validate-azure-ad-token` check in APIM and the same MCP server in Container Apps.

### Pattern 1 — Interactive: Claude / VS Code (docs 2 §2.5–2.7, 3 §3.2)

```mermaid
sequenceDiagram
    participant User as Person (Claude / VS Code)
    participant APIM as Azure API Management
    participant Entra as Microsoft Entra ID
    participant MCP as MCP server (Container Apps)

    User->>APIM: 1. Call MCP server, no token
    APIM-->>User: 2. 401 + WWW-Authenticate (PRM URL)
    User->>APIM: 3. GET /.well-known/oauth-protected-resource
    APIM-->>User: 4. PRM doc (authorization_servers: Entra ID)
    User->>Entra: 5. Browser redirect: /authorize (PKCE)
    Entra-->>User: 6. Sign-in prompt, then auth code
    User->>Entra: 7. Exchange code for token
    Entra-->>User: 8. Access token (scp: mcp.tools.invoke)
    User->>APIM: 9. Retry call, Authorization: Bearer <token>
    APIM->>APIM: validate-azure-ad-token
    APIM->>MCP: 10. Forward request
    MCP-->>User: 11. Tool result
```

No config makes step 5 happen automatically — it's the MCP client following the spec once the PRM document (step 3–4) exists and `mcp-client-interactive` (doc 3 §3.2) is registered.

### Pattern 2 — Service-to-service: automated agent (docs 2 §2.6–2.7, 3 §3.3)

```mermaid
sequenceDiagram
    participant Agent as Automated agent
    participant Entra as Microsoft Entra ID
    participant APIM as Azure API Management
    participant MCP as MCP server (Container Apps)

    Agent->>Entra: 1. POST /token (client_credentials,<br/>mcp-client-agent + secret)
    Entra-->>Agent: 2. Access token (roles: Tools.Invoke.All)
    Agent->>APIM: 3. Call, Authorization: Bearer <token>
    APIM->>APIM: validate-azure-ad-token
    APIM->>MCP: 4. Forward request
    MCP-->>Agent: 5. Tool result
```

No browser, no user — headless at request time. Same server app registration and same APIM validation policy as Pattern 1, but the token carries a `roles` claim instead of `scp`.

### Pattern 3 — Self-hosted Foundry agent runner (doc 4)

```mermaid
sequenceDiagram
    participant Client as Client calling the agent
    participant Foundry as Foundry Control Plane
    participant Runner as Self-hosted agent runner
    participant Entra as Microsoft Entra ID
    participant APIM as Azure API Management
    participant MCP as MCP server (Container Apps)

    Client->>Foundry: 1. Call agent via Foundry proxy URL
    Foundry->>Runner: 2. Forward (inbound governance + tracing only)
    Runner->>Entra: 3. POST /token (client_credentials,<br/>mcp-client-agent + secret)
    Entra-->>Runner: 4. Access token (roles: Tools.Invoke.All)
    Runner->>APIM: 5. Call MCP tool, Authorization: Bearer <token>
    APIM->>APIM: validate-azure-ad-token
    APIM->>MCP: 6. Forward request
    MCP-->>Runner: 7. Tool result
    Runner-->>Foundry: 8. Agent response
    Foundry-->>Client: 9. Agent response
```

Foundry Control Plane only sits in the *inbound* path (steps 1–2, 8–9) — governing calls to the runner. The MCP tool call itself (steps 3–7) is identical to Pattern 2 and bypasses Foundry entirely.

## Read order

Entra ID app registrations must exist before you can finish wiring APIM to the MCP server, so read in this order even though the docs are numbered by deployment layer:

1. [01-api-management-ai-gateway.md](01-api-management-ai-gateway.md) — create the APIM instance and AI Gateway tier.
2. [03-entra-id-oauth2.md](03-entra-id-oauth2.md) — register the server + client apps, get IDs/secrets/scope.
3. [02-mcp-remote-server.md](02-mcp-remote-server.md) — deploy the MCP server to Container Apps, secure it with the app registrations from step 2, expose it through the APIM instance from step 1.
4. [04-foundry-agent-mcp-tool.md](04-foundry-agent-mcp-tool.md) — optional: register a self-hosted Foundry agent runner and have it call the MCP server as a tool, reusing the service-to-service app from step 2.
5. [05-llm-gateway-budgets-rate-limits.md](05-llm-gateway-budgets-rate-limits.md) — optional, independent of steps 2–4: expose an LLM model through the same APIM instance from step 1, with per-consumer token budgets, rate limits, and observability.
6. [06-agent-gateway-capabilities.md](06-agent-gateway-capabilities.md) — optional: capability inventory for agent traffic specifically, plus importing and securing an Agent2Agent (A2A) API through the same instance. Covers what's first-class (MCP, A2A) vs. not (ACP, ANP, others) as of this writing.

Each doc calls out the cross-references explicitly so you can also jump straight to whichever layer you're working on.
