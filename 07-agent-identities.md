# 7. Agent identities (Microsoft Entra Agent ID)

Doc 3 (§3.3) registers `mcp-client-agent` as a plain `azuread_application` + long-lived client secret, then uses it for the client-credentials call from the Foundry agent runner (doc 4) to the MCP server. That is exactly the anti-pattern [Microsoft Entra Agent ID](https://learn.microsoft.com/entra/agent-id/what-is-microsoft-entra-agent-id) exists to replace: a nonhuman workload identity with no sponsor, no lifecycle controls, and a secret instead of a managed credential. This doc covers the recommended pattern and what changes in this repo if you adopt it.

Agent ID is additive — it doesn't replace the OAuth mechanics in doc 3 (token requests still hit `/oauth2/v2.0/token`, APIM still validates with `validate-azure-ad-token`). It changes *what kind of object* backs `mcp-client-agent` and how that object is created, credentialed, and governed.

> **Preview.** Microsoft Entra Agent ID is currently in preview — the shape of Graph resources, portal UX, and some CLI/SDK surfaces referenced below can change before GA. Treat §7.4's migration as something to pilot in dev, not a required prod cutover on a deadline.

## 7.1 Core model

Two object types, not one:

| Object | Role | Analogy to doc 3 |
|---|---|---|
| **Agent identity blueprint** | Template: app permissions, Conditional Access, credential config, sponsor/owner, metadata. One blueprint per *kind* of agent. | Closest to today's `mcp-client-agent` app registration — but as a template, not a runtime identity. |
| **Agent identity (instance)** | A concrete, individually addressable identity created *from* a blueprint. One per running agent. | Doesn't exist in this repo today — there's one shared app reg for all callers. |

Disabling a blueprint kills every instance created from it (kill-switch). Instances inherit the blueprint's Conditional Access, permissions, and credential policy automatically — you don't re-apply policy per agent.

Every blueprint and instance needs:
- a **sponsor** (accountable for the agent's purpose — a person/group, not a technical admin)
- an **owner** (technical admin)
- description/tags/verified publisher metadata

Creating one requires the **Agent ID Administrator** or **Agent ID Developer** role plus `AgentIdentityBlueprint.Create`, via Copilot Studio, Microsoft Graph, or the Agent 365 CLI — never `az ad app create`, `New-MgApplication`, `New-AzADApplication`, or a raw `POST /applications`.

## 7.2 Which OAuth flow — mapped to this repo's two clients

| Client (doc 3) | Pattern | Flow |
|---|---|---|
| `mcp-client-interactive` | Public client, user signs in (VS Code/Claude) | User-driven — **unaffected** by Agent ID; stays a normal delegated/interactive registration. |
| `mcp-client-agent` | No user context, calls MCP server as itself (doc 4 runner) | **Autonomous agent** → client-credentials flow off an agent identity instance, not a bare app registration. |

Only `mcp-client-agent` is in scope for migration here.

## 7.3a Which architecture pattern this repo is

Microsoft's identity-architecture guidance frames the first decision as *how many blueprints, and how many instances per blueprint* — driven by trust boundaries, not by convenience. Doc 4's setup (one Foundry agent runner, calling the one MCP server) is the simplest case: a **single autonomous worker agent** — one blueprint, one instance. Don't over-provision:

- If Container Apps scales the runner to N replicas, that's still **one** agent identity shared by the replicas of the same logical agent — replicas aren't separate agents. Only mint a new instance for a genuinely distinct agent (a different runner, a different purpose).
- If you later add a second, unrelated agent (e.g., a separate Foundry agent for a different task), give it its own blueprint rather than a second instance off `mcp-client-agent`'s blueprint, unless it shares the exact same trust boundary and permission set.
- MCP servers/APIM itself are resources being called, not agents — they don't get agent identities.

## 7.3 Gap vs. this repo today

| Current (doc 3 §3.3) | Recommended | Why |
|---|---|---|
| `az ad app create` → plain `azuread_application` | Agent identity blueprint (`POST /applications/microsoft.graph.agentIdentityBlueprint`) + one instance per deployed agent | Traceability, per-instance disable, blueprint-level kill-switch |
| One shared identity for all agent-runner deployments | Unique instance per agent deployment | A compromised/misbehaving instance doesn't take down every caller |
| Long-lived client secret (`az ad app credential reset`) | Federated credential (managed identity) or certificate in Key Vault, rotated ≤12mo | Secrets in state/CI are the highest-value target here |
| No sponsor/owner/tags | Sponsor + owner + description required at creation | Required for access reviews below |
| No agent-specific Conditional Access | CA policy scoped by identity filter / custom security attribute (`Environment=dev\|prod`) | `mcp-client-agent` can't do MFA — needs its own policy, not exclusion from user policies |
| Not in any access review | 6–12mo sponsor attestation | Prevents this becoming an orphaned always-on credential |

## 7.4 Migrating `mcp-client-agent`

1. **Create the blueprint** (replaces the `az ad app create` step in doc 3 §3.3):
   ```bash
   az rest --method POST \
     --uri "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint" \
     --body '{
       "displayName": "mcp-client-agent",
       "description": "Autonomous caller: Foundry agent runner -> MCP server via APIM (doc 4)",
       "signInAudience": "AzureADMyOrg"
     }'
   ```
   Capture the returned `appId`/blueprint id — same slot `MCP_CLIENT_AGENT_APP_ID` fills today.

2. **Assign sponsor + owner** — required, no default. Portal: Entra admin center → Agent ID → Blueprints → *mcp-client-agent* → Sponsors/Owners. (No stable CLI surface yet; treat as a manual step, same as admin consent already is in doc 3 §3.4.)

3. **Grant the app role** exactly as doc 3 §3.3 step 4 does today, just against the blueprint's `appId` instead of the plain app reg:
   ```bash
   az ad app permission add --id $MCP_CLIENT_AGENT_APP_ID \
     --api $MCP_SERVER_APP_ID --api-permissions "$TOOLS_INVOKE_ALL_ROLE_ID=Role"
   az ad app permission admin-consent --id $MCP_CLIENT_AGENT_APP_ID
   ```

4. **Credential**: for prod, use a certificate in Key Vault or a federated identity credential tied to the Foundry runner's managed identity — not `addPassword`. Reserve `addPassword` for local dev, and rotate it out before the runner goes live (doc 4).

5. **Create one instance per agent runner deployment** from the blueprint (portal wizard or Graph, currently preview) rather than reusing the blueprint's own credentials directly in more than one deployment.

6. Token acquisition in doc 4's runner code is otherwise unchanged: still `client_credentials` grant, still `scope=$MCP_URL/.default`, still validated by the same `validate-azure-ad-token` policy in `mcp-auth-flow.xml`.

**Terraform note**: the `azuread` provider has no native `agentIdentityBlueprint` resource as of this writing (it's a Graph `POST /applications/microsoft.graph.agentIdentityBlueprint` type-cast, not a distinct v1.0 resource type most providers model yet). Options, same tradeoff doc 3 already accepts for admin consent:
- keep blueprint creation as a manual/scripted `az rest` step outside Terraform (what's shown above), or
- model it with the `azapi` provider's generic `azapi_resource` against the same Graph path if you want it in state.

Either way, don't route it through `azuread_application` — that resource creates exactly the plain app registration Agent ID is meant to replace.

## 7.4a MCP-specific guidance: what's already right, one gap to close

Microsoft's own MCP + Agent ID guidance (`/entra/agent-id/secure-mcp-server`) confirms doc 2/3's implementation is already the recommended pattern for the MCP server side — no change needed there:
- v2 access tokens (`requestedAccessTokenVersion: 2`), Application ID URI matching the MCP server's canonical URL, no trailing slash (doc 3 §3.1 already gets this right — it's the #1 cause of `AADSTS9010010`).
- The `.well-known/oauth-protected-resource` document + `401` + `WWW-Authenticate: Bearer resource_metadata=...` on the failure path (`mcp-auth-flow.xml`, shown above) matches the documented pattern exactly.

One gap worth closing once `mcp-client-agent` becomes an agent identity (§7.4): tokens issued to an agent identity carry an `xms_act_fct` claim (value `11` = agent identity) and an `xms_par_app_azp` claim (the *parent blueprint's* app ID). Neither is an authorization signal — don't gate access on them — but `mcp-auth-flow.xml`'s `validate-azure-ad-token` step doesn't currently log either. Add them to the diagnostic/trace output so sign-in investigations can tell "this call came from an agent identity, descended from blueprint X" apart from a human or a plain app-reg caller, without another round-trip to Graph.

## 7.4b Alternative to hand-rolled client-credentials: the Auth SDK sidecar

Doc 4's Foundry agent runner currently (post-migration) would still do its own `client_credentials` token request against `/oauth2/v2.0/token`. Microsoft also ships an **Auth SDK sidecar** — a small container that sits next to the runner in the same Container Apps environment, handles token acquisition against the agent identity blueprint using a managed identity + federated credential (no `client_secret` in the runner's code or env at all), and exposes a local `/token` (and `/validate`, for a downstream API) endpoint over the pod-internal network. It's language-agnostic, so it doesn't require the runner to be .NET.

Worth piloting for the runner if you want to drop the client secret from doc 4's container entirely rather than just moving it into Key Vault (§7.4 step 4). Not required — a Key Vault-stored certificate/FIC credential called directly from the runner's existing code is equally valid and has less moving parts.

## 7.4c Integrating a third-party agent (e.g. AWS Bedrock)

Not this repo's current setup (doc 4's runner is Foundry), but relevant if a Bedrock- or n8n-hosted agent ever needs to call `mcp-server` through this gateway. Microsoft Entra Agent ID supports non-Microsoft agent platforms without embedding an Entra secret in them, via two patterns:

| Pattern | How it works | When to use |
|---|---|---|
| **Auth SDK sidecar** | A container running alongside the third-party agent (Docker/Docker Compose/Kubernetes) that acquires tokens for the agent's blueprint and exposes them locally (e.g. `localhost:7000/token`) — the agent calls the sidecar instead of Entra directly. | You control the deployment environment (your own AWS ECS/EKS, or wherever the agent runs) and can add a sidecar container. |
| **Workload identity federation** | The third-party platform's own workload identity (e.g. an AWS IAM role, verified via AWS STS) is federated as a credential source on the agent identity blueprint — no secret changes hands at all. | The platform has a mature workload-identity story (AWS STS-issued tokens) you can trust as a federated credential input. |

For AWS Bedrock specifically, the federation path is: the Bedrock agent's AWS IAM role gets an AWS STS token → that token is exchanged for a Microsoft Entra token via a federated identity credential configured on the blueprint → the agent uses the Entra token against `mcp-server` exactly like `mcp-client-agent` does today (§7.2). No AWS credentials or Entra secrets need to live in the same place.

Setup shape (both patterns): create the blueprint and agent identity as in §7.4, then either (a) deploy the Auth SDK sidecar next to the Bedrock agent and point it at that blueprint, or (b) configure the blueprint's federated credential to trust AWS STS as the issuer for that agent's IAM role. Either way, `mcp-auth-flow.xml`'s validation is unaffected — it's still validating a normal Entra-issued token on arrival, regardless of which platform obtained it.

## 7.5 Guardrail for AI coding assistants

Add this to this repo's own instructions file (`CLAUDE.md`/`AGENTS.md`) so future edits — by Claude Code, Copilot, or anyone else — don't regenerate `mcp-client-agent` as a plain app registration:

```markdown
## Microsoft Entra Agent ID
- To give an AI agent its own identity in Microsoft Entra, create an agent identity blueprint, then create agent identities from it.
- Don't create or reuse a standard app registration or service principal to represent an agent. Never use `az ad app create`, `New-MgApplication`, `New-AzADApplication`, or `POST /applications` to create an agent identity.
- Requires the Agent ID Developer or Agent ID Administrator role and the AgentIdentityBlueprint.Create permission.
- Reference: /entra/agent-id/how-to-plan-agent-identity-architecture
```

## 7.6 Monitoring & lifecycle

- Sign-in logs show each token acquisition by the blueprint/instance, resource, credential type, outcome — watch for spikes in token requests or unfamiliar resource access.
- Alert on: credential expiry approaching, agent blocked by Conditional Access/Identity Protection, repeated failed token acquisitions, unexpected permission/role changes on the blueprint.
- Quarterly: find instances with no sponsor, stale metadata, or no recent activity → reassign or decommission.
- Every 6–12 months: sponsor attests the agent is still needed. No attestation → evaluate decommissioning.
- Keep blueprint definitions and any Graph/CLI setup scripts in source control (this repo already does this for the current app-reg pattern — same discipline applies to the blueprint scripts in §7.4).

## 7.7 Worked example: provisioning a live Foundry-managed agent (eastus)

This section documents an actual run of §7.4's pattern end-to-end, against this repo's real `apim-isarabi`/`rg-ai-gateway` stack (eastus) and an existing Foundry project (`hermes-agent` in `aif-homelab-rv6t99la`, `rg-homelab-foundry`). It's the Foundry Agent Service variant of §7.4: instead of hand-rolling a Graph `agentIdentityBlueprint` for a self-hosted runner (doc 4's pattern), publishing an agent in Foundry auto-provisions the blueprint + instance identity for you (Foundry calls it a `ManagedAgentIdentityBlueprint`). Recording the exact steps, dead ends, and fixes here so the next agent doesn't hit the same walls.

### What got built

| Object | Value |
|---|---|
| Foundry project | `hermes-agent` (account `aif-homelab-rv6t99la`, `rg-homelab-foundry`) |
| Agent | `ai-gateway-mcp-agent` |
| Blueprint (`ManagedAgentIdentityBlueprint`) | `ai-gateway-mcp-agent-<suffix>` |
| Instance identity `principal_id`/`client_id` | `153f501c-3c97-4110-977e-aae615163d3b` (same value for both — instance identities are single-tenant, no separate principal/client split like the blueprint has) |
| MCP tool connection | `McpServer` project connection, `category: RemoteTool`, `authType: AgenticIdentityToken`, `audience: https://apim-isarabi.azure-api.net/mcp-server/mcp` |
| App role granted | `Tools.Invoke.All` on `mcp-server` app (`426dc472-b67d-4826-8adc-e031813972f8`), assigned to the **instance identity's service principal**, not the blueprint |

No app registration, no client secret — matches §7.3's "recommended" column exactly.

### Why a new agent instead of reusing the existing one

An existing agent (`silver-agent-0by0pdz5bz`) in the same project already had the `McpServer` connection wired up. Reusing it would have meant testing against — and risking breaking — someone else's running agent. Built a dedicated `ai-gateway-mcp-agent` instead, sharing only the read-only `McpServer` connection definition, and granted the role to *its own* instance identity rather than `silver-agent-0by0pdz5bz`'s.

### Steps taken (in order)

1. **Tried `azd ai` first** (`azd extension install azure.ai.projects azure.ai.connections azure.ai.agents`, then `azd ai connection create --kind remote-tool --auth-type agentic-identity --audience ...`). Blocked: `azd auth login` requires an interactive browser/device-code flow not available in this session. Abandoned `azd` and used raw REST with `az account get-access-token` bearer tokens for everything below — same operations, no interactive step.

2. **Found the correct agent-creation body by inspecting an existing agent first** (`GET {endpoint}/agents/silver-agent-0by0pdz5bz?api-version=v1`). A flat `{model, tools, instructions}` POST body 400s — the API needs a nested `definition` object:
   ```bash
   TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
   PROJECT_ENDPOINT="https://aif-homelab-rv6t99la.services.ai.azure.com/api/projects/hermes-agent"
   curl -X POST "$PROJECT_ENDPOINT/agents?api-version=v1" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{
       "name": "ai-gateway-mcp-agent",
       "definition": {
         "kind": "prompt",
         "model": "gpt-5",
         "instructions": "You are an AI assistant that helps people find information.",
         "tools": [
           { "type": "mcp", "server_label": "McpServer",
             "server_url": "https://apim-isarabi.azure-api.net/mcp-server/mcp",
             "project_connection_id": "McpServer" }
         ]
       }
     }'
   ```

3. **Granted the app role to the agent's own instance identity** (not the blueprint, not the pre-existing agent):
   ```bash
   az rest --method POST \
     --uri "https://graph.microsoft.com/v1.0/servicePrincipals/<mcp-server-sp-object-id>/appRoleAssignedTo" \
     --body '{
       "principalId": "153f501c-3c97-4110-977e-aae615163d3b",
       "resourceId": "<mcp-server-sp-object-id>",
       "appRoleId": "<Tools.Invoke.All role id>"
     }'
   ```

4. **First end-to-end test failed**: `"Failed to fetch agentic identity access token with status code: 400"`. Root cause: the `McpServer` connection had no `audience` set — the agentic-identity token exchange needs to know what resource to mint a token for.

5. **Broke the connection worse trying to fix it.** First fix attempt used the ARM management-plane PUT (`PUT .../connections/McpServer?api-version=2025-04-01-preview`) with a guessed body (`category: "CustomKeys"`, `authType: "AAD"`, `credentials.audience: ...`). It "succeeded" (200), but re-checking via the **data-plane** GET (`{endpoint}/connections/McpServer?api-version=v1`) showed the connection had actually flipped from `type: "RemoteTool"` / `credentials.type: "AgenticIdentityToken"` to `type: "CustomKeys"` / `credentials.type: "AAD"` — a different connection semantics entirely, silently. This is because **the ARM-plane and data-plane REST APIs for the same connection resource don't share a schema**: ARM uses `category`/`authType`/`credentials`, data-plane uses `type`/`credentials.type`, and the public ARM template reference doesn't even list `RemoteTool`/`AgenticIdentityToken` as valid enum values (they're real, just undocumented in that reference as of this writing).

   This connection is shared with `silver-agent-0by0pdz5bz` — a bad edit here would have broken it too.

6. **Corrective fix, in two passes** (confirmed with the user before each mutating call, since this touched a shared resource):
   - Pass 1 — restore the connection's actual type:
     ```bash
     TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
     URL="https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-homelab-foundry/providers/Microsoft.CognitiveServices/accounts/aif-homelab-rv6t99la/projects/hermes-agent/connections/McpServer?api-version=2025-04-01-preview"
     curl -X PUT "$URL" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{
       "properties": {
         "category": "RemoteTool",
         "authType": "AgenticIdentityToken",
         "target": "https://apim-isarabi.azure-api.net/mcp-server/mcp",
         "metadata": { "type": "custom_MCP" },
         "isDefault": true
       }
     }'
     ```
     This restored `type`/`authType` correctly, but the response showed `"audience": null` — because `audience` on this connection type is a **top-level `properties` field**, not nested inside `credentials` like most other ARM connection auth types.
   - Pass 2 — set `audience` at the right level:
     ```bash
     curl -X PUT "$URL" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{
       "properties": {
         "category": "RemoteTool",
         "authType": "AgenticIdentityToken",
         "target": "https://apim-isarabi.azure-api.net/mcp-server/mcp",
         "audience": "https://apim-isarabi.azure-api.net/mcp-server/mcp",
         "metadata": { "type": "custom_MCP" },
         "isDefault": true
       }
     }'
     ```
   - Verified via data-plane GET that the result now matches `silver-agent-0by0pdz5bz`'s connection shape exactly (`type: RemoteTool`, `credentials.type: AgenticIdentityToken`), confirming it wasn't broken.

7. **Second test attempt got past the token-fetch step but hit a 401 from APIM**: `"401 (Unauthorized). Access token is missing or invalid."` The agentic-identity token was now being minted correctly, but APIM's `validate-azure-ad-token` policy (`mcp-server.tf`) hardcodes a `client-application-ids` allowlist of exactly two IDs — `mcp-client-interactive` and `mcp-client-agent` (doc 3's app registrations). A Foundry agent's instance identity is neither, so its token — correctly signed, correctly audienced, correctly roled — was rejected purely on `azp`/client ID not being on the list. **This is the one real gap in this repo's Agent ID story once you go past §7.4's Graph-blueprint path into Foundry-managed agents**: the policy needs to know about every agent identity that's allowed to call in, not just the two doc-3 app registrations.

   Fixed it as a first-class Terraform input rather than a one-off portal edit, so it stays in source control:
   ```hcl
   # variables.tf
   variable "foundry_agent_client_ids" {
     description = "client_id of each Foundry-managed agent identity (doc 7) allowed to call the MCP server through APIM, in addition to mcp-client-interactive and mcp-client-agent."
     type        = list(string)
     default     = []
   }
   ```
   ```hcl
   # mcp-server.tf — inside validate-azure-ad-token's <client-application-ids>
   <application-id>{{interactive-client-id}}</application-id>
   <application-id>{{agent-client-id}}</application-id>
   %{ for id in var.foundry_agent_client_ids ~}
   <application-id>${id}</application-id>
   %{ endfor ~}
   ```
   ```hcl
   # terraform.tfvars
   foundry_agent_client_ids = [
     "153f501c-3c97-4110-977e-aae615163d3b", # ai-gateway-mcp-agent (hermes-agent project)
   ]
   ```
   Applied with `terraform plan -target=azurerm_api_management_api_policy.mcp_server` → review → `terraform apply` on the saved plan, so the change was scoped to exactly that one policy resource.

8. **Third test attempt got past auth entirely but timed out** — the MCP tool call itself failed, and the container app showed `runningState: ActivationFailed` / `ErrImagePull`. Unrelated to identity: **`acrapimisarabi` (the ACR built by this same eastus provisioning) was empty** — the `mcp-server` image had never been built/pushed after the centralus→eastus move (`terraform` provisions the registry and container app, it doesn't build/push the image). Fixed with:
   ```bash
   cd mcp-server && az acr build --registry acrapimisarabi --image mcp-server:latest .
   az containerapp revision restart -n mcp-server -g rg-ai-gateway --revision <active-revision>
   ```

9. **Fourth attempt succeeded end-to-end.** Working call shape (two REST quirks worth calling out — both undocumented in the obvious places):
   ```bash
   TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
   curl -X POST "$PROJECT_ENDPOINT/openai/v1/responses" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{
       "input": "Call the mcp tool to check available tools and tell me what it returns.",
       "tool_choice": "required",
       "agent_reference": { "name": "ai-gateway-mcp-agent", "type": "agent_reference" }
     }'
   ```
   - **No `?api-version=v1` on the `/openai/v1/responses` path** — the API rejects it: `"api-version query parameter is not allowed when using /v1 path"` (every other endpoint in this write-up does need `?api-version=v1`).
   - **`agent_reference` goes at the top level of the body, not inside `extra_body`.** `extra_body` is an SDK-only convenience wrapper (Python/JS clients merge it in); sent literally in a raw REST call it either 400s with `"Missing required parameter: 'model'"` or `"'extra_body' parameter is only supported for Fireworks and Perplexity models"`.

   Result: `200`, `mcp_list_tools` output showing the live tools the `mcp-server` container app exposes, fetched through Entra → APIM → Container Apps with no client secret anywhere in the path.

### Takeaways to fold back into §7.3/§7.4

- Add `foundry_agent_client_ids` (or equivalent) to any `validate-azure-ad-token` policy from day one if Foundry-managed agents (rather than only doc 4's self-hosted runner) will ever call this gateway — it's easy to provision the identity correctly and still get a 401 purely from the allowlist.
- When touching a project connection via ARM, always diff the **data-plane** representation before and after — the ARM and data-plane schemas for `Microsoft.CognitiveServices/accounts/projects/connections` don't correspond field-for-field, and a "successful" ARM PUT can silently retype the connection.
- `audience` on a `RemoteTool`/`AgenticIdentityToken` connection is a top-level ARM `properties` field, not nested under `credentials`.

## Security notes

- A blueprint's credential is shared by every instance created from it unless you override per-instance — don't put a production secret on a blueprint also used for dev/test instances. Use separate blueprints per environment instead (mirrors this repo's existing dev/stage/prod `environment` variable).
- Disabling the blueprint is the fastest containment step if an agent is compromised — faster than rotating a shared secret across every caller.
- Custom security attributes (e.g. `Environment`, `DataSensitivity`) on the blueprint let Conditional Access block, say, a non-prod agent from touching prod APIM products (doc 5) — set these up before you need them, not during an incident.

## Next

- Replace doc 3 §3.3's `mcp-client-agent` registration with §7.4 above; everything downstream (doc 4's runner, `mcp-auth-flow.xml`'s token validation) is unaffected.
- Doc 5's per-product token budgets and doc 6's A2A rate limits key off the *subscription/app role*, not the identity type — no changes needed there once the migration lands.
