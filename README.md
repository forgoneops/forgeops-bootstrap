# ForgeOps Bootstrap

Production-grade infrastructure repository for provisioning, configuring, maintaining, migrating, verifying, and updating Ubuntu 24.04 LTS VPS servers (built and tested against OVH VPS) — a single, repeatable, idempotent workflow.

See [`PROJECT_SPEC.md`](PROJECT_SPEC.md) for the full specification and [`CLAUDE.md`](CLAUDE.md) for engineering conventions.

## What it installs

Docker + Docker Compose, Git, Python + uv, Node.js LTS, common ops tooling (jq, ripgrep, fzf, tmux, btop, htop, tree, ncdu, rsync), Fail2Ban, UFW, and a Docker-based service stack: Caddy (reverse proxy, automatic HTTPS), Portainer, PostgreSQL, Redis, Uptime Kuma, Watchtower.

## Quick start

```bash
git clone <this-repo> forgeops-bootstrap
cd forgeops-bootstrap
sudo ./install.sh
```

`install.sh` is idempotent and resumable — if it fails partway (network blip, apt lock, etc.), fix the underlying issue and re-run it; completed steps are skipped.

After install, check health any time:

```bash
./verify.sh
```

## The four entry points

| Command | What it does |
| --- | --- |
| `sudo ./install.sh` | Provisions and configures the complete server |
| `sudo ./update.sh` | Updates every component to the version pinned in `configs/versions.env` |
| `./verify.sh` | Validates every installed component, writes console/Markdown/JSON reports |
| `sudo ./migrate.sh --host user@old-vps --sync` | Migrates an existing VPS into this environment (see [`MIGRATION.md`](MIGRATION.md)) |
| `sudo ./uninstall.sh` | Removes installed components (add `--purge-data` to also delete stored data, with confirmation) |

## Configuration

- `configs/versions.env` — every pinned component version. Edit this file, then run `./update.sh`, to upgrade anything.
- `.env` (git-ignored, generated on first `install.sh` run from `.env.example`) — runtime secrets and per-install settings (`PROJECTS_DIR`, `DOMAIN`, `EXPOSE_PORTAINER`, `EXPOSE_UPTIME_KUMA`, etc.).

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — system design, service topology, data flow
- [`MIGRATION.md`](MIGRATION.md) — step-by-step VPS-to-VPS migration guide
- [`SECURITY.md`](SECURITY.md) — hardening details, secrets handling, reporting a vulnerability
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures and fixes, FAQ
- [`CLAUDE.md`](CLAUDE.md) — engineering conventions for anyone (human or AI) contributing to this repo
- [`CHANGELOG.md`](CHANGELOG.md) — release history

## License

MIT — see [`LICENSE`](LICENSE).
