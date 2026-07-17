# Roadmap — Next Real PR (Layer 6: Integrations / MCP Gateway)

This is the concrete scope for the first non-documentation PR in the platform build-out (see `PROJECT_SPEC.md`'s "Platform Vision" and `ARCHITECTURE.md`'s "Platform layers" for the surrounding context). It is deliberately narrow: one layer, fully working, no placeholders — not a scaffold of all eight layers.

## Why Layer 6 first

Every other layer (Context, Memory, Knowledge, Projects) is reached *through* the gateway by AI clients. Building Memory or Context before there's a gateway means nothing outside the container network can use it yet. Layer 6 is the only layer whose absence blocks everything else from being useful.

## Gateway choice

**Primary candidate: `IBM/mcp-context-forge`** — registry + protocol translation + guardrails + OpenTelemetry + Kubernetes-scalable, ships an admin UI, PyPI + Docker deploy.

**Lighter alternative: `docker/mcp-gateway`** — Docker's own MCP Toolkit CLI plugin, container-isolated MCP servers, simpler config, tighter Docker Desktop integration.

Both are real, actively maintained, and self-hostable with no cloud dependency (see `docs/OSS_EVALUATION.md`). Decision between them is deferred to the PR itself — it should start with a short spike (stand up each locally, compare admin/config overhead) rather than being decided from research alone, since the deciding factor is likely to be operational fit once it's actually running against this repo's `forgeops_internal` network.

## First MCP servers to wire in behind the gateway

Start with servers that have an obvious, immediate use against infrastructure this repo already runs — don't add a server that has nothing to talk to yet:

1. **Filesystem MCP server** — scoped to the repo's `projects/` directory (see `install.sh`'s `create_project_directories` step for the existing directory convention).
2. **Git MCP server** — scoped to repos under that same `projects/` directory.
3. **PostgreSQL MCP server** — pointed at the existing `postgres` service on `forgeops_internal`, using a dedicated least-privilege DB role, not the superuser credential `.env` already provisions for the stack itself.

Anthropic's `modelcontextprotocol/servers` reference implementations are explicitly not production-ready per their own docs — treat them as examples to read, not containers to deploy as-is; the PR should either fork/harden one or pick a maintained third-party equivalent.

## Docker Compose shape

New services join the existing `docker-compose.yml` on `forgeops_internal` (never public by default — same pattern as Postgres/Redis today), each with its image version pinned in `configs/versions.env`. The gateway gets its own `EXPOSE_MCP_GATEWAY`-style opt-in flag and Caddyfile site block only if/when it needs to be reachable from outside the Docker network (e.g. a remote AI client, not one running on the same host) — mirroring exactly how `EXPOSE_PORTAINER`/`EXPOSE_UPTIME_KUMA` work today. No new pattern needs to be invented; this is `templates/Caddyfile.template` + `scripts/render_caddyfile.sh`'s existing mechanism.

## Stack for any glue code

Node.js/TypeScript, per the MCP SDK's first-class support and to match the bulk of the existing OSS MCP ecosystem. `install.sh` already provisions Node.js LTS on the host; no new host-level dependency is required.

## Verification plan for that PR

- `docker compose up -d` brings up the gateway + the 3 servers alongside the existing stack with no manual steps.
- `verify.sh` gains new checks: gateway health endpoint reachable, each MCP server registered with the gateway, filesystem/git servers scoped correctly (cannot read outside `projects/`), Postgres server using its dedicated least-privilege role (not the stack superuser).
- A real MCP client (Claude Code is the obvious first one, since it's already in use in this repo's own workflow) successfully lists and calls at least one tool from each of the 3 servers through the gateway, end to end.
- `bats` smoke tests added under `tests/` for the new `verify.sh` checks, following the existing `tests/entrypoints.bats` pattern.

## Explicitly out of scope for this PR

Layers 2-5, 7, 8. Do not add Context/Memory/Knowledge/Observability services in the same PR — those are separate PRs once Layer 6 is live and something can actually reach them.
