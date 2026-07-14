# ForgeOps Bootstrap — Repository Self-Audit (Round 2)

**Date:** 2026-07-14
**Scope:** every file in the repository, against `PROJECT_SPEC.md` and general production-infrastructure practice.
**Status:** audit only — **no code has been modified in this round**. Findings are ordered by severity within each category.

## Relationship to the previous audit

This repository was previously audited on 2026-07-14 (commit `bc22877`). That audit found 24 issues (1 CRITICAL, 5 HIGH, 12 MEDIUM, 6 LOW); all 24 were fixed in commits `3e6237c` and `1f44a14`, and verified via `bash -n` and safe-path (`--help`/`--dry-run`) smoke tests. This document is a **fresh, full re-review of the current state** — every file was re-read, not diffed against the prior findings — and it surfaces issues that either (a) were introduced by the round-1 fixes themselves, or (b) existed all along but weren't caught in round 1. None of the 24 round-1 findings recur here; spot-checks (executable bits via `git ls-files -s`, Caddy admin bind, `env_file` scoping, Watchtower profile-gating) confirm those fixes are intact.

## Severity legend

| Severity | Meaning |
| --- | --- |
| CRITICAL | Breaks the golden path for every user, or causes silent data loss |
| HIGH | Undermines a core safety/reliability guarantee the repo (or its docs) makes |
| MEDIUM | Real gap against production-grade expectations; not immediately fatal |
| LOW | Correctness nit, edge case, or an undisclosed caveat |

## Summary

| ID | Severity | One-line summary |
| --- | --- | --- |
| [ARCH-1](#arch-1) | HIGH | `run_step`'s `\|\|`-based invocation silently disables `set -e` for the whole step-function call tree — an unguarded intermediate command can fail and still be reported as a successful step |
| [DOCKER-1](#docker-1) | MEDIUM | The bare-IP (`:80`) Caddy fallback block never logs, so the new `forgeops-caddy-auth` Fail2Ban jail has nothing to watch (and its behavior against a missing logpath is unverified) until a domain is configured |
| [SEC-1](#sec-1) | MEDIUM | `backup.sh`'s Postgres-dump verification hardcodes `postgres:16-alpine` instead of reading `POSTGRES_IMAGE` from `configs/versions.env`, breaking the single-source-of-truth versioning policy |
| [DOCKER-2](#docker-2) | LOW | `uninstall.sh`'s `docker compose down` omits `--profile ondemand`, so a leftover Watchtower container from an interrupted run may not be cleaned up |
| [DOC-1](#doc-1) | LOW | Nowhere documents that Caddy access logging (and the jail that depends on it) is inactive until `DOMAIN` is configured |

---

## Architecture problems

### ARCH-1
**Severity:** HIGH
**File(s):** `scripts/lib/common.sh` (`run_step`, `run_step_always`), and every multi-command step in `scripts/lib/install_steps.sh`
**Explanation:** `run_step` (and `run_step_always`) invoke each step function as `"$@" || rc=$?`. Per bash's documented `set -e` semantics, a command is exempt from `errexit` when it's "part of a command list immediately following a `while`/`until`/`if` keyword, part of the test in an `&&`/`||` list... or any command in a pipeline but the last" — and critically, **that exemption propagates into the entire body of a function called in that position**: "if a compound command or shell function executes in a context where `-e` is being ignored, none of the commands executed within the compound command or function body will be affected by the `-e` setting, even if `-e` is set." Because every step function is called as the left-hand side of `"$@" || rc=$?`, `set -e` is effectively disabled for everything inside it — including `install_steps.sh`'s own file-level `set -euo pipefail`. Concretely, any *unguarded* command in the middle of a multi-command step function can fail silently; execution continues to the next line, and the step's reported success/failure is determined only by whichever command happens to run **last**.

This affects several real steps:
- **`step_deploy_docker_stack`** (the highest-impact instance): `bash "${REPO_ROOT}/scripts/render_caddyfile.sh"` is unguarded. If it fails (e.g. a malformed `.env`), execution continues straight to the `docker pull` calls and the final `docker compose up -d ...` — which can still succeed (starting Caddy with a stale or broken Caddyfile) and thus report the *entire deploy step* as successful even though Caddy's configuration was never actually regenerated.
- **`step_configure_locale`**: if `locale-gen en_US.UTF-8` fails, `update-locale LANG=en_US.UTF-8` (the last command) can still succeed independently, masking the failure.
- **`step_install_docker`**: an unguarded `curl` (fetching the GPG key), `apt-get update -y`, and the final `apt-get install -y docker-ce ...` are all sequential and unguarded except for the final one — an early failure only surfaces if it cascades into the final command also failing.
- **`step_configure_firewall`**, **`step_configure_fail2ban`**, **`step_configure_backups`**, **`step_detect_kvm_support`**, **`ensure_env_file`**: each has 2+ sequential commands with no explicit `||`/`if` guard between them, so the same class of masking is possible in each.

This directly undermines `install.sh`'s core promise ("detect failures... fix the error above and re-run") — a step can be marked `done` in `logs/.install-state` despite a real intermediate failure, and the operator has no signal until something downstream (e.g. `verify.sh`, or a live outage) surfaces the actual broken state.
**Proposed fix:** Run the step function inside a subshell with its own `set -e`, which correctly re-establishes strict-fail semantics for everything inside it while still propagating a real exit code to the outer `||`:
```bash
run_step() {
  local step="$1"; shift
  if state_is_done "${step}"; then
    log_info "Skipping '${step}' (already completed)."
    return 0
  fi
  log_info "Running step: ${step}"
  local rc=0
  ( set -e; "$@" ) || rc=$?
  ...
}
```
This is a two-line change (mirrored in `run_step_always`) and is fully compatible with the existing "return 75 means deferred, not failed" convention — a `return 75` inside the function still terminates the subshell with exit code 75, which the outer `|| rc=$?` captures exactly as before.

---

## Docker issues

### DOCKER-1
**Severity:** MEDIUM
**File(s):** `templates/Caddyfile.template`
**Explanation:** The global `log { output file /var/log/caddy/access.log ... }` block only *defines* a logger — it does not cause any traffic to be logged unless a site block actually references it with its own `log` directive. `scripts/render_caddyfile.sh` adds `log` to the dynamically-generated `portainer.${DOMAIN}`/`status.${DOMAIN}` blocks, but the static `:80 { }` fallback block in the template (the one that's active on every install until `DOMAIN` is set) has no `log` directive. On a bare-IP install — which `README.md`'s own quick-start produces by default — `logs/caddy/access.log` is therefore never created. The `forgeops-caddy-auth` Fail2Ban jail (added specifically to close the round-1 SEC-4 finding) has `logpath` pointing at that file; whether Fail2Ban 1.0.x (Ubuntu 24.04's shipped version) tolerates a jail whose logpath doesn't exist at `fail2ban` start time — retrying once the file appears, vs. failing to register that jail at all — has not been verified against a real system.
**Proposed fix:** Add a `log` directive to the `:80` fallback block in `templates/Caddyfile.template` as well, so `access.log` (and therefore the jail) is live from the very first `install.sh` run regardless of whether a domain is ever configured. Separately, verify Fail2Ban's actual startup behavior against a missing/late-appearing logpath on a real Ubuntu 24.04 box before relying on this jail in production.

---

## Security issues

### SEC-1
**Severity:** MEDIUM
**File(s):** `scripts/backup.sh`
**Explanation:**
```bash
if ! docker run --rm -v "${verify_dir}/${TIMESTAMP}:/backup:ro" postgres:16-alpine \
    pg_restore --list /backup/postgres.dump >/dev/null 2>&1; then
```
This hardcodes `postgres:16-alpine` for the throwaway container used to validate a backup's `pg_restore --list` readability. `backup.sh` never sources `configs/versions.env` (it only sources `common.sh` and `.env`), so `${POSTGRES_IMAGE}` isn't even available to it. Every other script in the repo treats `configs/versions.env` as the single source of truth for component versions (`install.sh`, `update.sh`, `uninstall.sh` all `load_versions` or source it explicitly) — this is the one place a Postgres-related version is hardcoded instead. If `POSTGRES_IMAGE` is ever bumped to a different major version in `configs/versions.env`, backup verification silently runs against a mismatched `pg_restore` binary without any warning, undermining the versioning policy `PROJECT_SPEC.md` and `ARCHITECTURE.md` both document as load-bearing.
**Proposed fix:** Simplest and avoids version drift entirely: run the verification via `docker exec` against the already-running `forgeops_postgres` container (whatever version is actually deployed) instead of spinning up a separate throwaway image:
```bash
docker cp "${verify_dir}/${TIMESTAMP}/postgres.dump" forgeops_postgres:/tmp/verify.dump \
  && docker exec forgeops_postgres pg_restore --list /tmp/verify.dump >/dev/null \
  && docker exec forgeops_postgres rm -f /tmp/verify.dump
```
(Alternative: `source "${VERSIONS_FILE}"` in `backup.sh` and use `${POSTGRES_IMAGE}` in the existing throwaway-container approach — works, but the `docker exec` approach is simpler and has zero version-mismatch surface by construction.)

---

## Docker issues (continued)

### DOCKER-2
**Severity:** LOW
**File(s):** `uninstall.sh`
**Explanation:** `docker compose down --remove-orphans` is not profile-aware unless `--profile ondemand` is passed (the same way `up`/`run` require it for Watchtower, per the round-1 DOCKER-2 fix). If a `forgeops_watchtower` container is ever left running — e.g. a `docker compose --profile ondemand run --rm watchtower` invocation from `update.sh` gets interrupted (SIGKILL, VM reboot) before Docker's `--rm` cleanup completes — a plain `sudo ./uninstall.sh` may not remove it, since Watchtower isn't in the default (unprofiled) service set `down` considers.
**Proposed fix:** Add `--profile ondemand` to `uninstall.sh`'s `docker compose down --remove-orphans` call so it considers every service regardless of profile.

---

## Documentation gaps

### DOC-1
**Severity:** LOW
**File(s):** `ARCHITECTURE.md`, `SECURITY.md`
**Explanation:** Neither doc currently mentions that Caddy access logging — and by extension, the `forgeops-caddy-auth` Fail2Ban jail described in `SECURITY.md`'s "What's hardened by default" section — is inactive on a bare-IP install until `DOMAIN` is configured (see DOCKER-1, above). As written, `SECURITY.md` reads as if that protection is active unconditionally from install.
**Proposed fix:** Add a one-line caveat to `SECURITY.md`'s `forgeops-caddy-auth` bullet noting it requires `DOMAIN` to be configured (or, once DOCKER-1 is fixed, that the file itself starts logging from install regardless — update the wording to match whichever fix is applied).

---

## What was re-checked and found solid

Executable bits (`git ls-files -s` — every script still `100755`), the Caddy admin-API `localhost:2019` bind, Postgres/Redis's scoped `environment:` blocks (no more wholesale `env_file: .env`), Watchtower's `restart: "no"` + `profiles: ["ondemand"]` crash-loop guard, the `run_step`/`run_step_always` split enabling `deploy_docker_stack` to actually re-run on a plain `install.sh` invocation, `migrate.sh`'s corrected `remote_projects_dir()` path and per-volume checksum verification in `--finalize`, and `restore.sh`'s atomic shadow-database swap were all re-read in full and remain correctly implemented. No categories beyond the five above (idempotency beyond ARCH-1, ShellCheck, portability, migration risk) turned up new findings this round — the round-1 fixes in those areas hold up under a fresh read.
