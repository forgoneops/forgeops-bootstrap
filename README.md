# ForgeOps Bootstrap

Scripts to provision, verify, update, migrate, and tear down an Ubuntu 24.04 VPS. Docker-based stack: Caddy, Portainer, PostgreSQL, Redis, Uptime Kuma, Watchtower. Built against OVH VPS but nothing in it is OVH-specific.

Full spec: [`PROJECT_SPEC.md`](PROJECT_SPEC.md). Contributor notes: [`CLAUDE.md`](CLAUDE.md).

This infrastructure layer is complete and frozen. It's also the foundation for a broader self-hosted AI-platform backend (MCP gateway, context/memory/knowledge services) being built on top of it — see `PROJECT_SPEC.md`'s "Platform Vision" section, [`ARCHITECTURE.md`](ARCHITECTURE.md#platform-layers-vision--see-project_specmd-platform-vision) layer diagram, and [`docs/ROADMAP.md`](docs/ROADMAP.md) for what's next. Nothing in this section changes what's documented above.

## Quick start

```bash
git clone <this-repo> forgeops-bootstrap
cd forgeops-bootstrap
sudo ./install.sh
```

Takes 5-10 minutes on a fresh box. It's safe to re-run if something fails partway — fix whatever broke and run it again, finished steps get skipped.

Check it worked:

```bash
./verify.sh
```

Example output on a clean install:

```
ForgeOps Bootstrap — Health Report (2026-07-14T12:03:01Z)

  PASS   Operating System     Ubuntu 24.04.1 LTS
  PASS   Docker               Docker version 27.3.1
  PASS   Caddy                forgeops_caddy container running
  PASS   PostgreSQL           forgeops_postgres container running
  WARN   Claude CLI           claude CLI not found (optional)
  PASS   Secrets Integrity    .env present, mode 600, no empty required keys

24 passed, 1 warnings, 0 failed
```

## Commands

| Command | Does |
| --- | --- |
| `sudo ./install.sh` | Full provision. Idempotent, resumable. |
| `sudo ./update.sh` | Bumps everything to the versions pinned in `configs/versions.env`. |
| `./verify.sh` | Health check — console + `logs/verify-report.md` + `logs/verify-report.json`. |
| `sudo ./migrate.sh --host user@old-vps --sync` | Pull an existing VPS's data onto this one. See [`MIGRATION.md`](MIGRATION.md). |
| `sudo ./uninstall.sh` | Removes what install.sh set up. Add `--purge-data` to also wipe volumes/backups (asks first). |
| `./scripts/backup.sh` | Backs up Postgres + Redis + config now. Also runs daily on its own via systemd timer. |
| `./scripts/restore.sh --list` | Shows available backups. Drop `--list` to restore the latest one. |

## Configuration

Two files matter:

- `configs/versions.env` — every pinned version (Docker images, Node, uv). Bump something here, then run `./update.sh`.
- `.env` — secrets and per-install settings (`DOMAIN`, `PROJECTS_DIR`, `EXPOSE_PORTAINER`, ...). Generated automatically on first `install.sh` run from `.env.example`, with random secrets. Git-ignored — don't commit it.

By default nothing except Caddy is reachable from outside. To expose Portainer or Uptime Kuma publicly, set a `DOMAIN` and flip the matching `EXPOSE_*` flag in `.env`, then re-run `install.sh`.

## More docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — how the pieces fit together
- [`MIGRATION.md`](MIGRATION.md) — moving from an old VPS
- [`SECURITY.md`](SECURITY.md) — what's hardened, what isn't, how to report a vulnerability
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures
- [`AUDIT.md`](AUDIT.md) — self-audit findings and fixes
- [`CHANGELOG.md`](CHANGELOG.md)

## License

MIT — see [`LICENSE`](LICENSE).
