# Shared Memory (Mem0)

**Status: not deployed.** This document describes the intended design and the specific decision blocking it — read this before assuming Mem0 is running.

## Intended design

Mem0, self-hosted on the *existing* Postgres instance via the `pgvector` extension — no new database, no Neo4j, no Qdrant (see `PROJECT_SPEC.md`'s "Reuse the existing Postgres + Redis" constraint). Single `MEM0_USER_ID` namespace: one maintainer, many devices/clients sharing one memory space, not per-device isolation. Embeddings via FastEmbed (local, no cloud API key — see `.env.example`'s `MEM0_EMBEDDER_PROVIDER`), consistent with `PROJECT_SPEC.md`'s "No cloud dependency" platform principle.

`mem0` (the server) and `mem0-mcp` (its MCP wrapper, exposed at `/mem0/*` on the MCP gateway) both have real, working service definitions in `docker-compose.yml` already — hardened, networked, healthchecked. They are just not started by `step_deploy_docker_stack` yet.

## Open decision: source pinning

Mem0's self-hosted server ships no maintained, versioned Docker image upstream — `mem0ai/mem0`'s own `docker-compose.yaml` builds the server from its own Dockerfile rather than pulling a published tag, and the only published image (`mem0/mem0-api-server`) has no version tags beyond an arm64-only `:latest` last pushed roughly 10 months ago.

The MCP wrapper originally scoped for this (`coleam00/mcp-mem0`) has had **no commits in 14+ months** and only ever published a Dockerfile, not a registry image either.

Building either from source means cloning and running code from a specific external repository that hasn't been explicitly named and approved by the operator for this purpose — that's a different, larger decision than approving "build from source" as a general approach, and it needs its own explicit go-ahead. `step_install_mem0` (in `scripts/lib/install_steps.sh`) reflects this: it logs a clear warning and returns exit 75 (retry-next-run) rather than either silently skipping the feature or blocking every other part of the install.

### Options for resolving this

1. **Proceed with the named repos, pinned to a specific commit** (not `main`) — trades "audited" for "reproducible." Update `MEM0_GIT_REF`/`MEM0_MCP_GIT_REF` in `configs/versions.env` to an actual commit SHA once chosen, then implement `step_install_mem0`'s git-clone logic (currently absent, not stubbed).
2. **Pick a different, actively-maintained Memory-layer project.** `docs/OSS_EVALUATION.md` already flags Letta (`letta-ai/letta`) as a strong alternative — official versioned Docker image, active releases, also Postgres+pgvector backed. Would mean revisiting this doc and the `mem0`/`mem0-mcp` compose service names.
3. **Accept the risk explicitly** — pin `mem0/mem0-api-server:latest` (confirm your VPS is arm64 first) and self-build `coleam00/mcp-mem0` from its Dockerfile, both documented in `SECURITY.md` as accepted staleness/maintenance risk.

Whichever is chosen, update this document, `configs/versions.env`, `SECURITY.md`'s "Known gaps" section, and add `mem0 mem0-mcp` back to `step_deploy_docker_stack`'s service list in `scripts/lib/install_steps.sh`.
