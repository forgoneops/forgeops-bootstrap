# ForgeOps Bootstrap — Repository Self-Audit

**Date:** 2026-07-14
**Scope:** every file in the repository, against `PROJECT_SPEC.md` and general production-infrastructure practice.
**Status:** audit only — **no code has been modified**. Findings are ordered by severity within each category.

## Severity legend

| Severity | Meaning |
| --- | --- |
| CRITICAL | Breaks the golden path for every user, or causes silent data loss |
| HIGH | Breaks a documented workflow, or a safety guarantee the docs explicitly promise |
| MEDIUM | Real gap against production-grade/least-privilege expectations; not immediately fatal |
| LOW | Correctness nit, cosmetic drift, or a caveat that should be disclosed but isn't dangerous |

## Summary

| ID | Severity | One-line summary |
| --- | --- | --- |
| [ARCH-1](#arch-1) | CRITICAL | Shell scripts are committed as mode 644 (non-executable) — `sudo ./install.sh` fails on a fresh clone |
| [IDEM-1](#idem-1) | HIGH | SSH-hardening step is marked "done" even on the deferred/no-key path, so the documented "add a key, re-run install.sh" fix silently no-ops |
| [MIG-1](#mig-1) | HIGH | `migrate.sh` reads the wrong path for the source's `PROJECTS_DIR`, silently falling back to a hardcoded default |
| [MIG-2](#mig-2) | HIGH | `--finalize` only checksums `--projects`; the mandatory `--volumes` data (the actual database) is never verified |
| [MIG-3](#mig-3) | HIGH | Volume transfer failures during `--sync`/`--finalize` are not detected — a failed copy still logs success |
| [DOCKER-1](#docker-1) | HIGH | Portainer/Uptime Kuma healthchecks assume `wget` is present in their images; unverified, and Uptime Kuma's own docs use a different mechanism |
| [DOCKER-2](#docker-2) | MEDIUM | Watchtower's `restart: unless-stopped` + one-shot command will crash-loop if ever started via a bare `docker compose up -d` |
| [SEC-1](#sec-1) | MEDIUM | Caddy admin API bound to `0.0.0.0:2019` instead of `localhost:2019` — reachable from every sibling container |
| [SEC-2](#sec-2) | MEDIUM | `env_file: .env` on Postgres/Redis wholesale-injects every secret into both containers, violating least privilege |
| [DOCKER-3](#docker-3) | MEDIUM | No container log size limits — unbounded `docker logs` growth can fill the disk |
| [DOCKER-4](#docker-4) | MEDIUM | No CPU/memory limits on any service — one runaway container can OOM the host |
| [IDEM-2](#idem-2) | MEDIUM | `ufw --force reset` wipes any manually-added firewall rules every time the firewall step is forced to re-run |
| [IDEM-3](#idem-3) | MEDIUM | Re-running `install.sh` after changing `EXPOSE_*`/`DOMAIN` doesn't redeploy — the docs' suggested fix doesn't work |
| [SEC-3](#sec-3) | MEDIUM | `restore.sh`'s Postgres restore (drop → create → restore) is non-atomic with no recovery if interrupted mid-sequence |
| [SEC-4](#sec-4) | MEDIUM | Fail2Ban only covers SSH; exposed Portainer/Uptime Kuma admin UIs have no brute-force protection |
| [DOC-1](#doc-1) | MEDIUM | Backups are local-only (same disk as the data) with no offsite replication — undisclosed limitation |
| [DOC-2](#doc-2) | MEDIUM | Backup archives contain `.env` secrets in plaintext (uncompressed-readable) — undisclosed in SECURITY.md |
| [SEC-5](#sec-5) | MEDIUM | `redis-cli -a` exposes the Redis password via process listing (`docker top`/`ps`) in `backup.sh` |
| [SC-1](#sc-1) | LOW | `docker compose run` in `update.sh` overrides Watchtower's declared command, dropping `--no-startup-message` |
| [PORT-1](#port-1) | LOW | `sed -i` calls use GNU-only syntax; silently breaks on macOS/BSD if a contributor tests off-Ubuntu |
| [SEC-6](#sec-6) | LOW | Backup/restore Postgres commands implicitly rely on the image's default local-socket trust auth, not an explicit credential |
| [DOC-3](#doc-3) | LOW | Postgres/Redis Alpine (musl) images have known collation caveats, undocumented anywhere in this repo |
| [ARCH-2](#arch-2) | LOW | `docker-compose.yml`'s Watchtower `command:`/`restart:` fields don't reflect how it's actually invoked, misleading a reader of the compose file alone |
| [DOC-4](#doc-4) | LOW | `MIGRATION.md` doesn't warn about the brief source-side outage window between `--finalize` and the operator's manual DNS cutover |

---

## Architecture problems

### ARCH-1
**Severity:** CRITICAL
**File(s):** every `*.sh` file (verified via `git ls-files -s`)
**Explanation:** Every shell script in the repository is stored in git's index as mode `100644` (non-executable), not `100755`. Root cause: `core.fileMode` is `false` in this local git config (the Windows-default behavior), so the `chmod +x` calls made during development were never captured by `git add`/`git commit`. This means anyone who clones the repository fresh onto Ubuntu and follows the README's own quick-start (`sudo ./install.sh`) gets `Permission denied` on the very first command — the golden path is broken for every user, and CI's ShellCheck job doesn't catch it either (ShellCheck doesn't check file permissions).
**Proposed fix:** Run `git update-index --chmod=+x <file>` for every `*.sh` file (or `chmod +x` locally with `core.fileMode` temporarily set to `true` for the commit), commit the mode change, and add a CI check (`find . -name '*.sh' ! -perm -u+x -print -exec false {} +` or equivalent) that fails the build if any tracked shell script loses its executable bit again.

### ARCH-2
**Severity:** LOW
**File(s):** `docker-compose.yml`
**Explanation:** The `watchtower` service declares `command: ["--cleanup", "--no-startup-message", "--run-once"]` and `restart: unless-stopped`, but per `ARCHITECTURE.md`, Watchtower is never included in the `docker compose up -d` service list in `step_deploy_docker_stack` — it's only ever invoked ad hoc via `docker compose run --rm watchtower ...` from `update.sh`, which overrides the declared `command:` anyway (see SC-1). A reader of `docker-compose.yml` in isolation (without having read `ARCHITECTURE.md`) would reasonably conclude Watchtower runs as a persistent polling daemon, which is never true in this design.
**Proposed fix:** Add an inline comment directly above the `watchtower:` service block stating it is on-demand-only, invoked exclusively by `update.sh`, and never started via `up -d`. See DOCKER-2 for the related runtime risk this ambiguity creates.

---

## Security issues

### SEC-1
**Severity:** MEDIUM
**File(s):** `templates/Caddyfile.template`
**Explanation:** The template sets `admin 0.0.0.0:2019`, binding Caddy's admin API (which can rewrite Caddy's entire routing configuration at runtime) to all interfaces inside the container. Since port 2019 isn't published to the host in `docker-compose.yml`, it isn't reachable from the internet — but it *is* reachable from every other container on `forgeops_internal` (Postgres, Redis, Portainer, Uptime Kuma, and anything added later). Caddy's own default (if the `admin` directive were omitted entirely) is `localhost:2019`, which the in-container healthcheck (`wget --spider -q http://localhost:2019/config/`) would satisfy just as well, since the healthcheck runs inside the same container's network namespace. The `0.0.0.0` override appears to be an unforced security regression.
**Proposed fix:** Remove the `admin 0.0.0.0:2019` line (or change it to `admin localhost:2019`) so the admin API is reachable only from within the Caddy container itself.

### SEC-2
**Severity:** MEDIUM
**File(s):** `docker-compose.yml` (postgres, redis services)
**Explanation:** Both `postgres` and `redis` declare `env_file: .env`, which loads *every* key in `.env` into each container's environment — including secrets the service doesn't need (e.g., the Postgres container receives `REDIS_PASSWORD`, and vice versa). `PROJECT_SPEC.md` and `SECURITY.md` both commit to "principle of least privilege," which this violates. For Postgres, `env_file` is redundant on top of the explicit `environment: POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB` mapping already present. For Redis, `env_file` is load-bearing (the `command:` needs `$$REDIS_PASSWORD` in the container's shell environment) but still over-broad.
**Proposed fix:** Remove `env_file: .env` from `postgres` (the explicit `environment:` block already covers what it needs — Compose auto-loads `.env` for `${VAR}` substitution in the file itself, no `env_file:` directive required for that). For `redis`, replace `env_file: .env` with a scoped `environment: - REDIS_PASSWORD=${REDIS_PASSWORD}`.

### SEC-3
**Severity:** MEDIUM
**File(s):** `scripts/restore.sh`
**Explanation:** The Postgres restore path runs `dropdb --if-exists` → `createdb` → `pg_restore` as three separate, non-atomic steps. If the process is interrupted between the drop and a successful restore (SIGKILL, VM reboot, OOM), the database is left empty with no automatic recovery — the script's own `die()` message on `pg_restore` failure acknowledges "there is no automatic rollback for this step," but the gap actually starts one command earlier, at `dropdb`.
**Proposed fix:** Restore into a temporary shadow database name (e.g., `${POSTGRES_DB}_restoring`), verify the restore succeeded, then swap names (rename current DB to `_old`, rename shadow to the real name) only after `pg_restore` reports success — eliminating the empty-database window entirely.

### SEC-4
**Severity:** MEDIUM
**File(s):** `scripts/lib/install_steps.sh` (`step_configure_fail2ban`), `SECURITY.md`
**Explanation:** The only Fail2Ban jail configured is `[sshd]`. Once an operator sets `EXPOSE_PORTAINER=true` or `EXPOSE_UPTIME_KUMA=true`, those admin UIs become internet-reachable through Caddy with no brute-force/credential-stuffing protection beyond whatever rate-limiting the applications implement themselves (Uptime Kuma and Portainer are not known for aggressive built-in lockout policies). Caddy's own logs, by default, go to stdout/`docker logs` rather than a file Fail2Ban could parse, so wiring up protection isn't a one-line jail addition.
**Proposed fix:** At minimum, document this gap in `SECURITY.md`'s "Known non-goals." For a real fix: configure Caddy to write access logs to a file (`log { output file /var/log/caddy/access.log }`), mount that path into a location the host's Fail2Ban can read, and add a jail with a filter matching repeated 401/403 responses to `/api/*` (Portainer) or the Uptime Kuma login path.

### SEC-5
**Severity:** MEDIUM
**File(s):** `scripts/backup.sh` (lines invoking `redis-cli -a`)
**Explanation:** `redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning ...` passes the password as a command-line argument, which is visible to any local user who can run `ps aux`/`docker top` while the command is executing (the `--no-auth-warning` flag exists specifically to suppress redis-cli's own built-in warning about this exact exposure — its presence here is a signal the risk was known but not mitigated).
**Proposed fix:** Use the `REDISCLI_AUTH` environment variable instead (supported since Redis 5): `docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD}" forgeops_redis redis-cli --no-auth-warning LASTSAVE`, which keeps the secret out of argv.

### SEC-6
**Severity:** LOW
**File(s):** `scripts/backup.sh`, `scripts/restore.sh`
**Explanation:** `pg_dump`/`pg_restore`/`dropdb`/`createdb` are invoked with `-U "${POSTGRES_USER}"` and no explicit password mechanism, relying implicitly on the official Postgres image's default `pg_hba.conf` (`local` Unix-socket connections are `trust`-authenticated regardless of `POSTGRES_HOST_AUTH_METHOD`, which only governs `host`/TCP connections). This works today but is an undocumented, implicit dependency on upstream image defaults — if a future change to the image, or an operator override of `pg_hba.conf`, changes local-socket auth, backup/restore break with a password-prompt hang rather than a clear error.
**Proposed fix:** Set `PGPASSWORD="${POSTGRES_PASSWORD}"` explicitly in the environment for these `docker exec` calls, making the auth path explicit rather than relying on trust-by-default.

---

## Idempotency issues

### IDEM-1
**Severity:** HIGH
**File(s):** `scripts/lib/install_steps.sh` (`step_configure_ssh_security`), `scripts/lib/common.sh` (`run_step`), `TROUBLESHOOTING.md`
**Explanation:** `run_step` marks a step "done" in `logs/.install-state` whenever the step function returns success — but `step_configure_ssh_security` returns success in **both** branches: the "key found, hardened" branch and the "no key found, deferred" branch. `TROUBLESHOOTING.md` explicitly documents: *"Add an SSH key, then re-run install.sh to harden SSH"* — but because `configure_ssh_security=done` is already written to the state file after the first (deferred) run, `run_step` will skip the function entirely on every subsequent `install.sh` invocation. The documented recovery path silently does nothing.
**Proposed fix:** Only call `state_mark_done` for this step when the full-hardening branch executes; leave the step un-marked (so it retries every run) when deferred due to no key being present. Alternatively, make the step idempotently self-checking (inspect the current `sshd_config.d` file's content rather than trusting the coarse state cache) regardless of the state file.

### IDEM-2
**Severity:** MEDIUM
**File(s):** `scripts/lib/install_steps.sh` (`step_configure_firewall`)
**Explanation:** The step begins with `ufw --force reset`, unconditionally wiping every existing UFW rule before re-adding ForgeOps' own rules. `TROUBLESHOOTING.md` suggests, for any stuck step, "delete just that line from `logs/.install-state` and re-run `install.sh`" — for this specific step, that advice means any firewall rule the operator added by hand for an unrelated purpose (e.g., allowing a custom app port) is silently destroyed on the next forced re-run, with no warning specific to this step.
**Proposed fix:** Either check for the presence of ForgeOps' specific rules and only add missing ones (no blanket reset), or add an explicit warning in `TROUBLESHOOTING.md` next to the "delete a line and re-run" advice calling out that `configure_firewall` is destructive to unrelated rules.

### IDEM-3
**Severity:** MEDIUM
**File(s):** `install.sh` (`deploy_docker_stack` step), `TROUBLESHOOTING.md`
**Explanation:** `TROUBLESHOOTING.md`'s "A service needs to be exposed publicly" section says to set `EXPOSE_PORTAINER=true`/`DOMAIN` in `.env`, then "re-run `sudo ./install.sh` (or `sudo ./update.sh`)" to regenerate the Caddyfile and reload Caddy. Because `deploy_docker_stack` (the step that calls `render_caddyfile.sh` and `docker compose up -d`) is state-cached and already marked done after the first successful install, re-running `install.sh` alone is a no-op for this purpose — only `update.sh` (which is not state-gated) actually re-renders the Caddyfile and recreates containers.
**Proposed fix:** Either remove `install.sh` from that troubleshooting suggestion (since only `update.sh` works), or make `deploy_docker_stack` self-checking against the current `.env`/rendered Caddyfile content so a genuine config change causes it to re-run even when state-cached.

---

## ShellCheck issues

No `shellcheck` binary was available in this environment to run the actual linter (see `tests/run.sh`'s own fallback message); the following are manually-identified issues a ShellCheck pass would very likely flag, plus the one behavioral issue found by inspection:

### SC-1
**Severity:** LOW
**File(s):** `update.sh`
**Explanation:** `docker compose run --rm watchtower --cleanup --run-once` passes `--cleanup --run-once` as CLI arguments to `docker compose run`, which **replaces** the service's declared `command:` entirely rather than appending to it — so the `--no-startup-message` flag declared in `docker-compose.yml` is silently dropped whenever Watchtower runs via `update.sh`, causing an extra startup banner line in the update log. Purely cosmetic, but a real drift between declared and actual behavior.
**Proposed fix:** Either pass all three flags explicitly in `update.sh` (`--cleanup --no-startup-message --run-once`) or rely solely on the compose file's `command:` by invoking `docker compose run --rm watchtower` with no extra arguments.

(Structural note: since `shellcheck` could not be run here, `tests/run.sh`/CI's ShellCheck job should be treated as **not yet verified green** — running it for real on a Linux box with `shellcheck` installed is a prerequisite before trusting this repo's scripts are actually SC-clean, independent of the one issue found manually above.)

---

## Portability issues

### PORT-1
**Severity:** LOW
**File(s):** `scripts/lib/common.sh` (`ensure_env_file`)
**Explanation:** `sed -i "s|...|...|" "${ENV_FILE}"` uses GNU sed's single-argument `-i` syntax. BSD/macOS sed requires `sed -i '' ...` (a mandatory empty-string argument for the backup-suffix parameter). Since the target platform is exclusively Ubuntu 24.04 (GNU sed), this isn't a production issue — but it would silently break (or silently create a file named after the sed script, a classic macOS sed gotcha) if a contributor tries to exercise `install.sh`'s `.env`-generation logic locally on a Mac, which `CLAUDE.md`'s testing guidance doesn't rule out.
**Proposed fix:** No change needed for the Ubuntu-only production target; if local macOS testing is ever a goal, branch on `$OSTYPE` or use a portable Perl one-liner instead.

---

## Docker issues

### DOCKER-1
**Severity:** HIGH
**File(s):** `docker-compose.yml` (portainer, uptime-kuma healthchecks)
**Explanation:** Both healthchecks use `wget --spider -q http://localhost:<port>/...`. This assumes `wget` is present inside `portainer/portainer-ce:2.21-alpine` and `louislam/uptime-kuma:1.23.16`. Portainer's Alpine-based image is intentionally minimal and has not been confirmed here to include `wget`. More concretely, **Uptime Kuma's own official Docker documentation ships a dedicated healthcheck script** (`node extra/healthcheck.js`, invoked as `HEALTHCHECK CMD node extra/healthcheck.js`) rather than a wget-based check — a strong signal that a wget-based check is not the officially supported/reliable pattern for that image. If `wget` is absent in either image, the healthcheck command itself fails (exit 127), and Docker will report the container as perpetually `unhealthy` even when the service is functioning correctly — directly undermining `verify.sh`'s "Health Endpoints" check, which is one of the spec's explicitly required verification rows.
**Proposed fix:** For Uptime Kuma, switch to the image's own documented healthcheck: `test: ["CMD", "node", "extra/healthcheck.js"]`. For Portainer, verify `wget` presence on the real image (`docker run --rm portainer/portainer-ce:2.21-alpine which wget`) before relying on it in production; if absent, fall back to a TCP-connect check or Portainer's documented healthcheck pattern.

### DOCKER-2
**Severity:** MEDIUM
**File(s):** `docker-compose.yml` (watchtower service)
**Explanation:** Watchtower is declared with `command: [..., "--run-once"]` (a one-shot command that exits immediately after completing) combined with `restart: unless-stopped`. As designed, this container is never started via `up -d` (see ARCH-2), so the combination is currently latent rather than actively triggered. But if an operator ever runs a bare `docker compose up -d` (the single most natural Compose command, and one nothing in this repo prevents), Watchtower **will** start, run once, exit, and then be restarted by the `unless-stopped` policy — forever, in a tight crash-loop, generating continuous log churn and container-restart events that would pollute `docker ps`/monitoring output.
**Proposed fix:** Set `restart: "no"` on the watchtower service (since it's only ever invoked via `docker compose run`, which ignores `restart:` policy anyway for one-off runs, but explicitly documents the intent), and/or add `profiles: ["ondemand"]` so Compose excludes it from any bare `up` invocation entirely — the cleanest fix, since profile-gated services require an explicit `--profile` flag to start.

### DOCKER-3
**Severity:** MEDIUM
**File(s):** `docker-compose.yml` (all services)
**Explanation:** No service declares a `logging:` block, so all containers use Docker's default `json-file` log driver with no size cap. `install.sh`'s `configure_log_rotation` step only sets up logrotate for `${REPO_ROOT}/logs/*.log` (ForgeOps' own script logs) — it does not touch `docker logs` output, which lives under `/var/lib/docker/containers/*/*.json-log` and grows unbounded. On a long-lived VPS, particularly under any meaningful Caddy/Postgres traffic, this is a classic disk-fill failure mode that a "production-grade" repository should guard against.
**Proposed fix:** Add `logging: driver: json-file, options: {max-size: "10m", max-file: "3"}` to every service in `docker-compose.yml`, or configure a Docker-daemon-wide default via `/etc/docker/daemon.json` during `step_install_docker` so every future container inherits the cap automatically.

### DOCKER-4
**Severity:** MEDIUM
**File(s):** `docker-compose.yml` (all services)
**Explanation:** No service declares CPU or memory limits (`deploy.resources.limits` or the legacy `mem_limit`/`cpus` fields). On a VPS — where total RAM is typically much smaller than on a dedicated host — an unbounded Postgres (e.g., under a large query) or Redis (unbounded key growth) can consume all available memory and trigger the kernel OOM-killer against an arbitrary process, potentially including Caddy or SSH-adjacent tooling, causing a wider outage than the misbehaving service alone.
**Proposed fix:** Set conservative memory limits per service (e.g., `mem_limit: 512m` for Redis, sized relative to typical VPS RAM tiers), and document how to tune them in `ARCHITECTURE.md`.

---

## Documentation gaps

### DOC-1
**Severity:** MEDIUM
**File(s):** `ARCHITECTURE.md`, `SECURITY.md`, `PROJECT_SPEC.md`
**Explanation:** `scripts/backup.sh` writes archives only to `${REPO_ROOT}/backups/` — the same disk as the VPS's live data. Nothing in the documentation discloses that this is **not** an offsite/3-2-1 backup strategy: if the VPS's disk fails, is deleted, or the whole instance is lost, the backups are lost along with the primary data they were meant to protect against exactly that scenario.
**Proposed fix:** Add an explicit "Backup limitations" note to `ARCHITECTURE.md`'s Backups section (and/or `SECURITY.md`'s Known non-goals) stating backups are local-only in v1, and that offsite replication (e.g., periodic `rsync`/`rclone` of `backups/` to remote object storage) is a Future Extension, not yet implemented.

### DOC-2
**Severity:** MEDIUM
**File(s):** `SECURITY.md`
**Explanation:** Backup archives produced by `scripts/backup.sh` include a copy of `.env` (all secrets) inside the `tar.gz`. The archive file itself is `chmod 600`, but its *contents* are not encrypted — anyone who obtains the archive (a copied file, a misconfigured future offsite sync, an over-permissioned intermediate directory) gets every secret in plaintext. `SECURITY.md`'s Secrets section discusses `.env` itself but doesn't mention that backups duplicate those same secrets.
**Proposed fix:** Document this explicitly in `SECURITY.md`, and consider encrypting the config portion of the archive (e.g., `age`/`gpg`) as a follow-up, independent of the Postgres/Redis data which is less sensitive by comparison.

### DOC-3
**Severity:** LOW
**File(s):** `ARCHITECTURE.md`, none currently
**Explanation:** `configs/versions.env` pins `postgres:16.4-alpine` and `redis:7.4-alpine`. Alpine's musl libc has known, documented caveats for Postgres specifically around locale/collation handling (glibc-collation-based indexes can behave differently or require `REINDEX` after certain base-image updates) — a well-known operational gotcha in the Postgres community, absent from any doc in this repo.
**Proposed fix:** Add a short note to `ARCHITECTURE.md` or `TROUBLESHOOTING.md` flagging the Alpine/musl collation caveat for anyone using non-`C`/non-`POSIX` collations, with a pointer to switch to `postgres:16.4` (Debian-based) if collation stability across upgrades matters for their use case.

### DOC-4
**Severity:** LOW
**File(s):** `MIGRATION.md`
**Explanation:** `--finalize` stops the migrated services on the source host, but the source's Caddy instance (not part of the stopped set) keeps running and may continue routing public traffic to the now-stopped backends until the operator manually points DNS at the destination (per `MIGRATION.md`'s own "After a successful migration" step 2). The guide doesn't explicitly warn that this creates a brief window of source-side errors for end users.
**Proposed fix:** Add a sentence to `MIGRATION.md`'s Step 3 noting the expected brief service gap on the source between `--finalize` and the DNS cutover, and recommending the operator minimize that window by pre-staging the DNS change (low TTL) beforehand.

---

## Migration risks

(Cross-referencing findings already detailed above that are specific to `migrate.sh`; listed here together since they compound into one overall risk picture for the highest-stakes script in the repository.)

### MIG-1
**Severity:** HIGH
**File(s):** `migrate.sh` (`remote_projects_dir`)
**Explanation:**
```bash
remote_projects_dir() {
  ssh "${HOST}" 'test -f "${HOME}/.env" && grep -E "^PROJECTS_DIR=" "${HOME}/.env" | cut -d= -f2- || echo /opt/forgeops/projects'
}
```
This checks `${HOME}/.env` on the **source** host — but the source's actual ForgeOps `.env` lives at `${SOURCE_REPO_PATH}/.env` (default `/opt/forgeops-bootstrap/.env`), not in the SSH user's home directory. Every other place in `migrate.sh` correctly uses `${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}}` (the docker-config sync, `do_finalize`'s and `do_rollback`'s `cd` commands) — this function alone missed it. In practice, `test -f "${HOME}/.env"` will almost always be false on the source (unless its ForgeOps repo happens to be checked out directly into the SSH user's home directory), so this silently falls through to the hardcoded default `/opt/forgeops/projects` regardless of what the source actually has configured. If the source's real `PROJECTS_DIR` differs from the default, migration copies from — and checksums against — the wrong path, or an empty/nonexistent one.
**Proposed fix:**
```bash
remote_projects_dir() {
  local repo_path="${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}}"
  ssh "${HOST}" "test -f '${repo_path}/.env' && grep -E '^PROJECTS_DIR=' '${repo_path}/.env' | cut -d= -f2- || echo /opt/forgeops/projects"
}
```

### MIG-2
**Severity:** HIGH
**File(s):** `migrate.sh` (`do_finalize`)
**Explanation:** `do_finalize` hard-requires `--volumes` (`[[ "${DO_VOLUMES}" -eq 1 ]] || die ...`) since that's meant to be the consistent, stopped-container copy of the actual database data. But the checksum-verification block immediately after only computes and compares checksums `if [[ "${DO_PROJECTS}" -eq 1 ]]` — there is **no checksum verification for `--volumes` at all**, despite it being the mandatory, most critical payload for a finalize. If an operator runs `--finalize --volumes` without also passing `--projects` (a perfectly valid combination, since only `--volumes` is required), `mismatch` never gets set to `1` for any reason, and the script prints **"Checksums verified — source and destination match"** and proceeds to start the destination stack, having performed zero actual verification of the database data it just migrated. This directly contradicts `PROJECT_SPEC.md`'s requirement ("Verify copied data (checksum manifest, not just size/count)") and `MIGRATION.md`'s own description of what `--finalize` guarantees.
**Proposed fix:** Compute and compare a checksum manifest for each synced Docker volume's tarball (e.g., `sha256sum` of the tar.gz on both source and destination before/after transfer) as part of the mandatory `--volumes` path, and only report "verified" once that comparison passes — independent of whether `--projects` was also selected.

### MIG-3
**Severity:** HIGH
**File(s):** `migrate.sh` (`do_sync`, volumes block)
**Explanation:** The volume-sync loop chains `ssh ... tar czf` (checked via `||`), then an unchecked `scp`, then an unchecked `ssh ... rm -f`, then unchecked `docker volume create`/`docker run ... tar xzf`, and finally an unconditional `log_ok "Volume ... synced"`. Because `migrate.sh` runs under `set -uo pipefail` (deliberately **without** `-e`, to allow its own explicit error handling), none of the unchecked commands' failures actually stop the script or get surfaced — a dropped network connection mid-`scp`, a corrupt tarball, or a failed extraction all result in the same cheerful "synced" log line as a genuine success. Combined with MIG-2 (no checksum verification of volume data at all), there is currently no reliable signal — visual or automated — that a volume actually transferred intact.
**Proposed fix:** Check the exit status of `scp` explicitly (`scp ... || die "..."`) before proceeding to delete the remote temp file or attempt local extraction; check `docker run ... tar xzf`'s exit status before logging success; and feed the resulting per-volume checksum into the MIG-2 fix so a truly failed transfer is caught by at least two independent mechanisms (explicit exit-code checks, and checksum comparison) rather than zero.

---

## What was *not* found to be a problem

Worth stating explicitly, since an audit that only lists bad news is easy to misread as "the repo is broken": the two-phase migration *design* (stop-only-what's-needed, never delete source data, explicit typed confirmations, `--rollback` path), the `.env` secrets-generation and permission model, the network topology (Postgres/Redis genuinely unreachable from outside `forgeops_internal` — no `ports:` mapping exists to accidentally expose them), the version-pinning discipline in `configs/versions.env`, and the component/data separation in `uninstall.sh` were all reviewed and hold up structurally. The issues above are real and worth fixing, but they're refinements to a sound design, not signs the design itself is wrong — MIG-1/2/3 in particular are implementation bugs inside an otherwise correctly-conceived safety model, not evidence the safety model is misconceived.
