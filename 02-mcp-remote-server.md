# 2. Deploy the MCP remote server & wire it through APIM

> Part 2 of 3. Requires the Entra ID apps from [03-entra-id-oauth2.md](03-entra-id-oauth2.md) (`$APP_ID`, `$MCP_URL`, `$TENANT_ID`, `$AGENT_CLIENT_ID`/`$AGENT_CLIENT_SECRET`) and the APIM instance from [01-api-management-ai-gateway.md](01-api-management-ai-gateway.md) (`$APIM_NAME`, `$RESOURCE_GROUP`). See [README.md](README.md) for the full read order.

This doc wires up two ways to call the MCP server through APIM: an **interactive** path where an unauthenticated Claude/VS Code session is redirected to Entra ID sign-in automatically, and a **service-to-service** path for automated agent callers using client credentials. Both are validated the same way at the APIM edge — see doc 3 for why.

## Prerequisites

- Azure CLI v2.62.0+ (`az --version`).
- A container image for your MCP server implementing streamable HTTP transport at `/mcp` (any MCP SDK — TypeScript, Python, etc.). This guide assumes you already have an image in a registry; building the image itself is out of scope.
- The APIM instance from doc 1, in the same subscription.
- The Entra ID server app from doc 3.

## 2.1 Deploy the standalone container app

```bash
CONTAINERAPPS_ENV="cae-mcp"
CONTAINER_APP_NAME="mcp-server"
IMAGE="<your-registry>/<your-mcp-server-image>:latest"

az provider register --namespace Microsoft.App --wait

az containerapp env create \
  --name $CONTAINERAPPS_ENV \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

az containerapp create \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENV \
  --image $IMAGE \
  --target-port 3000 \
  --ingress external \
  --transport auto \
  --min-replicas 1
```

- `--ingress external` exposes the app publicly (APIM and MCP clients need to reach it).
- `--transport auto` is correct for MCP streamable HTTP — it runs over standard HTTP, no special MCP transport value needed.
- Expose your MCP endpoint at `/mcp` and a separate health check at `/healthz` — MCP endpoints expect JSON-RPC POST and will error on a plain GET health probe.

Get the app's URL:

```bash
MCP_URL=$(az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query properties.configuration.ingress.fqdn -o tsv)

echo "https://$MCP_URL/mcp"
```

## 2.2 Configure CORS

Needed if any MCP client connects from a browser-based environment (VS Code for the Web, vscode.dev). Not required for the VS Code desktop app.

```bash
az containerapp ingress cors update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --allowed-origins "https://vscode.dev" "https://github.dev" \
  --allowed-methods "GET" "POST" "OPTIONS" \
  --allowed-headers "Content-Type" "Authorization" "Mcp-Session-Id" \
  --max-age 3600
```

Restrict `--allowed-origins` to your actual trusted origins in production.

## 2.3 Restrict the container app to APIM

Token validation happens once, at the APIM edge (§2.6), against the server app from doc 3. The container app itself doesn't need its own Entra ID auth layer or secret — instead, lock its network so it's only reachable from your APIM instance, so the MCP endpoint can't be called by bypassing APIM.

```bash
az containerapp ingress access-restriction set \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --rule-name "allow-apim" \
  --ip-address "$(az apim show --name $APIM_NAME --resource-group $RESOURCE_GROUP --query publicIpAddresses[0] -o tsv)/32" \
  --action Allow
```

For stronger isolation, put both APIM and the container app in the same virtual network and use `--ip-address` rules scoped to the VNet, or Container Apps' [VNet integration](https://learn.microsoft.com/azure/container-apps/vnet-custom) instead of a public-IP allowlist. **Requires Standard v2 or Premium v2** — Basic v2 (doc 1's default) can't connect to VNet-isolated backends, so stick with the public-IP allowlist above unless you've upgraded the APIM tier.

If you want defense-in-depth token validation at the container app too (not just at APIM), add JWT validation middleware in your MCP server code against the same `$APP_ID` audience and `$TENANT_ID` issuer — using your platform's standard Entra ID token-validation library, not hand-rolled checks.

## 2.4 Expose the MCP server through APIM

Portal steps, on the APIM instance from doc 1:

1. Open your APIM instance.
2. Left menu, under **APIs**, select **MCP servers** > **+ Create MCP server**.
3. Select **Expose an existing MCP server**.
4. **Backend MCP server**:
   - **MCP server base URL**: bare container app origin only, e.g. `https://<container-app-fqdn>` — **do not** include `/mcp` here. The MCP server operation you create in this step already appends `/mcp` as its `url_template`; including it in the base URL too doubles it into `.../mcp/mcp` on the backend request and the Go/SDK server 404s.
   - **Transport type**: Streamable HTTP (default).
5. **New MCP server**:
   - **Name**: e.g. `mcp-server`.
   - **Base path**: route prefix, e.g. `mcp-server`.
   - **Description**: optional.
6. **Products**: optionally associate a product to manage subscriptions/access.
7. Select **Create**.

The portal lists the new MCP server under **MCP Servers**, with a **Server URL** you'll use for testing and client config — of the form:

```
https://<apim-service-name>.azure-api.net/<base-path>/mcp
```

This URL must be exactly `$MCP_URL` from doc 3 — it's the Application ID URI and PRM `resource` value everything else matches against. If you set up doc 3 before this step, confirm they're identical now; if not, go back and set `$MCP_URL` to match what you just created here.

You can select which backend operations are exposed as callable tools under the MCP server's **Tools** blade.

> **Caution:** Don't reference `context.Response.Body` in MCP server policies — it forces response buffering and breaks the streaming behavior MCP requires.

## 2.5 Publish protected resource metadata (PRM) — this is what triggers the login prompt

This is the piece that makes an unauthenticated Claude/VS Code session redirect to Entra ID sign-in automatically, per the MCP authorization spec (RFC 9728). Add an operation to the MCP server's API (or the wrapping API, depending on how the portal modeled it) that serves the PRM document **anonymously** at `/.well-known/oauth-protected-resource`:

1. In the MCP server's parent API, add a new operation: `GET /.well-known/oauth-protected-resource`.
2. Set its policy to bypass auth (no `validate-azure-ad-token`, see §2.6) and return the document directly:

```xml
<inbound>
    <base />
    <return-response>
        <set-status code="200" reason="OK" />
        <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
        </set-header>
        <set-body>{
  "resource": "{{mcp-url}}",
  "authorization_servers": ["https://login.microsoftonline.com/{{tenant-id}}/v2.0"],
  "scopes_supported": ["mcp.tools.invoke"],
  "bearer_methods_supported": ["header"]
}</set-body>
    </return-response>
</inbound>
```

Create the `mcp-url` and `tenant-id` **Named Values** (APIM instance > **Named values**) set to `$MCP_URL` and `$TENANT_ID` from doc 3.

3. On the MCP operations themselves, add a `401` challenge for requests with no token (see the `validate-azure-ad-token` policy in §2.6 — its `on-error` response should set `WWW-Authenticate`):

```xml
<on-error>
    <choose>
        <when condition="@(context.Response.StatusCode == 401)">
            <set-header name="WWW-Authenticate" exists-action="override">
                <value>@("Bearer resource_metadata=\"" + (string)context.Variables["mcp-url"] + "/.well-known/oauth-protected-resource\"")</value>
            </set-header>
        </when>
    </choose>
</on-error>
```

## 2.6 Validate tokens at the APIM edge

Both the interactive and service-to-service patterns end up presenting a bearer token with the same audience (`$APP_ID` / `$MCP_URL`) — validate both the same way with the [`validate-azure-ad-token`](https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy) policy on the MCP server's inbound policy (not on the PRM operation from §2.5, which must stay anonymous):

```xml
<inbound>
    <base />
    <validate-azure-ad-token tenant-id="{{tenant-id}}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Access token is missing or invalid.">
        <client-application-ids>
            <application-id>{{interactive-client-id}}</application-id>
            <application-id>{{agent-client-id}}</application-id>
        </client-application-ids>
        <audiences>
            <audience>{{resource-app-id}}</audience>
        </audiences>
    </validate-azure-ad-token>
</inbound>
```

> **Audience gotcha, confirmed by live testing:** Entra v2 access tokens always set `aud` to the **resource app's `client_id` (GUID)** — never the Application ID URI from `identifier_uris` (`$MCP_URL`) — regardless of whether the token was requested with `scope=$MCP_URL/.default` or `scope=$APP_ID/.default`. Add a `resource-app-id` Named Value set to `$APP_ID` (the GUID from doc 3 §3.1) and check the audience against that, not `{{mcp-url}}`. Using `{{mcp-url}}` here means every token validation fails with `401` regardless of a valid token.

Add `interactive-client-id`, `agent-client-id`, and `resource-app-id` Named Values set to `$INTERACTIVE_CLIENT_ID`, `$AGENT_CLIENT_ID`, and `$APP_ID` from doc 3. Optionally branch on the token's claims to restrict tools by caller type — a delegated (interactive) token has an `scp` claim containing `mcp.tools.invoke`; a service-to-service token has a `roles` claim containing `Tools.Invoke.All`:

```xml
<choose>
    <when condition="@(context.Request.Headers.GetValueOrDefault("Authorization","").Contains("roles"))">
        <!-- optional: gate agent-only tools here -->
    </when>
</choose>
```

(That header check is illustrative only — for real claim inspection, parse the JWT with `context.Request.Headers.GetValueOrDefault("Authorization")` piped through `Jwt.Parse` or use `validate-jwt`'s claim extraction instead of string matching.)

### Forward the token to the container app (if your MCP server also validates it)

Authorization headers are forwarded to the backend by default. If you added defense-in-depth validation in the container app (§2.3), no extra policy is needed. If you stripped or overrode the header anywhere upstream, restore it explicitly:

```xml
<set-header name="Authorization" exists-action="override">
    <value>@(context.Request.Headers.GetValueOrDefault("Authorization"))</value>
</set-header>
```

## 2.7 Connect and validate — both patterns

### Interactive: VS Code

1. Command Palette > **MCP: Add Server**.
2. Server type: **HTTP (HTTP or Server-Sent Events)**.
3. **Server URL**: `https://<apim-service-name>.azure-api.net/<base-path>/mcp` (= `$MCP_URL`).
4. Choose **Workspace settings** (writes `.vscode/mcp.json`) or **User settings**. No auth header needed in the config — VS Code follows the `401` → PRM → Entra ID redirect from §2.5 and prompts you to sign in the first time you use the server.

```json
{
    "servers": {
        "mcp-server": {
            "type": "http",
            "url": "https://<apim-service-name>.azure-api.net/<base-path>/mcp",
            "oauth": {
                "clientId": "<INTERACTIVE_CLIENT_ID>"
            }
        }
    }
}
```

> **Confirmed in practice:** Entra ID doesn't support RFC 7591 dynamic client registration, so VS Code cannot auto-register itself. On first use it shows *"The authorization server ... does not support automatic client registration. Do you want to proceed by manually providing a client registration (client ID)?"* and lists the redirect URIs it needs registered (typically `http://127.0.0.1:33418/` and `https://vscode.dev/redirect`). Pre-empt the prompt by setting `oauth.clientId` to `$INTERACTIVE_CLIENT_ID` in `mcp.json` as shown above, and make sure both redirect URIs are registered on the `mcp-client-interactive` app (doc 3 §3.2).

In GitHub Copilot Chat, switch to **Agent** mode, open **Tools**, select tools from your server, and prompt the agent to invoke one — on first use, a browser window opens to Entra ID sign-in. Subsequent calls reuse the cached token silently.

### Interactive: Claude

Add the MCP server as a remote connector (Claude Desktop settings, or claude.ai's remote MCP connector UI) pointing at `$MCP_URL`. On first use, Claude follows the same `401` → PRM → Entra ID redirect and opens a browser for sign-in. Consult Claude's own MCP connector documentation for the exact redirect URI it expects — register that URI on the `mcp-client-interactive` app from doc 3 §3.2 if it differs from what you already added.

### Service-to-service: agent caller

Any automated caller acquires its own token per doc 3 §3.4 and calls the MCP server directly — no APIM-side config beyond what's already in §2.6:

```bash
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AGENT_CLIENT_ID" \
  -d "client_secret=$AGENT_CLIENT_SECRET" \
  -d "scope=$MCP_URL/.default" \
  -d "grant_type=client_credentials" | jq -r .access_token)

curl -s -X POST "$MCP_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### MCP Inspector (either token type)

```bash
npx @modelcontextprotocol/inspector
```

Open the printed local URL, set transport to Streamable HTTP, set the URL to `$MCP_URL`, and either let Inspector drive the OAuth redirect or paste in a token acquired via doc 3 §3.4. Pin MCP Inspector to **v0.9.0** — later/earlier versions have known compatibility issues with APIM-managed MCP servers.

## 2.8 Entra ID / RFC 8414 metadata gap — VS Code workaround

Entra ID does **not** serve [RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414) authorization-server metadata (`.well-known/oauth-authorization-server` 404s); it only serves the OIDC-flavored `.well-known/openid-configuration`. VS Code's MCP OAuth client, observed live, fails AS metadata discovery against the PRM's `authorization_servers` entry because of this gap and falls back to guessing conventional `/authorize` and `/token` paths **directly on the MCP resource's own origin** (your APIM gateway), which has no such routes — the browser lands on `{"statusCode": 404, "message": "Resource not found"}`.

Fix by adding a small anonymous "OAuth facade" API mounted at the APIM service root (`path = ""`) that intercepts those guessed paths and proxies them to the real Entra endpoints:

- `GET /.well-known/oauth-authorization-server` → returns Entra's real `issuer`/`authorization_endpoint`/`token_endpoint` as JSON (satisfies clients that do find this URL but expect RFC 8414 shape).
- `GET /authorize` → `302` redirect to `https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize`, forwarding the original query string.
- `POST /token` → reverse-proxy to `https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token`, forwarding the POST body.

> **Second gotcha, confirmed by live testing:** VS Code's manual-client-registration flow (the prompt in §2.7) omits the `scope` parameter entirely from both the `/authorize` request and the `/token` POST body. Entra's v2.0 token endpoint rejects a scope-less request with `AADSTS900144: The request body must contain the following parameter: 'scope'`. The facade's `/authorize` and `/token` operations should inject a default scope (`$APP_ID/.default offline_access openid profile`) whenever the incoming request doesn't already include one — do this with a `<set-header>`/`<set-body>` policy expression rather than assuming the client will supply it.

This facade is optional — only needed if your MCP client falls back to resource-origin `/authorize`/`/token` guessing the way VS Code does. Claude and other clients that complete proper PRM + OIDC discovery don't need it.

## Troubleshooting

| Problem | Cause | Solution |
|---|---|---|
| No login prompt appears; client just fails | PRM document missing, malformed, or not anonymous | Re-check §2.5 — the PRM operation must return `200` with no auth challenge, and `resource` must exactly match `$MCP_URL` |
| `AADSTS9010010` during interactive or client-credentials token request | `resource`/`scope` doesn't exactly match the Application ID URI | Re-check doc 3 §3.1 — casing, trailing slash, and path must match `$MCP_URL` character for character |
| `401 Unauthorized` from APIM even with a valid-looking token | Audience or client-application-id mismatch in `validate-azure-ad-token` | Confirm `{{mcp-url}}` and the `client-application-ids` Named Values in §2.6 match the actual token's `aud` and `appid`/`azp` claims |
| Interactive sign-in works but agent client-credentials calls get `401` | Agent client wasn't granted the app role, or admin consent wasn't completed | Redo doc 3 §3.3 steps 1–2; check the token's `roles` claim contains `Tools.Invoke.All` |
| MCP server streaming fails when diagnostic logs are enabled | Response body logging/access interferes with MCP transport | Set **Number of payload bytes to log** to 0 for Frontend Response at the All-APIs scope, or configure logging per-API instead |
| Valid-looking token still gets `401` from `validate-azure-ad-token` | `<audience>` checked against `$MCP_URL` instead of the token's real `aud` claim | Entra always sets `aud` to the resource app's `client_id` GUID, never the Application ID URI — check against `$APP_ID`, see §2.6 |
| MCP call with a valid token returns `404` from the server itself (not APIM's 404 body) | Backend `service_url` already ends in `/mcp` and the operation's `url_template` is also `/mcp`, doubling the path | Strip `/mcp` from the backend base URL — see §2.4 |
| VS Code hits `<apim-url>/authorize` directly and gets `{"statusCode":404,"message":"Resource not found"}` | Entra doesn't serve RFC 8414 metadata; VS Code falls back to guessing `/authorize`/`/token` on the MCP resource's own origin | Deploy the OAuth facade in §2.8 |
| Browser sign-in reaches Entra but fails with `AADSTS900144: The request body must contain the following parameter: 'scope'` | VS Code's manual-client-registration flow omits `scope` from the `/authorize` and `/token` requests | Inject a default scope in the facade from §2.8, or in the client's own `mcp.json` if the client supports specifying one |

## Next

You now have a governed AI Gateway (doc 1), an MCP server deployed and exposed through APIM with both interactive and service-to-service OAuth2 wired up (this doc), and the Entra ID app registrations backing both (doc 3). Revisit doc 1 §1.5 to confirm gateway metrics/logs are picking up MCP tool call traffic from both connection patterns.
