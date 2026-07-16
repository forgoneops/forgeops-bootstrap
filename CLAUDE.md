# CLAUDE.md

Authoritative engineering guide for Claude Code / Claude Cowork (and any human contributor) working in this repository. This file takes precedence over general defaults whenever the two disagree.

## Repository architecture

See `ARCHITECTURE.md` for the full picture. In short: a host layer configured by `install.sh` via apt, and a Docker Compose service layer (`docker-compose.yml`) with two networks (`forgeops_edge` public-facing via Caddy, `forgeops_internal` with no public route). `configs/versions.env` pins every component version; nothing moves to upstream `latest` implicitly.

## File organization

- `install.sh` / `verify.sh` / `update.sh` / `uninstall.sh` / `migrate.sh` — thin entry points. They parse args, load `scripts/lib/common.sh`, and call into step/check functions. Entry points should stay orchestration-only.
- `scripts/lib/common.sh` — shared logging, state tracking, and guard functions. Anything used by more than one entry point belongs here, not duplicated.
- `scripts/lib/install_steps.sh`, `scripts/lib/verify_checks.sh` — one function per install step / verify check. Each function must be independently idempotent (safe to call again even if `install.sh`'s state file is deleted).
- `scripts/render_caddyfile.sh` — the only thing that writes `docker/Caddyfile`. Never hand-edit that file; edit `templates/Caddyfile.template` instead.
- `scripts/backup.sh` / `scripts/restore.sh` — daily-scheduled (via `forgeops-backup.timer`) backup/restore of PostgreSQL, Redis, and critical config. `backup.sh` always self-verifies before keeping an archive; `restore.sh` always verifies before touching anything, and requires a typed confirmation because it's destructive.
- `configs/versions.env` — the only file `update.sh` reads for target versions. Bumping a version is a one-line edit here.
- `docs/` — supplementary docs beyond the required top-level guides.

## Coding conventions

- Every shell script starts with `set -euo pipefail` (or `set -uo pipefail` where the script needs to control its own abort/exit logic, e.g. `verify.sh`, `update.sh`, `uninstall.sh`, `migrate.sh` — document why `-e` is omitted in a comment when you do this).
- Must pass ShellCheck with no suppressions beyond documented, narrowly-scoped `# shellcheck disable=SC____` comments (e.g. `SC1090`/`SC1091` for intentional dynamic sourcing).
- Functions are named `step_<name>` (install steps) or `check_<name>` (verify checks) so entry-point arrays stay self-documenting.
- No duplicated logic between entry points — if two scripts need the same behavior, it goes in `scripts/lib/common.sh`.
- Comments explain *why*, not *what* — the function/variable names should already say what.
- Any Python added to this repo must use type hints and pass `ruff` + `mypy`; stdlib-only unless a dependency is explicitly justified in the file's own header comment.

## Documentation standards

- Every new capability gets a corresponding update to `PROJECT_SPEC.md` (if it changes the spec) and the relevant top-level doc (`ARCHITECTURE.md`, `MIGRATION.md`, `SECURITY.md`, or `TROUBLESHOOTING.md`).
- `CHANGELOG.md` gets an entry for every user-visible change, dated, before merge.
- No placeholder sections, no "TODO: document this" — if it's not documented, it's not done.

## Testing strategy

- `tests/run.sh` ShellChecks every `*.sh` file in the repo and runs the `bats` smoke tests under `tests/`. Run it before every commit that touches a script.
- New scripts or new step/check functions get a corresponding smoke test (at minimum: `--help`/`--dry-run` exits 0 and doesn't require root).
- Destructive paths (`uninstall.sh --purge-data`, `migrate.sh --finalize`) are tested via `--dry-run` in CI; full end-to-end runs are a manual pre-release step against a throwaway VPS, not part of automated CI.

## Review checklist

Before merging any change to this repository, confirm:

- [ ] No placeholder implementations, no TODO comments standing in for functionality
- [ ] ShellCheck clean (and `ruff`/`mypy` clean for any Python)
- [ ] `PROJECT_SPEC.md` updated if the change affects spec'd behavior
- [ ] Relevant doc (`ARCHITECTURE.md` / `MIGRATION.md` / `SECURITY.md` / `TROUBLESHOOTING.md`) updated
- [ ] `CHANGELOG.md` entry added
- [ ] No secret, credential, or default password introduced anywhere (grep the diff before committing)
- [ ] New/changed steps are idempotent and safe to re-run
- [ ] `tests/run.sh` passes

## Migration workflow

See `MIGRATION.md`. The short version for an AI agent operating this repo: never invoke `migrate.sh --finalize` without the operator's explicit go-ahead — it is the one command in this repository that stops services on a remote host. `--sync` is safe to run repeatedly and non-destructively.

## Update workflow

Version bumps go through `configs/versions.env`, then `sudo ./update.sh`. Never edit a pinned image tag directly in `docker-compose.yml` — that breaks the single-source-of-truth guarantee `update.sh` relies on.

## Security requirements

See `SECURITY.md`. Non-negotiables for any change: no hardcoded credentials, no default passwords, secrets only via `.env`/`env_file`, no new public-by-default network exposure (any new service defaults to `forgeops_internal` with no `ports:` mapping unless it's meant to be the edge).

## Isolated-project Compose testing (validation runs)

`docker-compose.yml` pins every top-level `volumes:` entry to a **literal**
`name:` (e.g. `postgres_data` → `forgeops_postgres_data`), matching the
literal `container_name:` and network `name:` values production already
depends on. This means Compose's project-name scoping (`-p <project>`)
does **not** protect volumes the way it protects container/network names —
Compose still parses and can act on *every* volume declared in the file,
not just the ones used by whatever services you actually bring up under
your isolated project name, because the names aren't derived from
`${COMPOSE_PROJECT_NAME}` at all.

Confirmed empirically (2026-07-16, dry-run `docker compose config` only,
no volumes touched): stripping the literal `name:` overrides and letting
Compose derive default names from the directory `docker-compose.yml`
lives in produces `forgeops-bootstrap_postgres_data`,
`forgeops-bootstrap_caddy_data`, etc. — **different names than production's
existing volumes** (`forgeops_postgres_data`, `forgeops_caddy_data`, ...).
Production's directory is literally `~/forgeops-bootstrap` on the VPS, so
this isn't a hypothetical mismatch — dropping the `name:` overrides would
make the next real `install.sh`/`update.sh` run create brand-new, empty
volumes under the derived names instead of reattaching to production's
existing data. **Do not remove the literal `name:` overrides from
`docker-compose.yml`'s `volumes:` section for this reason.**

The enforced rule instead, non-negotiable for any isolated-clone/
isolated-project Compose testing (e.g. a `-p forgeops-validate` run
against a VPS clone):

- **Never pass `-v` / `--volumes` to `docker compose down` (or `docker
  compose down` combined with a separate `docker volume rm`/`prune`)
  against this `docker-compose.yml`, full stop** — not even from an
  isolated project name, not even "just to clean up the test volume."
  Because every volume in the file resolves to production's literal
  names, `-v` risks removing production's real data volumes the moment
  production's containers aren't holding them open (see
  `.superpowers/sdd/task-8-report.md` Concern #1 for the near-miss that
  surfaced this).
- If a validation run needs a disposable Postgres/Redis volume, override
  just that service's volume mount in an **untracked**
  `docker-compose.override.*.yml` to point at a throwaway named volume
  (e.g. `forgeops_validate_postgres_data`) instead of relying on `-v`
  teardown, and delete that specific throwaway volume by its full
  explicit name (`docker volume rm forgeops_validate_postgres_data`) —
  never a bare `down -v` against the shared compose file.
- Tear down isolated validation stacks with plain `docker compose -p
  <project> down` (no `-v`), then remove only volumes you explicitly
  named yourself, by their exact name.

## Working in this repo (for Claude specifically)

- Treat `PROJECT_SPEC.md` as the source of truth for *what* the repository must do; treat this file as the source of truth for *how* to build it.
- If a request conflicts with a Non-Negotiable Rule in `PROJECT_SPEC.md` (no placeholders, no TODOs, no unnecessary complexity), say so before implementing rather than silently complying or silently refusing.
- Prefer extending `scripts/lib/*.sh` with a new function over adding logic inline in an entry-point script.
