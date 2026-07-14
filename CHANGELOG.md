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
