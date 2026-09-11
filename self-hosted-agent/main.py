"""Self-hosted A2A agent (doc 8 + doc 9 §9.2).

Exposes an Agent Framework agent over the A2A protocol on Azure Container
Apps. Identity is the ACA user-assigned managed identity, federated (no
secret) to the `self-hosted-a2a-agent` Entra application — terraform/modules
/agent/main.tf provisions both. Inbound calls (from a Foundry agent using
the outbound-A2A auth described in doc 9 §9.4) are validated here: JWT
signature via the tenant's JWKS, audience == this app's identifier URI, and
caller client_id (`azp`/`appid`) in the ALLOWED_CALLER_CLIENT_IDS allowlist
— the same allowlist-not-RBAC posture doc 7/8 use for the MCP server, since
we don't control object IDs for Foundry-side service principals.

No APIM in front yet (see doc 9 §9.5 for adding it later) — this process
does its own auth.
"""

import logging
import os

import jwt
import uvicorn
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill
from agent_framework import Agent
from agent_framework.a2a import A2AExecutor
from agent_framework.azure import AzureOpenAIChatClient
from azure.identity import ChainedTokenCredential, ManagedIdentityCredential, AzureCliCredential
from jwt import PyJWKClient
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("self-hosted-a2a-agent")

TENANT_ID = os.environ["AZURE_TENANT_ID"]
AGENT_APP_ID_URI = os.environ["AGENT_APP_ID_URI"]
ALLOWED_CALLER_CLIENT_IDS = {
    c.strip() for c in os.environ.get("ALLOWED_CALLER_CLIENT_IDS", "").split(",") if c.strip()
}
UAMI_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID")
PORT = int(os.environ.get("PORT", "8080"))

_jwks_client = PyJWKClient(
    f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"
)
_ISSUER = f"https://login.microsoftonline.com/{TENANT_ID}/v2.0"


class EntraBearerAuthMiddleware(BaseHTTPMiddleware):
    """Validates inbound bearer tokens before letting a request reach the
    A2A routes. Rejects anything not issued for this agent's own audience
    by an allowlisted caller — mirrors what APIM's validate-azure-ad-token
    + client-application-ids allowlist does for the MCP server (doc 3), just
    done here in-process since this endpoint isn't behind APIM yet."""

    # Agent-card fetches are commonly anonymous (doc 9 §9.4) — don't require
    # a token for them.
    EXEMPT_SUFFIXES = ("/.well-known/agent-card.json",)

    async def dispatch(self, request: Request, call_next):
        if request.url.path.endswith(self.EXEMPT_SUFFIXES):
            return await call_next(request)

        auth = request.headers.get("authorization", "")
        if not auth.lower().startswith("bearer "):
            return JSONResponse({"error": "missing bearer token"}, status_code=401)
        token = auth.split(" ", 1)[1]

        try:
            signing_key = _jwks_client.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                audience=AGENT_APP_ID_URI,
                issuer=_ISSUER,
            )
        except jwt.PyJWTError as exc:
            log.warning("token rejected: %s", exc)
            return JSONResponse({"error": "invalid token"}, status_code=401)

        caller = claims.get("azp") or claims.get("appid")
        if ALLOWED_CALLER_CLIENT_IDS and caller not in ALLOWED_CALLER_CLIENT_IDS:
            log.warning("caller %s not in allowlist", caller)
            return JSONResponse({"error": "caller not authorized"}, status_code=403)

        request.state.caller_client_id = caller
        return await call_next(request)


def build_chat_client() -> AzureOpenAIChatClient:
    endpoint = os.environ["AZURE_OPENAI_ENDPOINT"]
    deployment = os.environ["AZURE_OPENAI_DEPLOYMENT_NAME"]

    credential = ChainedTokenCredential(
        ManagedIdentityCredential(client_id=UAMI_CLIENT_ID),
        AzureCliCredential(),  # local `az login` dev fallback
    )
    return AzureOpenAIChatClient(
        endpoint=endpoint,
        deployment_name=deployment,
        credential=credential,
    )


def build_app() -> Starlette:
    agent = Agent(
        client=build_chat_client(),
        name="Self-Hosted Agent",
        instructions="You are a helpful self-hosted agent, reachable over A2A from a Microsoft Foundry agent.",
    )

    agent_card = AgentCard(
        name="Self-Hosted Agent",
        description="Self-hosted (Azure Container Apps) Agent Framework agent, callable via A2A.",
        version="1.0.0",
        default_input_modes=["text"],
        default_output_modes=["text"],
        capabilities=AgentCapabilities(streaming=True),
        supported_interfaces=[
            AgentInterface(url="/", protocol_binding="JSONRPC"),
        ],
        skills=[
            AgentSkill(
                id="general",
                name="General assistance",
                description="Answers general questions.",
                tags=["general"],
                examples=[],
            )
        ],
    )

    request_handler = DefaultRequestHandler(
        agent_executor=A2AExecutor(agent, stream=True),
        task_store=InMemoryTaskStore(),
        agent_card=agent_card,
    )

    return Starlette(
        routes=[
            *create_agent_card_routes(agent_card),
            *create_jsonrpc_routes(request_handler, "/"),
        ],
        middleware=[Middleware(EntraBearerAuthMiddleware)],
    )


app = build_app()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
