# 9. Agent-to-Agent (A2A)

Doc 6 (§6.3–6.5) covers one side of A2A: importing *someone else's* A2A agent into APIM as a governed, subscription-keyed API. This doc covers the other two sides, which doc 6 doesn't touch:

- **Building** an A2A server — exposing an agent this repo owns (or a partner team's agent) over the A2A protocol.
- **Calling out** — a Foundry agent invoking a *remote* A2A endpoint, and how that outbound call authenticates.

All three sides compose: this repo's Foundry agent (doc 4/7) could call a partner's A2A agent (this doc, §9.4), reached through APIM's A2A import (doc 6) for governance, while the partner's own agent is itself hosted using the self-hosting pattern in §9.2.

## 9.1 What A2A is, and when it's the right tool

A2A is an [open protocol](https://a2a-protocol.org/latest/) for agents to discover each other (via a published **agent card**), exchange messages, and coordinate on tasks over HTTP — framework- and language-agnostic. It is not a replacement for doc 4's in-process "agent calls MCP tool" pattern; it solves a different problem.

Use A2A when a boundary that in-process composition can't cross is real:

| Boundary | Example in this repo's terms |
|---|---|
| **Service** | The MCP server (doc 2) runs as its own Container App; a second agent running elsewhere can't call it as a function — it needs a network protocol. |
| **Team** | A partner team owns a compliance-review agent. You get its agent card and endpoint, not its code. |
| **Organization** | A third-party vendor's agent (document processing, triage) — A2A is the interoperable way to discover and call it regardless of what it's built with. |
| **Independent release cycles** | This repo's Foundry agent (doc 4) and a self-hosted A2A agent (doc 8) ship on different schedules, different languages. |

If everything lives in one process under one team, agents-as-tools (doc 4's pattern) is simpler and has no network hop. Reach for A2A only when a boundary in the table above is actually present — every A2A call is an HTTP round-trip, and it hands you the usual distributed-systems tax: timeouts, retries, versioning, and a remote conversation state (keyed by `contextId`) that this side of the call doesn't see into.

## 9.2 Self-hosting an A2A server

This repo's MCP server (doc 2) is a Python Container App behind APIM. If a future agent in this repo needs to be *called* via A2A rather than only calling out, the same deployment shape applies — Container App + APIM front door — with the A2A protocol layer swapped in for the MCP one.

Microsoft ships `agent-framework-a2a` (Python) for this:

```bash
pip install agent-framework-a2a --pre
```

It provides `A2AExecutor`, which adapts any Agent Framework agent to the A2A server-side protocol — running the agent, mapping its output to A2A events/artifacts, and driving task-status updates through the official [`a2a-sdk`](https://pypi.org/project/a2a-sdk/). Your app still assembles the surrounding pieces: the agent card, `DefaultRequestHandler`, a task store, and the routes.

```python
import uvicorn
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill
from agent_framework import Agent
from agent_framework.a2a import A2AExecutor
from agent_framework.openai import OpenAIChatClient
from starlette.applications import Starlette

public_agent_card = AgentCard(
    name="Example Agent",
    description="What this agent does.",
    version="1.0.0",
    default_input_modes=["text"],
    default_output_modes=["text"],
    capabilities=AgentCapabilities(streaming=True),
    supported_interfaces=[
        AgentInterface(url="http://localhost:9999/", protocol_binding="JSONRPC"),
    ],
    skills=[AgentSkill(id="example", name="Example", description="...", tags=[], examples=[])],
)

agent = Agent(client=OpenAIChatClient(), name="Example Agent", instructions="...")

request_handler = DefaultRequestHandler(
    agent_executor=A2AExecutor(agent, stream=True),
    task_store=InMemoryTaskStore(),
    agent_card=public_agent_card,
)

server = Starlette(routes=[
    *create_agent_card_routes(public_agent_card),
    *create_jsonrpc_routes(request_handler, "/"),
])

uvicorn.run(server, host="0.0.0.0", port=9999)
```

Notes that carry over from doc 2/doc 3 directly:

- `supported_interfaces[].url` is the raw backend URL. When this server sits behind APIM (§9.5), that URL is internal — APIM's A2A import rewrites the hostname in the published agent card to its own, exactly the way doc 6 §6.3 describes for imported agents.
- `A2AExecutor` propagates the A2A `contextId` as the agent's session ID — the same role `contextId` plays in doc 4's MCP session model, just named differently.
- This server has **no built-in auth** — `DefaultRequestHandler` will answer any caller unless you add it. Don't deploy it directly to the internet the way §7.3a warns against for bare app registrations; front it with APIM (§9.5) or add auth middleware before exposing it, the same posture doc 2 takes for the MCP server.
- .NET and Go equivalents exist (`Microsoft.Agents.AI.Hosting.A2A.AspNetCore`, `provider/a2aprovider`) if a future agent in this repo isn't Python — same shape, different package.

## 9.3 Testing a secured A2A endpoint

If the server requires bearer auth (see §9.5 for what issues that token), a test client attaches it via an `AuthInterceptor`:

```python
from a2a.client.auth.interceptor import AuthInterceptor

class BearerAuth(AuthInterceptor):
    def __init__(self, token: str):
        self.token = token

    async def intercept(self, request):
        request.headers["Authorization"] = f"Bearer {self.token}"
        return request

async with A2AAgent(
    name="secure-agent",
    url="https://secure-a2a-agent.example.com",
    auth_interceptor=BearerAuth("your-token"),
) as agent:
    response = await agent.run("Hello!")
```

## 9.4 Foundry agent calling a remote A2A agent — authentication

This is the inverse of §9.2: the Foundry agent from doc 4/7 is the *caller*, and the A2A endpoint is somebody else's. Foundry Agent Service fetches the remote agent's card, then invokes its tools — and the auth model splits on one question: **does the call need to carry a specific user's identity, or is one shared identity enough for every caller?**

| Scenario | Method | User context preserved |
|---|---|---|
| Every caller should have the same access (e.g. a shared internal agent) | Key-based, or Entra ID (agent/project managed identity) | No |
| Each caller's permissions must scope the call (e.g. "only see repos this user can access") | OAuth identity passthrough | Yes |
| Endpoint is public / requires nothing | Unauthenticated | No |

**Key-based** — an API key or PAT stored in a Foundry project connection, sent as a header (`Authorization: Bearer <token>`, `x-api-key: <key>`, or a custom header). Simplest option; the tradeoff is the same one flagged for `mcp-client-agent`'s original secret in doc 7 — it's a shared secret anyone with project access can read, so treat rotation and project-access scoping as mandatory, not optional.

**Microsoft Entra ID — agent identity / project managed identity** — no secret to manage; Foundry requests a token from Entra using the calling agent's (or project's) managed identity and attaches it. This is the direct extension of doc 7/8's Agent ID work: once an agent has a real Entra Agent ID instance (doc 7 §7.1) or the self-hosted workload-identity pattern (doc 8), that same identity is what authenticates its *outbound* A2A calls — no separate credential to provision. Requires role assignments on whatever backs the remote endpoint, scoped via:

```bash
azd ai connection create my-a2a-connection \
  --kind remote-a2a \
  --target https://<a2a-endpoint> \
  --auth-type agentic-identity \
  --audience "<entra-audience>"
```

(`--auth-type project-managed-identity` for the project-identity variant — use this when every agent in the project should share one identity rather than each having its own.)

**OAuth identity passthrough** — for the case Entra-agent-identity and key-based both deliberately avoid: preserving the *calling user's* permissions on the remote side. First interaction produces a consent link; the user signs in to the remote service once, and Foundry stores the resulting access/refresh token pair scoped to that user+agent pair, replaying it on later calls and refreshing silently. Needs the **Foundry Agent Consumer** role on the project/agent (least privilege — prefer it over the broader **Foundry User** role for end users who only consume the agent, not build it).

**Agent-card fetch is unauthenticated by default.** Whichever method you pick above, it applies to tool calls only — Foundry fetches the *agent card* anonymously first. Most endpoints publish their card publicly, so this is fine. If a remote endpoint protects the card path itself, set `send_credentials_for_agent_card: true` on the A2A tool definition to send the connection's credentials there too — and only then, since it widens exposure of a shared secret unnecessarily otherwise:

```json
{
  "type": "a2a_preview",
  "base_url": "https://<a2a-endpoint>",
  "project_connection_id": "<connection-id>",
  "send_credentials_for_agent_card": true
}
```

Credentials only ever go to the host in `base_url`, over HTTPS — Foundry silently falls back to an anonymous card fetch rather than leaking credentials to a different host or over HTTP.

## 9.5 Fronting a self-hosted A2A server with APIM

Doc 6 §6.3–6.5 already describes importing an A2A agent card into APIM (subscription-key auth, rate limiting, the `genai.agent.id`/`genai.agent.name` OpenTelemetry attributes). That's the mechanism to put in front of the server built in §9.2, rather than exposing the Container App directly — same reasoning doc 2 gives for fronting the MCP server with APIM instead of hitting its FQDN.

Two things worth calling out that aren't obvious from doc 6 alone:

- **APIM's purpose-built A2A import does more than a generic API import.** It rewrites the agent card's hostname to APIM's own, forces the preferred transport to JSON-RPC, strips other `additionalInterfaces`, and rewrites the card's security requirements to point at APIM's subscription-key requirement — all automatically, from the agent card URL alone.
- **This repo's current Terraform (`modules/ai-gateway/main.tf`, `enable_a2a_gateway`) does not use that import path.** It hand-builds a generic `azurerm_api_management_api` with manually declared operations (`a2a_agent_card`, `a2a_jsonrpc`) and a `rate-limit-by-key` policy, because the `azurerm` provider has no dedicated A2A-import resource type as of this writing — the same "provider hasn't caught up to the portal feature" gap doc 7/8 flag for Entra Agent ID blueprints. If/when `azurerm` ships one, swap it in; until then, the manual card-rewrite behavior (hostname, transport, security requirements) has to be replicated by hand in the policy if it's needed, or accepted as a gap.

## 9.6 Summary — which doc covers which A2A role

| Role | Doc |
|---|---|
| Governing an *inbound* A2A agent as an APIM-managed API (someone else built it) | Doc 6 §6.3–6.5 |
| Building/self-hosting an A2A server for an agent this repo owns | This doc, §9.2–9.3 |
| A Foundry agent authenticating *outbound* calls to a remote A2A agent | This doc, §9.4 |
| The identity that backs an outbound Entra-based A2A call | Doc 7 (Foundry-managed) / Doc 8 (self-hosted) |
| Fronting a self-hosted A2A server with APIM for governance | This doc §9.5, mechanism in Doc 6 |

See [arb/03-agent-arb-brief.md](arb/03-agent-arb-brief.md) for the ARB-level risk/decision summary covering agent identity and A2A together.
