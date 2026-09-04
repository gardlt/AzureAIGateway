# mcp-server

Minimal Go MCP server — streamable HTTP transport, JSON-RPC 2.0, two tools
(`echo`, `time`). No auth of its own; sits behind APIM's `validate-azure-ad-token`
policy per [../terraform/mcp-server.tf](../terraform/mcp-server.tf) and
[../02-mcp-remote-server.md](../02-mcp-remote-server.md).

## Local run

```bash
go run .
curl -s http://127.0.0.1:3000/healthz
curl -s -X POST http://127.0.0.1:3000/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Build + push (cloud-side, no local Docker daemon needed)

```bash
ACR=$(terraform -chdir=../terraform output -raw acr_login_server)
az acr build --registry "${ACR%%.*}" --image mcp-server:latest .
```

Then `terraform apply` in `../terraform` — the container app's `mcp_container_image`
already points at `${acr_login_server}/mcp-server:latest`.

## Add a tool

Append to the `tools` slice and a `case` in `tools/call` in `main.go`.
