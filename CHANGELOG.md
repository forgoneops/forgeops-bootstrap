# Changelog

All notable changes to this repository are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

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
