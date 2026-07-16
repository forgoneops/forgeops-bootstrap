# MCP Gateway

The single, VPN-gated entrypoint every AI client (Claude Code, Cursor, ChatGPT, Gemini, etc.) uses to reach this backend's tools. See `SECURITY.md`'s "VPN-gated MCP engine" for the full threat model — this doc is the operational how-it-works.

## Shape

`mcp-gateway` is a dedicated Caddy instance (`configs/mcp-gateway/Caddyfile`), internal-only, reverse-proxying by path to each backend MCP server:

| Path | Backend | Server |
| --- | --- | --- |
| `/filesystem/*` | `mcp-filesystem:8000` | Official `@modelcontextprotocol/server-filesystem`, scoped to `PROJECTS_DIR` |
| `/git/*` | `mcp-git:8000` | Official `@modelcontextprotocol/server-git`, scoped to `PROJECTS_DIR` |
| `/postgres/*` | `mcp-postgres:8000` | `crystaldba/postgres-mcp`, `--access-mode=restricted --transport=sse`, dedicated read-only DB role |
| `/mem0/*` | `mem0-mcp:8050` | Not deployed yet — see `docs/MEMORY.md` |

`mcp-filesystem` and `mcp-git` are built from a shared Dockerfile (`docker/mcp-stdio-bridge/Dockerfile`) that wraps each stdio-only reference server behind `sparfenyuk/mcp-proxy`'s stdio→SSE bridge — the official reference servers don't speak HTTP/SSE natively.

## Authentication

Every request needs `Authorization: Bearer <MCP_BEARER_TOKEN>` or gets a 401 (see `SECURITY.md` layer 2). The one exception is `/healthz`, and only when the request's source IP is the gateway container's own loopback (`127.0.0.1`) -- that's what the Docker healthcheck itself uses (see `docker-compose.yml`'s `mcp-gateway` healthcheck and `configs/mcp-gateway/Caddyfile`'s `@healthz_internal` matcher). A request to `/healthz` from anywhere else -- another container on `forgeops_internal`, a VPN peer, outside -- is NOT exempt: it still 401s without a valid bearer token, and even with one it 404s (no route is registered for that path). No path is otherwise exempt.

## Connecting a client

1. Connect to the WireGuard VPN (`docs/VPN_SETUP.md`).
2. Point your MCP-compatible client at `http://<forgeops_mcp_gateway's internal address>:8443/<server>/sse` — e.g. `.../filesystem/sse`.
3. Configure the client to send `Authorization: Bearer <MCP_BEARER_TOKEN>` (value from this VPS's `.env`) on every request.

The exact reachable address depends on how your MCP client resolves hosts once connected to the VPN — since `mcp-gateway` has no host port, it's reached via WireGuard's routing into `forgeops_internal`, not a public hostname. Document your specific client's config here once confirmed working end-to-end (`docs/ROADMAP.md`'s verification plan calls for a real Claude Code connection test before this PR's follow-up work is considered complete).

## Token rotation

```bash
# Edit MCP_BEARER_TOKEN in .env (or regenerate: openssl rand -hex 32), then:
docker compose up -d mcp-gateway mem0-mcp
```

No other service needs restarting — nothing else reads this value directly.

## Adding a new MCP server

1. Add its service to `docker-compose.yml` (internal-only, hardened, healthchecked — copy an existing MCP service block as a starting point).
2. Add a `handle_path` block to `configs/mcp-gateway/Caddyfile` routing to it.
3. Add it to `step_deploy_docker_stack`'s service list in `scripts/lib/install_steps.sh`.
4. If it needs Postgres access, create a dedicated least-privilege role in a new or existing `step_install_*` function — never reuse the stack superuser or another service's role.
