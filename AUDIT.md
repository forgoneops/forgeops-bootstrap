# ForgeOps Bootstrap — Repository Self-Audit (Round 3)

**Date:** 2026-07-14
**Scope:** every file in the repository, against `PROJECT_SPEC.md` and general production-infrastructure practice.
**Status:** audit only — **no code has been modified in this round**.

## Relationship to the previous audits

Round 1 (commit `bc22877`) found 24 issues, fixed in `3e6237c`/`1f44a14`. Round 2 (commit `40aa826`) found 5 more, fixed in `27e5e05`. Since then the repo went through a cleanup pass (comment/log-message trim across every script, `docker-compose.yml`, `templates/Caddyfile.template`, and a README rewrite — commits `6d74c8d` through `a762e71`) that touched nearly every file but wasn't meant to change behavior. This round re-reads everything fresh, both to catch anything that cleanup pass got wrong and to look for whatever the first two rounds missed.

Result: nothing from rounds 1 or 2 has regressed — spot-checked the ones most likely to break under a rewrite (the `run_step` `set -e` fix, `docker-compose.yml`'s `mem_limit`/`logging`/`profiles` fields, `migrate.sh`'s volume-checksum logic) and all still work as designed, confirmed with `bash -n` plus the existing smoke tests and a standalone reproduction of the `run_step` fix. Four small findings below, none above LOW/MEDIUM — this is a noticeably shorter list than the previous two rounds, which tracks: the two big issues (broken golden path, weak migration verification) are the kind of thing that gets found once and stays fixed.

## Summary

| ID | Severity | One-line summary |
| --- | --- | --- |
| [DOC-1](#doc-1) | MEDIUM | README claims "5-10 minutes" for install.sh — a number nobody has actually measured, since this has never run against a real VPS |
| [DOC-2](#doc-2) | MEDIUM | README's health-report output is a hand-written example, not a real capture, and isn't clearly labeled as such |
| [STYLE-1](#style-1) | LOW | `render_caddyfile.sh`'s final log line kept its old capitalization while every other script's messages got lowercased |
| [SC-1](#sc-1) | LOW | `verify.sh`'s summary line always says "N warnings" / "N failed" even when N is 1 |

---

## Documentation gaps

### DOC-1
**Severity:** MEDIUM
**File(s):** `README.md`
**Explanation:** The Quick Start section says installing "takes 5-10 minutes on a fresh box." Nothing in this repo's history includes an actual timed run of `install.sh` against a real Ubuntu 24.04 VPS — every verification so far has been `bash -n` and `--help`/`--dry-run` smoke tests on this Windows dev machine, which can't run the script for real. The number is a plausible guess (a handful of apt installs, Docker Engine setup, five image pulls), not a measurement, and reads as more authoritative than it is.
**Proposed fix:** Either drop the number entirely ("takes a few minutes" or no claim at all), or measure it on a real box and keep the number once it's actually true.

### DOC-2
**Severity:** MEDIUM
**File(s):** `README.md`
**Explanation:** The "Example output on a clean install" block was written by hand to illustrate what `verify.sh` produces — it was not captured from an actual run, because (per DOC-1) no real run has happened yet. The label "Example output" is a little ambiguous: it could mean "here's a real example" as easily as "here's an illustration of the format." A reader skimming the README could reasonably take this as evidence the tool has been exercised end-to-end, which it hasn't.
**Proposed fix:** Either relabel it explicitly ("illustrative — not from a real run" or similar) or replace it with genuine output once install.sh has actually been run somewhere.

---

## ShellCheck / style issues

### STYLE-1
**Severity:** LOW
**File(s):** `scripts/render_caddyfile.sh`
**Explanation:** The cleanup pass lowercased routine log/error messages across every script (`"done: ${step}"`, `"backup complete: ..."`, etc.) so that capitals would stand out for genuinely emphasized text. `render_caddyfile.sh`'s last line, `log_ok "Rendered ${OUT}"`, was missed and kept its original capital.
**Proposed fix:** `log_ok "rendered ${OUT}"`, matching everything else.

### SC-1
**Severity:** LOW
**File(s):** `verify.sh`
**Explanation:** `printf '\n%d passed, %d warnings, %d failed\n\n' ...` always pluralizes "warnings" and "failed," so a report with exactly one warning or one failure reads "1 warnings" / "1 failed." Cosmetic, but noticeable every time it happens.
**Proposed fix:** A small helper — `plural() { [[ "$1" == 1 ]] && echo "$2" || echo "$2s"; }` — or just accept the grammar and move on; genuinely low priority.

---

## What was re-checked and found solid

Re-read in full: `install.sh`, `scripts/lib/common.sh`, `scripts/lib/install_steps.sh`, `verify.sh`, `scripts/lib/verify_checks.sh`, `update.sh`, `uninstall.sh`, `migrate.sh`, `scripts/backup.sh`, `scripts/restore.sh`, `docker-compose.yml`, `templates/Caddyfile.template`, `scripts/render_caddyfile.sh`. Specifically re-verified:

- The `run_step`/`run_step_always` `set +e; ( set -e; "$@" ); rc=$?; set -e` pattern still catches a mid-function failure — reran the `false; true` reproduction against the current file.
- `docker-compose.yml`'s `mem_limit`, `logging: *default-logging`, and Watchtower's `restart: "no"` + `profiles: ["ondemand"]` are all intact and unchanged in substance by the comment trim.
- `migrate.sh`'s `remote_projects_dir()` still reads from the source repo's own `.env`, and `--finalize`'s volume-checksum gate (`ok_volumes`/`failed_volumes`/`skipped_volumes`) is unchanged.
- `backup.sh`/`restore.sh` still use `PGPASSWORD`/`REDISCLI_AUTH` explicitly and `backup.sh`'s Postgres verification still runs against the live container instead of a pinned image tag.
- Full `bash -n` pass and the `--help`/`--dry-run` smoke suite: all clean.

No hardcoded secrets, no new bugs in the entry-point scripts' argument parsing or control flow, no inconsistencies found between `README.md`'s command table and what the scripts actually do (this round's DOC findings are about unverified claims, not incorrect ones).
