#!/usr/bin/env bash
# restore.sh - restores PostgreSQL and Redis from a backup produced by
# scripts/backup.sh. Destructive: overwrites the live database and Redis
# dataset. Requires an explicit typed confirmation unless --yes is passed.
#
# Usage:
#   ./scripts/restore.sh --list                  # show available backups
#   ./scripts/restore.sh                          # restore the most recent backup
#   ./scripts/restore.sh --from 20260714T101500Z  # restore a specific backup
#   ./scripts/restore.sh --dry-run                # show what would happen, do nothing
#   ./scripts/restore.sh --yes                     # skip the interactive confirmation

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

FROM=""
DO_LIST=0
DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) DO_LIST=1; shift ;;
    --from=*) FROM="${1#*=}"; shift ;;
    --from) FROM="${2:?--from requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

BACKUPS_DIR="${REPO_ROOT}/backups"

list_backups() {
  find "${BACKUPS_DIR}" -maxdepth 1 -name 'forgeops-backup-*.tar.gz' -printf '%f\n' 2>/dev/null | sort
}

if [[ "${DO_LIST}" -eq 1 ]]; then
  echo "Available backups:"
  list_backups | sed 's/^/  /'
  exit 0
fi

if [[ -z "${FROM}" ]]; then
  ARCHIVE="$(find "${BACKUPS_DIR}" -maxdepth 1 -name 'forgeops-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  [[ -n "${ARCHIVE}" ]] || die "No backups found in ${BACKUPS_DIR}. Run ./scripts/backup.sh first."
else
  ARCHIVE="${BACKUPS_DIR}/forgeops-backup-${FROM}.tar.gz"
  [[ -f "${ARCHIVE}" ]] || die "Backup not found: ${ARCHIVE} (use --list to see available backups)."
fi

TIMESTAMP="$(basename "${ARCHIVE}" .tar.gz | sed 's/^forgeops-backup-//')"

echo ""
echo "This will restore from: ${ARCHIVE}"
echo "The following will be OVERWRITTEN with backup contents:"
echo "  - PostgreSQL database '${POSTGRES_DB:-<from .env>}' (all current data replaced)"
echo "  - Redis dataset (all current keys replaced)"
echo ""

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[dry-run] Would extract ${ARCHIVE}, verify checksums, stop postgres+redis, restore both, then start them again."
  exit 0
fi

if [[ "${ASSUME_YES}" -eq 0 ]]; then
  read -r -p "Type 'restore' to confirm overwriting live data: " confirm
  [[ "${confirm}" == "restore" ]] || die "Confirmation did not match — aborting. Nothing was restored."
fi

[[ -f "${ENV_FILE}" ]] || die "No .env found — run install.sh first."
# shellcheck disable=SC1090
source "${ENV_FILE}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

log_info "Extracting and verifying ${ARCHIVE}..."
tar -xzf "${ARCHIVE}" -C "${WORK_DIR}" || die "Failed to extract ${ARCHIVE} — it may be corrupt. Nothing was restored."
( cd "${WORK_DIR}/${TIMESTAMP}" && sha256sum -c SHA256SUMS --quiet ) \
  || die "Checksum verification FAILED for ${ARCHIVE} — refusing to restore from a corrupt backup. Nothing was touched."
log_ok "Backup verified."

RESTORE_DIR="${WORK_DIR}/${TIMESTAMP}"

if [[ -f "${RESTORE_DIR}/postgres.dump" ]]; then
  log_info "Restoring PostgreSQL..."
  docker compose -f "${REPO_ROOT}/docker-compose.yml" stop postgres
  docker compose -f "${REPO_ROOT}/docker-compose.yml" up -d postgres
  # Wait for Postgres to accept connections before dropping/recreating.
  for _ in $(seq 1 30); do
    docker exec forgeops_postgres pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec forgeops_postgres dropdb -U "${POSTGRES_USER}" --if-exists "${POSTGRES_DB}"
  docker exec forgeops_postgres createdb -U "${POSTGRES_USER}" "${POSTGRES_DB}"
  docker cp "${RESTORE_DIR}/postgres.dump" forgeops_postgres:/tmp/restore.dump
  if ! docker exec forgeops_postgres pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" /tmp/restore.dump; then
    die "pg_restore reported errors — inspect the database manually before trusting it. The pre-restore database was already dropped; there is no automatic rollback for this step (see MIGRATION.md's rollback model, which does not cover this destructive local restore path)."
  fi
  docker exec forgeops_postgres rm -f /tmp/restore.dump
  log_ok "PostgreSQL restored."
fi

if [[ -f "${RESTORE_DIR}/redis-dump.rdb" ]]; then
  log_info "Restoring Redis..."
  docker compose -f "${REPO_ROOT}/docker-compose.yml" stop redis
  docker cp "${RESTORE_DIR}/redis-dump.rdb" forgeops_redis:/data/dump.rdb
  docker compose -f "${REPO_ROOT}/docker-compose.yml" up -d redis
  log_ok "Redis restored."
fi

log_ok "Restore complete from ${ARCHIVE}. Run ./verify.sh to confirm the stack is healthy."
