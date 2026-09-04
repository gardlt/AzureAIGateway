# 5. LLM gateway: expose models through APIM with budgets and rate limits

> Part 5. Reuses the APIM instance from [01-api-management-ai-gateway.md](01-api-management-ai-gateway.md) (`$APIM_NAME`, `$RESOURCE_GROUP`). Independent of docs 2–4 (MCP server) — this doc is about exposing **LLM model** traffic through the same gateway, not tools.

This wires up the same APIM instance as a governed front door for LLM calls: import a Microsoft Foundry/Azure OpenAI model deployment, group consumers into **Products** (the practical unit of "budget" in APIM), and apply rate limits + token quotas + observability per product.

## What "budget" means in APIM terms

APIM doesn't enforce a dollar-denominated spend cap directly — it enforces **token quotas** (`llm-token-limit` with `token-quota`/`token-quota-period`), which is the practical proxy for cost since Azure OpenAI/Foundry billing is token-based. Pair that with:

- **`llm-emit-token-metric`** — streams per-consumer token counts to Application Insights, so you can see actual spend patterns.
- **Azure Cost Management budgets** on the underlying Foundry/Azure OpenAI resource — a true dollar-denominated alert, but it's a resource-level guardrail (fires after the fact), not a per-consumer gate. Use both together: token quota gates in real time per consumer; Cost Management budget catches the aggregate.

## Prerequisites

- The APIM instance from doc 1 (`$APIM_NAME`, `$RESOURCE_GROUP`; Basic v2 is sufficient — this doc uses no feature above that tier).
- A Microsoft Foundry resource with at least one model deployed (Azure OpenAI or another provider). If you're also doing doc 4, this can be the same Foundry resource.

## 5.1 Import the model as an API

Portal steps:

1. In your APIM instance, **APIs** > **+ Add API** > **Create from Azure resource** > **Microsoft Foundry**.
2. **Select AI Service**: pick the subscription and the Foundry resource that has your model deployment(s). Select **Next**.
3. **Configure API**:
   - **Display name** / **Base path**: e.g. `llm`, so calls go to `https://<apim-name>.azure-api.net/llm/...`.
   - **Products**: leave unset for now — you'll create per-consumer products in §5.2, which is where the actual budget/rate-limit boundary lives.
   - **Client compatibility**: **Azure OpenAI** if you only need Azure OpenAI deployments (clients call `/openai/deployments/<name>/chat/completions`); **Azure AI** if you want to support non-Azure-OpenAI Foundry models through the same shape (`/models` endpoint, deployment name in the body); **Azure OpenAI v1** if you specifically need the v1 API surface.
4. **Manage token consumption**: you can set `llm-token-limit`/`llm-emit-token-metric` defaults here, or skip and configure them per-product in §5.3–5.4 for finer control.
5. **Apply semantic caching** / **AI content safety**: optional — see §5.6.
6. **Review** > **Create**.

The wizard auto-configures a system-assigned managed identity on APIM with the permissions needed to call the Foundry deployment — no keys to manage for the APIM → Foundry hop.

## 5.2 Group consumers into Products — the budget boundary

An APIM **Product** is the natural unit for "this team/app gets this budget and this rate limit." Create one product per consumer group (team, application, environment):

```bash
az apim product create \
  --resource-group $RESOURCE_GROUP \
  --service-name $APIM_NAME \
  --product-id "team-a-llm" \
  --product-name "Team A — LLM access" \
  --subscription-required true \
  --state published
```

Associate the LLM API from §5.1 with the product (portal: **Products** > `team-a-llm` > **APIs** > **+ Add**), then create a subscription under that product for the consuming app/team — this subscription's key is what they present in the `Ocp-Apim-Subscription-Key` header, and it's the `counter-key` the policies below key off of.

Repeat per consumer group. Each product gets its own rate limit and quota, set independently in §5.3–5.4.

If your consumers are the same Entra ID-authenticated callers from docs 2–3 rather than subscription-key holders, you can key the policies below off `context.User.Id`/the token's `appid` claim instead of `context.Subscription.Id` — see the note in §5.3.

## 5.3 Rate limits (protect against bursts)

On each product's policy (**Products** > `team-a-llm` > **Policies**):

```xml
<inbound>
    <base />
    <rate-limit-by-key calls="60" renewal-period="60" counter-key="@(context.Subscription.Id)" />
</inbound>
```

This caps raw call volume (60 calls/minute per subscription here) — a blunt instrument against request-flood bursts, independent of token cost. Use `llm-token-limit`'s `tokens-per-minute` (§5.4) for the AI-aware version of this same protection.

## 5.4 Token quotas (the actual budget lever)

On the same product policy, add `llm-token-limit`:

```xml
<inbound>
    <base />
    <llm-token-limit
        counter-key="@(context.Subscription.Id)"
        tokens-per-minute="10000"
        token-quota="1000000"
        token-quota-period="Monthly"
        estimate-prompt-tokens="false"
        remaining-tokens-variable-name="remainingTokens"
        remaining-quota-tokens-variable-name="remainingQuotaTokens" />
</inbound>
```

- `tokens-per-minute` — burst protection scoped to actual token cost (a TPM cap), not just call count.
- `token-quota` + `token-quota-period` — the budget: this product's total token allowance over `Hourly`/`Daily`/`Weekly`/`Monthly`/`Yearly`. Exceeding `tokens-per-minute` returns `429`; exceeding `token-quota` returns `403`.
- `counter-key` must be consistent across every scope where you apply the same key's policy (product, API, global) — mixing different `tokens-per-minute` values for the same key across scopes causes unpredictable behavior in v2 tiers (token-bucket algorithm).

If consumers authenticate with Entra ID tokens (docs 2–3 pattern) instead of subscription keys, key off the token instead:

```xml
<llm-token-limit counter-key="@(context.Request.Headers.GetValueOrDefault("Authorization","").Split(' ').Last())" .../>
```

(Illustrative — in practice extract a stable claim like `appid`/`oid` via `Jwt.Parse` rather than keying on the raw token string, so token refreshes don't reset the counter.)

Set different `token-quota` values per product to give teams different budgets from the same underlying model deployment.

## 5.5 Observability: see what's actually being spent

Add `llm-emit-token-metric` to the same policy (or globally, for cross-product dashboards):

```xml
<inbound>
    <base />
    <llm-emit-token-metric namespace="llm-metrics">
        <dimension name="Product" value="@(context.Product.Name)" />
        <dimension name="Subscription" value="@(context.Subscription.Id)" />
        <dimension name="API" value="@(context.Api.Id)" />
    </llm-emit-token-metric>
</inbound>
```

This sends per-request token counts to Application Insights as custom metrics with the dimensions you define — filter/alert on them per team in Azure Monitor. Also enable **logging for LLM APIs** (API > **Settings** > diagnostic logging) to capture prompts/completions for audit, and use APIM's built-in **analytics workbook** (portal, under the API) for a token-consumption dashboard without building one from scratch.

Pair this with an **Azure Cost Management budget** on the Foundry/Azure OpenAI resource itself (Foundry resource > **Cost Management** > **Budgets**) for a true dollar alert as a backstop — the token quota above is the real-time per-consumer gate; the Cost Management budget is the aggregate financial tripwire.

## 5.6 Optional: semantic caching and content safety

**Semantic caching** — cache completions by semantic similarity to cut both latency and token spend on repeated/similar prompts:

```xml
<inbound>
    <base />
    <llm-semantic-cache-lookup score-threshold="0.05" embeddings-backend-id="embeddings-backend" embeddings-backend-auth="system-assigned">
        <vary-by>@(context.Subscription.Id)</vary-by>
    </llm-semantic-cache-lookup>
</inbound>
<outbound>
    <base />
    <llm-semantic-cache-store duration="60" />
</outbound>
```

Requires an embeddings model deployment and a configured cache — see [Enable semantic caching of responses](https://learn.microsoft.com/azure/api-management/azure-openai-enable-semantic-caching) for the embeddings-backend setup this policy references.

**Content safety** — screen prompts against Azure AI Content Safety before they reach the model:

```xml
<inbound>
    <base />
    <llm-content-safety backend-id="content-safety-backend" shield-prompt="true" />
</inbound>
```

See [Enforce content safety checks on LLM requests](https://learn.microsoft.com/azure/api-management/llm-content-safety-policy) for the Content Safety resource prerequisite.

## 5.7 Optional: backend pools for failover and multi-region

If you have more than one model deployment (e.g. a Provisioned Throughput Units deployment plus a pay-as-you-go fallback, or the same model in two regions), configure a **backend pool** so APIM spreads or fails over traffic instead of relying on a single deployment:

```bash
az apim backend create --resource-group $RESOURCE_GROUP --service-name $APIM_NAME \
  --backend-id "ptu-deployment" --url "https://<ptu-foundry>.openai.azure.com" --protocol http

az apim backend create --resource-group $RESOURCE_GROUP --service-name $APIM_NAME \
  --backend-id "payg-deployment" --url "https://<payg-foundry>.openai.azure.com" --protocol http
```

Then, in the portal, **Backends** > your primary backend > **Load balancer** tab > **+ Create new pool**, and set priority groups so the PTU deployment is tried first and PAYG only receives traffic once the PTU backend's circuit breaker trips (spillover pattern) — or use **Weighted** for even round-robin sharing between regions. Up to 30 backends per pool; APIM's own load balancing is approximate (gateway instances don't synchronize state), which is fine for cost/availability failover but don't rely on it for strict traffic-split guarantees.

## 5.8 Verify

1. In the portal, open the imported LLM API > **Test** tab, select a chat-completions operation, send a request under a product's subscription key. Confirm the response includes `usage` (token counts).
2. Send enough requests to exceed a product's `tokens-per-minute` — confirm you get `429` with a `Retry-After` header.
3. Check **Monitoring** > **Metrics** in APIM, or query Application Insights for the `llm-metrics` custom metric from §5.5, and confirm counts show up per product/subscription dimension.
4. Confirm the `ApiManagementGatewayLogs` Kusto query from doc 1 §1.5 now also shows entries for the LLM API's operations.

## Next

The LLM gateway (this doc) and the MCP tool gateway (docs 1–4) run on the same APIM instance but are independent API surfaces — a client or agent can call both through the same `$APIM_NAME` endpoint, governed by whichever auth/budget/rate-limit policy applies to each API.
