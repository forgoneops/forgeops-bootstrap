# Migration Guide

`migrate.sh` moves an existing Linux VPS ("source") into a fresh ForgeOps Bootstrap install ("destination") over SSH, without ever stopping or deleting anything on the source except during the explicit `--finalize` cutover.

## Prerequisites

- Destination host has already run `sudo ./install.sh` successfully (`./verify.sh` passes).
- You can SSH from the destination to the source with key-based auth, non-interactively (`ssh -o BatchMode=yes user@source true` succeeds).
- The source host's ForgeOps repo path is known if you're syncing `--docker-config` (default assumed: `/opt/forgeops-bootstrap`; override by exporting `SOURCE_REPO_PATH` before running `migrate.sh`).

## Step 1 — Sync (repeatable, safe to run anytime)

```bash
sudo ./migrate.sh --host deploy@old-vps.example.com --sync --projects --claude-config --docker-config
```

- Copies data from the source to the destination while the source keeps running normally.
- Uses `rsync` with `--partial` so interrupted transfers resume on the next `--sync` run instead of starting over.
- Safe to run as many times as you like — each run only copies the delta.
- Nothing on the source is modified.

Add `--dry-run` to preview what would transfer without copying anything, and `--verbose` for per-file output.

### Target flags

| Flag | Copies |
| --- | --- |
| `--projects` | `PROJECTS_DIR` on the source (from its `.env`, default `/opt/forgeops/projects`) |
| `--claude-config` | `~/.claude` on the source |
| `--docker-config` | `docker/`, `configs/`, and `docker-compose.yml` from the source repo (compose file is saved as `docker-compose.yml.from-source` for manual review — never auto-applied over your destination's compose file) |
| `--ssh-config` | `~/.ssh` on the source (optional — only if you want the same keys on both hosts) |
| `--volumes` | Named Docker volumes (Postgres/Redis/Portainer/Uptime Kuma data) via a live tar snapshot |

If you pass none of these, `migrate.sh` defaults to `--projects --claude-config --docker-config`.

## Step 2 — Verify the sync looks right

Check the destination's `${PROJECTS_DIR}` and `~/.claude` match what you expect. Re-run `--sync` as many times as needed — it's non-destructive and idempotent-ish (converges toward the source each time).

## Step 3 — Finalize (one-time cutover)

```bash
sudo ./migrate.sh --host deploy@old-vps.example.com --finalize --volumes
```

`--finalize`:

1. Prompts for a typed `finalize` confirmation (this is the one destructive-adjacent step in the whole tool).
2. Stops only the migrated containers on the source (`docker compose stop postgres redis portainer uptime-kuma`) — nothing is deleted, and non-migrated services on the source are untouched.
3. Runs one last `--sync` delta pass to catch anything written between step 1 and now.
4. Verifies data integrity via a SHA-256 checksum manifest comparison (not just file size/count) between source and destination.
5. **Only if verification passes**, starts the destination's Postgres/Redis/Portainer/Uptime Kuma containers.
6. If verification fails, it aborts before starting anything on the destination and tells you to run `--rollback`.

The source host is never deleted from, force-shut-down, or decommissioned by this tool — after a successful `--finalize` its containers are simply stopped. Decommissioning the source is a manual step you take once you've confirmed the destination is healthy.

## Rollback

If something looks wrong after `--finalize` — or checksum verification failed — restart the source's stopped containers:

```bash
sudo ./migrate.sh --host deploy@old-vps.example.com --rollback
```

This reads the last migration's recorded host from `logs/.migrate-state` and runs `docker compose start postgres redis portainer uptime-kuma` on it. If you've also started the destination stack, stop it manually first to avoid two live copies of the same database.

## After a successful migration

1. Run `./verify.sh` on the destination — confirm a clean pass.
2. Point DNS at the destination (or update `DOMAIN` in the destination's `.env` and re-run `./install.sh` to regenerate the Caddyfile).
3. Once you're confident, decommission the source host manually (it was never touched destructively by this tool, so nothing here does that for you).
