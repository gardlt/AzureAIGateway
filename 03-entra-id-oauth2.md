# 3. Microsoft Entra ID app registrations & OAuth2 flow

> Part 3 of 3, but do this **before finishing part 2** — [02-mcp-remote-server.md](02-mcp-remote-server.md) needs the IDs/scope/role created here to secure the MCP server and validate calls in APIM. See [README.md](README.md) for the full read order.

## Two connection patterns, one server app

This guide wires up **two separate OAuth2 patterns against the same MCP server**, because there are two kinds of caller:

| Pattern | Caller | Flow | Trigger |
|---|---|---|---|
| **Interactive** | A person, through Claude or VS Code | OAuth 2.1 authorization code + PKCE, delegated | If the client has no valid token, it opens a browser and redirects to Entra ID sign-in automatically — this is the MCP spec's built-in behavior, not something you build |
| **Service-to-service** | An agent/automated caller acting on its own identity | OAuth 2.0 client credentials | No browser, no user — the caller acquires a token headlessly at request time |

Both patterns validate against the **same server app registration** (the MCP server, as an OAuth2 *protected resource*). What differs is the **scope claim** in the resulting token: interactive tokens carry a delegated `scp` claim (from a scope you expose), service-to-service tokens carry a `roles` claim (from an app role you define). APIM (in doc 2) validates the audience the same way for both, and can optionally branch on `scp` vs `roles` to gate which tools a caller may invoke.

You'll register **three** Entra ID apps in total:

| App | Type | Used by |
|---|---|---|
| `mcp-server` | Server app (resource) | Represents the MCP server itself; issues no tokens, just defines the scope/role |
| `mcp-client-interactive` | Public client (no secret) | Claude / VS Code — drives the browser login flow |
| `mcp-client-agent` | Confidential client (has a secret) | Automated/service callers using client credentials |

## Prerequisites

- Azure CLI, signed in (`az login`), same tenant as your APIM instance and container app.
- Permissions to create app registrations (Application Developer role, minimum).
- The canonical URL your MCP server will be reachable at through APIM, e.g. `https://<apim-name>.azure-api.net/mcp-server` (from [02-mcp-remote-server.md](02-mcp-remote-server.md) §2.4) — decide this URL now, since it must match exactly, character for character, everywhere below.

```bash
MCP_URL="https://<apim-name>.azure-api.net/mcp-server"
TENANT_ID=$(az account show --query tenantId -o tsv)
```

## 3.1 Register the server app (the MCP server as a resource)

```bash
APP_ID=$(az ad app create \
  --display-name "mcp-server" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

az ad sp create --id $APP_ID
OBJECT_ID=$(az ad app show --id $APP_ID --query id -o tsv)
```

### Set v2 access tokens (required — do this before the next step)

```bash
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body '{"api": {"requestedAccessTokenVersion": 2}}'
```

Entra ID matches an MCP client's `resource` parameter against the app's **Application ID URI**, and that matching only works with v2 tokens. Skipping this step is the most common cause of `AADSTS9010010` errors later.

### Set the Application ID URI to your MCP server's canonical URL

```bash
az ad app update --id $APP_ID --identifier-uris "$MCP_URL"
```

The value must be identical — scheme, host casing, path, no trailing slash — to what MCP clients send as `resource` and to the `resource` field you'll publish in the PRM document (doc 2 §2.5).

### Expose a delegated scope (for the interactive pattern)

```bash
SCOPE_ID=$(uuidgen)

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"api\": {
        \"oauth2PermissionScopes\": [{
            \"id\": \"$SCOPE_ID\",
            \"adminConsentDescription\": \"Invoke MCP tools on behalf of the signed-in user\",
            \"adminConsentDisplayName\": \"Invoke MCP tools\",
            \"isEnabled\": true,
            \"type\": \"User\",
            \"userConsentDescription\": \"Invoke MCP tools on your behalf\",
            \"userConsentDisplayName\": \"Invoke MCP tools\",
            \"value\": \"mcp.tools.invoke\"
        }]
    }
  }"
```

Interactive clients request the fully qualified scope `$MCP_URL/mcp.tools.invoke`.

### Define an app role (for the service-to-service pattern)

```bash
ROLE_ID=$(uuidgen)

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"appRoles\": [{
        \"id\": \"$ROLE_ID\",
        \"displayName\": \"Tools.Invoke.All\",
        \"description\": \"Invoke MCP tools as an autonomous agent\",
        \"value\": \"Tools.Invoke.All\",
        \"allowedMemberTypes\": [\"Application\"],
        \"isEnabled\": true
    }]
  }"
```

Service-to-service clients request `scope=$MCP_URL/.default` under the client credentials grant; if the calling app has been assigned this role, the resulting token carries `"roles": ["Tools.Invoke.All"]`.

## 3.2 Register the interactive client app (Claude / VS Code)

This is a **public client** — no secret, PKCE only. MCP clients need a pre-registered Entra app to redirect users through, since Entra ID doesn't support OAuth dynamic client registration.

Portal steps (App registrations > New registration):

1. **Name**: `mcp-client-interactive`.
2. **Supported account types**: Accounts in this organizational directory only (or multitenant if your users span tenants).
3. **Redirect URI**: select **Public client/native (mobile & desktop)** and add the loopback/custom-scheme redirect URI your specific MCP client uses for its OAuth callback. This differs by client and client version:
   - VS Code (GitHub Copilot agent mode / `MCP: Add Server`) — check the redirect URI shown when you add an HTTP MCP server and it initiates auth; VS Code typically uses a `vscode://` or `http://127.0.0.1:<port>/` loopback callback.
   - Claude (Desktop or claude.ai remote MCP connectors) — check Claude's MCP OAuth documentation for the exact callback URI its current version expects.

   Add every redirect URI you need to support as separate entries; you can register more than one client app if the clients need materially different configuration.
4. Select **Register**. Copy the **Application (client) ID** — this is `$INTERACTIVE_CLIENT_ID`.
5. **Authentication** > under **Advanced settings**, set **Allow public client flows** to **Yes**, then **Save**.
6. **API permissions** > **Add a permission** > **My APIs** > select `mcp-server` > **Delegated permissions** > select `mcp.tools.invoke` > **Add permissions**.
7. Select **Grant admin consent for \<tenant\>** > **Yes** (skips the per-user consent prompt; omit this if you want users to consent individually on first login instead).

```bash
INTERACTIVE_CLIENT_ID=$(az ad app create \
  --display-name "mcp-client-interactive" \
  --sign-in-audience AzureADMyOrg \
  --public-client-redirect-uris "http://127.0.0.1:33418/" \
  --query appId -o tsv)

az ad sp create --id $INTERACTIVE_CLIENT_ID
```

(Redo the redirect URI with the value your MCP client actually uses; the permission grant in steps 6–7 above is easiest done in the portal since it requires picking the scope by name.)

You will **not** put this client ID into APIM config or the MCP server — it's consumed entirely on the client side (Claude/VS Code configuration), which discovers it via the PRM/authorization-server metadata flow documented in doc 2 §2.5–2.6.

## 3.3 Register the agent (service-to-service) client app

A **confidential client** — has a secret, used by automated callers with no user present.

```bash
AGENT_CLIENT_ID=$(az ad app create \
  --display-name "mcp-client-agent" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

az ad sp create --id $AGENT_CLIENT_ID

AGENT_CLIENT_SECRET=$(az ad app credential reset --id $AGENT_CLIENT_ID --query password -o tsv)
```

Grant it the app role from §3.1 (application permission, not delegated — requires admin consent, portal step):

1. App registration `mcp-client-agent` > **API permissions** > **Add a permission** > **My APIs** > select `mcp-server` > **Application permissions** > select `Tools.Invoke.All` > **Add permissions**.
2. **Grant admin consent for \<tenant\>** > **Yes**.

## 3.4 Token acquisition reference

### Interactive (handled automatically by the MCP client — shown here only to explain what happens under the hood)

1. Claude/VS Code calls the MCP server URL through APIM with no token.
2. APIM returns `401` with `WWW-Authenticate: Bearer resource_metadata="<MCP_URL>/.well-known/oauth-protected-resource"`.
3. The client fetches that PRM document, finds `authorization_servers: ["https://login.microsoftonline.com/$TENANT_ID/v2.0"]`, and discovers Entra's `/authorize` and `/token` endpoints via OpenID Connect metadata.
4. The client opens a browser to Entra ID's `/authorize` endpoint with PKCE, `client_id=$INTERACTIVE_CLIENT_ID`, `resource=$MCP_URL` (or the equivalent `scope=$MCP_URL/mcp.tools.invoke`), and its registered redirect URI. **This is the login prompt you see pop up.**
5. On success, the client exchanges the code for a token at Entra's `/token` endpoint and retries the MCP call with `Authorization: Bearer <token>`.

No config on your side makes step 4 happen — it's the MCP client following the spec once PRM (doc 2 §2.5) and the app registrations here exist. Full walkthrough and connection setup for both clients is in [02-mcp-remote-server.md](02-mcp-remote-server.md) §2.7.

### Service-to-service (client credentials)

```bash
curl -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AGENT_CLIENT_ID" \
  -d "client_secret=$AGENT_CLIENT_SECRET" \
  -d "scope=$MCP_URL/.default" \
  -d "grant_type=client_credentials"
```

The response's `access_token` carries `"roles": ["Tools.Invoke.All"]` and is presented as `Authorization: Bearer <token>` on every call — used directly by an agent process, or attached by APIM itself if APIM is the caller (see doc 2 §2.6 "outbound" option).

### Dev-only token retrieval for manual testing

```bash
az account get-access-token --resource $MCP_URL --query accessToken -o tsv
```

## Security notes

- Client secrets on `mcp-client-agent` expire — rotate before expiry, or prefer a **federated identity credential** / **managed identity** over a long-lived secret for production agent callers (see doc 2 §2.6 for the managed-identity outbound option).
- Admin consent (§3.2 step 7, §3.3 step 2) is required once per tenant; propagation can take a few minutes.
- Keep the delegated scope and the app role distinct in purpose: don't grant the interactive client app-role permissions, and don't grant the agent client the delegated scope — each pattern should only be able to acquire the token type it needs.
- If `AADSTS9010010` appears: check for a trailing-slash or casing mismatch between the Application ID URI (§3.1) and the `resource`/`MCP_URL` value used everywhere else — it must match character for character.

## Next

Go to [02-mcp-remote-server.md](02-mcp-remote-server.md) §2.4 onward to publish the PRM document, configure APIM's `validate-azure-ad-token` policy against `$APP_ID`, and connect both Claude/VS Code (interactive) and an agent caller (service-to-service) end to end.
