# AI Gateway — ARB Brief

**Ask:** approve Azure API Management (APIM), AI Gateway tier, as the single front door for every AI-shaped traffic pattern this org runs — MCP tool calls, LLM model calls, and agent-to-agent (A2A) calls — with Products (not the API itself) as the budget/rate-limit boundary, rather than a separate gateway or bespoke cost control per pattern.

Full detail: [../01-api-management-ai-gateway.md](../01-api-management-ai-gateway.md), [../05-llm-gateway-budgets-rate-limits.md](../05-llm-gateway-budgets-rate-limits.md), [../06-agent-gateway-capabilities.md](../06-agent-gateway-capabilities.md).

## Context

Three distinct traffic shapes need a gateway in front of them: tool calls (MCP), model calls (LLM), and agent-to-agent calls (A2A). Left alone, each tends to grow its own bespoke auth, rate limiting, and cost tracking — three things to secure and operate instead of one. Model traffic in particular needs real spend control before the monthly bill is the first signal.

## Decision

One APIM instance (`BasicV2` tier in this deployment) mediates all three:

- **Topology.** Each pattern (MCP, LLM, A2A) is its own API resource inside the same instance, with its own named policy file in Terraform — not one monolithic policy, but one operational surface.
- **Auth.** Every pattern reuses the same `validate-azure-ad-token` policy shape (see the MCP brief for the Entra ID design it's built on).
- **Budget/cost control for LLM traffic.** Consumers are grouped into APIM **Products** — the actual enforcement unit — with real-time **token quotas** (`llm-token-limit`) per product, since Azure OpenAI/Foundry billing is token-based, not dollar-based, at the gateway. Per-consumer token counts stream to Application Insights (`llm-emit-token-metric`). An Azure Cost Management budget on the underlying Foundry resource is the complementary dollar-denominated, after-the-fact backstop.
- **Protocol coverage for agent traffic.** A2A agents are imported natively — APIM rewrites and re-hosts the agent card at its own hostname so any framework-agnostic A2A client can call an agent behind the gateway. This is recorded explicitly as a boundary, not an oversight: **APIM has first-class, protocol-aware support for exactly two agent protocols today — MCP and A2A.** ACP, ANP, and others get no manifest rewriting or automatic tagging; they'd come in as generic REST/OpenAPI passthroughs or behind an adapter.

## Why this over the alternatives

| Option | Why not chosen |
|---|---|
| Separate gateway per traffic type | Triples the auth/policy/observability surface; no shared budget or rate-limit story across patterns. |
| No gateway — auth/limits/cost tracking built into each backend service | Pushes token validation and spend tracking into every MCP server, model deployment, and agent individually; no single revocation or spend-visibility point. |
| Rely on Azure Cost Management budgets alone for LLM spend | Fires only after spend has happened, at the resource level — can't stop one noisy consumer in real time or attribute spend per team. |
| Wait for every agent protocol to get native gateway support before adopting any | Blocks real work for a moving target; the two-protocol ceiling is documented so teams know the fallback path (generic import/adapter) exists today. |
| Chosen: one instance, per-pattern APIs/policies, Products as budget boundary, explicit protocol ceiling | One policy engine and one place for logs/budgets, with the actual per-pattern differences kept in independently reviewable Terraform resources rather than hidden inside one giant policy. |

## Risks

| Risk | Mitigation |
|---|---|
| Single point of failure for all AI traffic | APIM v2 tier supports zones/scaling; multi-region not yet configured — flag as follow-up if traffic requires it. |
| Policy sprawl as more patterns are added | Each pattern's policy lives in its own Terraform file, reviewed independently. |
| Token quota isn't a literal dollar cap across models at different price points | Acceptable for the current single/small model set; revisit with per-model quota weighting if that changes. |
| Products are the enforcement boundary, not the API — misconfigured product assignment silently changes who's limited | Product-to-API-to-policy wiring lives in Terraform, reviewed like code. |
| Teams may assume every agent protocol gets MCP/A2A-level treatment | Explicitly documented in doc 6 and here; check the protocol table before proposing a new integration. |

## Decision requested

Approve APIM AI Gateway as the standing pattern for all new AI/agent traffic — MCP, LLM, A2A, and whatever comes next added as its own API + policy inside the same instance — with Products/token-quotas as the standing cost-control mechanism for anything token-billed.
