# Troubleshooting & FAQ

## `install.sh` failed partway through

Read the error — `install.sh` names the exact step that failed. Fix the underlying issue (network, apt lock, disk space) and re-run `sudo ./install.sh`; completed steps are skipped via `logs/.install-state`. To force every step to re-run from scratch: `sudo ./install.sh --reset-state`.

## `./verify.sh` reports a FAIL

Check `logs/verify-report.md` for the detail column on the failing row. Common causes:

- **Docker/Docker Compose FAIL** — `docker info` isn't reachable; confirm the Docker daemon is running (`systemctl status docker`) and that `install.sh` completed the `install_docker` step.
- **Caddy/Portainer/Redis/PostgreSQL FAIL** — the container isn't running. `docker compose ps` to see its state, `docker compose logs <service>` for why it exited.
- **Secrets Integrity FAIL** — `.env` is missing, has the wrong permissions (should be 600), or has an empty required key. Re-run `install.sh` if `.env` is missing entirely; fix permissions with `chmod 600 .env`; fill in any empty key manually if it's a user-supplied one (like `DOMAIN`).
- **Firewall/Fail2Ban FAIL** — the service isn't active. `sudo systemctl status ufw fail2ban`; re-run the relevant `install.sh` step by name if needed (delete just that line from `logs/.install-state` and re-run `install.sh`).

## `./update.sh` aborted

`update.sh` aborts before touching the next stage on any failure, by design — read the error, it tells you exactly what state things are in (e.g. "Ubuntu packages updated, Docker images not yet pulled" vs. "images pulled, recreate failed — previous containers untouched"). A pre-update image-tag snapshot is written to `logs/pre-update-images-<timestamp>.txt` for manual rollback (`docker compose up -d` with the prior tags) if a recreate leaves things in a bad state.

## `migrate.sh --finalize` failed checksum verification

The script already stopped the source's migrated containers and did **not** start the destination. Nothing is running for those services right now on purpose — that's safer than running two divergent copies. Run `sudo ./migrate.sh --host <source> --rollback` to bring the source back up while you investigate the mismatch (usually: something wrote to the source between the last `--sync` and `--finalize`'s stop — re-run `--sync` once more, then retry `--finalize`).

## I can't SSH in anymore after `install.sh`

This should not happen: `install.sh` only sets `PasswordAuthentication no` if it verified an `authorized_keys` file exists first. If you're locked out anyway, use your VPS provider's console/rescue access, check `/etc/ssh/sshd_config.d/60-forgeops-hardening.conf`, and either add a key or temporarily comment out `PasswordAuthentication no` and `systemctl reload ssh`.

## A service needs to be exposed publicly (e.g. Portainer)

Set `EXPOSE_PORTAINER=true` (or `EXPOSE_UPTIME_KUMA=true`) and a `DOMAIN` in `.env`, then re-run `sudo ./install.sh` (or `sudo ./update.sh`) to regenerate `docker/Caddyfile` and reload Caddy with the new site block.

## How do I bump a component's version?

Edit `configs/versions.env`, then run `sudo ./update.sh`. Nothing auto-updates to an unpinned "latest" — see `PROJECT_SPEC.md`'s Versioning & Pinning Policy.

## How do I completely remove ForgeOps Bootstrap, including data?

```bash
sudo ./uninstall.sh --purge-data
```

You'll be shown exactly what will be deleted and asked to type a confirmation phrase. Use `--dry-run` first if you want to see the list without the prompt.
