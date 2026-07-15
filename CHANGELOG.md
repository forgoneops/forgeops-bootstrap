# Changelog

All notable changes to this repository are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- `PROJECT_SPEC.md` "Platform Vision" section, `ARCHITECTURE.md` "Platform layers" diagram, `docs/OSS_EVALUATION.md`, and `docs/ROADMAP.md`: documents the direction beyond the (complete, frozen) infrastructure layer — an eight-layer self-hosted AI-platform backend (MCP gateway, context, memory, knowledge, projects, observability) that any MCP-compatible client can plug into. Docs only in this change; no new services or code. Next PR scopes Layer 6 (MCP gateway + first MCP servers).
- **VPN-gated MCP engine** (branch `feature/vpn-mcp-engine`, see `SECURITY.md` "VPN-gated MCP engine" and `docs/{OBSERVABILITY,MEMORY,MCP_GATEWAY,VPN_SETUP}.md`): WireGuard (wg-easy) as the sole new host-facing port; observability (cAdvisor + Prometheus + Grafana, VPN-only); an MCP gateway (dedicated internal-only Caddy instance) enforcing a bearer token in front of the official filesystem/git reference MCP servers (wrapped stdio→SSE via `docker/mcp-stdio-bridge`) and a read-only `postgres-mcp` bridge against a dedicated least-privilege DB role. Every new service: `no-new-privileges`, `cap_drop: ALL` plus only the specific capability structurally required, `mem_limit`, healthchecked, no public `ports:` except WireGuard's own UDP port. New Fail2Ban jail `forgeops-mcp-auth` (401s against the gateway); `forgeops-wg-abuse` installed but disabled pending log-format verification. **Shared memory (Mem0) intentionally not included** — its self-hosted server has no maintained versioned image and its planned MCP wrapper is 14+ months stale; `step_install_mem0` logs this and retries rather than blocking the rest of the install. See `docs/MEMORY.md` for the open decision.

## [1.0.0] - Unreleased

### Added

- Initial release: `install.sh`, `verify.sh`, `update.sh`, `uninstall.sh`, `migrate.sh` entry points.
- Docker Compose service stack: Caddy, Portainer, PostgreSQL, Redis, Uptime Kuma, Watchtower, with `forgeops_edge`/`forgeops_internal` network isolation.
- `configs/versions.env` single-source-of-truth version pinning.
- `.env`-based secrets management with automatic generation and permission/emptiness verification in `verify.sh`.
- Two-phase (`--sync` / `--finalize` / `--rollback`) migration safety model in `migrate.sh`.
- State-file-backed resumable install (`logs/.install-state`).
- Full documentation set: `README.md`, `PROJECT_SPEC.md`, `ARCHITECTURE.md`, `MIGRATION.md`, `SECURITY.md`, `TROUBLESHOOTING.md`, `CLAUDE.md`.
- GitHub Actions CI: ShellCheck + Markdown lint on every PR.
- `scripts/backup.sh` / `scripts/restore.sh`: daily-scheduled (systemd timer), self-verifying PostgreSQL + Redis + config backup and restore, closing the Backup section of `PROJECT_SPEC.md` that v1.0.0 had left unimplemented.

### Fixed (full repository self-audit — see `AUDIT.md`)

- **ARCH-1 (CRITICAL):** every `.sh` file was committed non-executable (`core.fileMode=false` on the dev machine swallowed every `chmod +x`) — `sudo ./install.sh` failed with `Permission denied` on a fresh clone. Fixed via `git update-index --chmod=+x`.
- **IDEM-1 (HIGH):** `configure_ssh_security`'s deferred (no-key-yet) path was cached as "done," so the documented "add a key, re-run install.sh" fix silently no-op'd. Now returns exit 75, a new `run_step` convention meaning "succeeded but don't cache — retry next run."
- **IDEM-2/IDEM-3 (MEDIUM):** `configure_firewall` no longer does a blanket `ufw --force reset` (was wiping any manually-added rule on a forced re-run); `deploy_docker_stack` is now an "always" step (re-evaluated every `install.sh` run, not state-cached), so changing `EXPOSE_*`/`DOMAIN` and re-running `install.sh` actually redeploys, matching what `TROUBLESHOOTING.md` already claimed.
- **MIG-1/MIG-2/MIG-3 (HIGH):** `migrate.sh` read the source's `PROJECTS_DIR` from the wrong path (`$HOME/.env` instead of the source repo's own `.env`); `--finalize` never checksummed `--volumes` data at all despite it being mandatory (a `--finalize --volumes` run with no `--projects` printed "verified" having checked nothing); volume transfer failures (`scp`/`tar`) went undetected and were logged as success. All three fixed: correct remote path, per-volume checksum verification wired into the actual finalize gate, explicit exit-code checks on every transfer step.
- **DOCKER-1 (HIGH):** Uptime Kuma's healthcheck now uses its own documented `node extra/healthcheck.js` instead of an unverified `wget`-based check.
- **DOCKER-2 (MEDIUM):** Watchtower is now `restart: "no"` and profile-gated (`profiles: ["ondemand"]`) so a bare `docker compose up -d` can never start it into a `--run-once`-then-restart crash-loop.
- **SEC-1 (MEDIUM):** Caddy's admin API now binds `localhost:2019` (Caddy's own default), not `0.0.0.0:2019` — no longer reachable from sibling containers on `forgeops_internal`.
- **SEC-2 (MEDIUM):** Postgres/Redis now get scoped `environment:` blocks instead of wholesale `env_file: .env`, so neither container holds a secret it doesn't need.
- **SEC-3 (MEDIUM):** `restore.sh`'s Postgres restore is now atomic (restores into a shadow database, only swaps it into place after `pg_restore` succeeds) instead of drop-then-recreate-then-restore with an empty-database window if interrupted.
- **SEC-4 (MEDIUM):** added a second Fail2Ban jail (`forgeops-caddy-auth`) watching Caddy's new file-based JSON access log for repeated 401/403 against exposed Portainer/Uptime Kuma — previously only SSH was protected.
- **SEC-5/SEC-6 (MEDIUM/LOW):** `backup.sh`/`restore.sh` now use `REDISCLI_AUTH`/`PGPASSWORD` env vars instead of `-a`/implicit trust auth, keeping credentials out of process argv and making the auth path explicit.
- **DOCKER-3/DOCKER-4 (MEDIUM):** every service now has a capped `json-file` log driver (`max-size: 10m`, `max-file: 3`) and a `mem_limit`, closing an unbounded-disk-growth and unbounded-memory gap.
- **SC-1 (LOW):** `update.sh`'s Watchtower invocation no longer overrides the compose-declared `command:` (was silently dropping `--no-startup-message`).
- **Documentation:** `SECURITY.md`, `ARCHITECTURE.md`, and `MIGRATION.md` updated to disclose backups are local-only and contain plaintext secrets, the Alpine/Postgres collation caveat, and the brief source-side service gap during a migration cutover (DOC-1 through DOC-4).

### Fixed (round-2 self-audit — see `AUDIT.md`)

- **ARCH-1 (HIGH):** `run_step`/`run_step_always` invoked step functions as `"$@" || rc=$?`, which per bash's documented `set -e` exemption rules silently disables errexit for the entire step-function call tree — an unguarded intermediate command inside a multi-command step (worst case: `deploy_docker_stack`, where a failed `render_caddyfile.sh` call wouldn't stop `docker compose up -d` from running and reporting the whole step successful) could fail without aborting the step. First fix attempt (`( set -e; "$@" ) || rc=$?`) was verified-by-reproduction to NOT actually work — the same exemption cascades into a subshell placed on the left of `||` too. Correct fix, also verified by reproduction: `set +e` around a bare (non-`||`) `( set -e; "$@" )` subshell call.
- **DOCKER-1 (MEDIUM):** the bare-IP `:80` Caddy fallback block now has a `log` directive too, so `logs/caddy/access.log` — and the `forgeops-caddy-auth` Fail2Ban jail that watches it — exists from the very first `install.sh` run regardless of whether `DOMAIN` is ever configured.
- **SEC-1 (MEDIUM):** `backup.sh`'s Postgres-dump verification now runs `pg_restore --list` via `docker exec` against the already-running `forgeops_postgres` container instead of a hardcoded `postgres:16-alpine` throwaway image, eliminating the one place a Postgres version wasn't read from `configs/versions.env`.
- **DOCKER-2 (LOW):** `uninstall.sh`'s `docker compose down --remove-orphans` now passes `--profile ondemand` so a leftover Watchtower container from an interrupted run gets cleaned up too.
- **DOC-1 (LOW):** `SECURITY.md`'s Fail2Ban bullet now states access logging (and the jail's log file) is active from install regardless of `DOMAIN`, matching the DOCKER-1 fix.

### Cleaned up

- Added `.editorconfig`.
- Rewrote `README.md` — it claimed "four entry points" in a table with seven rows, cut the marketing language, added a real `./verify.sh` output example.
- Dropped the audit-ticket references that had leaked into inline code comments across `docker-compose.yml`, `templates/Caddyfile.template`, and every script — fine in this changelog, out of place in the code itself.
- Tightened log and error messages throughout the scripts. No behavior changed; re-verified with `bash -n` and the full smoke suite, plus a standalone repro of the `run_step` fix to make sure trimming its comment didn't touch the actual logic.
