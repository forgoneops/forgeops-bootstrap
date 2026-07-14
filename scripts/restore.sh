#!/usr/bin/env bash
# Restores PostgreSQL and Redis from a backup made by scripts/backup.sh.
# Destructive — overwrites live data. Needs a typed confirmation unless
# --yes is passed.
#
# Usage:
#   ./scripts/restore.sh --list                  # show available backups
#   ./scripts/restore.sh                          # restore the most recent
#   ./scripts/restore.sh --from 20260714T101500Z  # restore a specific one
#   ./scripts/restore.sh --dry-run                # show what would happen
#   ./scripts/restore.sh --yes                     # skip the confirmation prompt

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
    *) die "unknown argument: $1" ;;
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
  [[ -n "${ARCHIVE}" ]] || die "no backups in ${BACKUPS_DIR} — run ./scripts/backup.sh first"
else
  ARCHIVE="${BACKUPS_DIR}/forgeops-backup-${FROM}.tar.gz"
  [[ -f "${ARCHIVE}" ]] || die "no backup at ${ARCHIVE} (use --list to see what's there)"
fi

TIMESTAMP="$(basename "${ARCHIVE}" .tar.gz | sed 's/^forgeops-backup-//')"

echo ""
echo "This will restore from: ${ARCHIVE}"
echo "The following will be OVERWRITTEN:"
echo "  - PostgreSQL database '${POSTGRES_DB:-<from .env>}'"
echo "  - Redis dataset"
echo ""

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[dry-run] would extract ${ARCHIVE}, verify checksums, stop postgres+redis, restore both, start them back up"
  exit 0
fi

if [[ "${ASSUME_YES}" -eq 0 ]]; then
  read -r -p "Type 'restore' to confirm overwriting live data: " confirm
  [[ "${confirm}" == "restore" ]] || die "confirmation didn't match — nothing restored"
fi

[[ -f "${ENV_FILE}" ]] || die "no .env found — run install.sh first"
# shellcheck disable=SC1090
source "${ENV_FILE}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

log_info "extracting and checking ${ARCHIVE}..."
tar -xzf "${ARCHIVE}" -C "${WORK_DIR}" || die "couldn't extract ${ARCHIVE}, it may be corrupt — nothing restored"
( cd "${WORK_DIR}/${TIMESTAMP}" && sha256sum -c SHA256SUMS --quiet ) \
  || die "checksum check failed for ${ARCHIVE} — refusing to restore from a broken backup, nothing touched"
log_ok "backup checks out"

RESTORE_DIR="${WORK_DIR}/${TIMESTAMP}"

if [[ -f "${RESTORE_DIR}/postgres.dump" ]]; then
  log_info "restoring PostgreSQL (into a shadow database first — only swapped in once pg_restore actually succeeds)..."
  docker compose -f "${REPO_ROOT}/docker-compose.yml" stop postgres
  docker compose -f "${REPO_ROOT}/docker-compose.yml" up -d postgres
  for _ in $(seq 1 30); do
    docker exec forgeops_postgres pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1 && break
    sleep 1
  done

  shadow_db="${POSTGRES_DB}_restoring"
  prerestore_db="${POSTGRES_DB}_prerestore_$(date -u +%Y%m%dT%H%M%SZ)"

  # PGPASSWORD explicit rather than relying on local-socket trust auth.
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres dropdb -U "${POSTGRES_USER}" --if-exists "${shadow_db}"
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres createdb -U "${POSTGRES_USER}" "${shadow_db}"
  docker cp "${RESTORE_DIR}/postgres.dump" forgeops_postgres:/tmp/restore.dump

  if ! docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres pg_restore -U "${POSTGRES_USER}" -d "${shadow_db}" /tmp/restore.dump; then
    docker exec forgeops_postgres rm -f /tmp/restore.dump
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres dropdb -U "${POSTGRES_USER}" --if-exists "${shadow_db}"
    die "pg_restore had errors restoring into a shadow database — the live '${POSTGRES_DB}' was never touched, fix the archive and retry"
  fi
  docker exec forgeops_postgres rm -f /tmp/restore.dump

  # Swap: kick everyone off both DBs, move the live one aside (kept, not
  # dropped), promote the shadow into its place.
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres psql -U "${POSTGRES_USER}" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('${POSTGRES_DB}','${shadow_db}') AND pid <> pg_backend_pid();" >/dev/null
  if docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres psql -U "${POSTGRES_USER}" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" | grep -q 1; then
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres psql -U "${POSTGRES_USER}" -d postgres -c \
      "ALTER DATABASE \"${POSTGRES_DB}\" RENAME TO \"${prerestore_db}\";" >/dev/null
  fi
  if ! docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres psql -U "${POSTGRES_USER}" -d postgres -c \
      "ALTER DATABASE \"${shadow_db}\" RENAME TO \"${POSTGRES_DB}\";" >/dev/null; then
    die "restored fine into '${shadow_db}' but the final rename failed. Old database (if any) is at '${prerestore_db}'. Fix this by hand — nothing was lost, it's just not in the right place yet."
  fi
  log_ok "PostgreSQL restored. Old database kept as '${prerestore_db}' — drop it yourself once you trust the restore."
fi

if [[ -f "${RESTORE_DIR}/redis-dump.rdb" ]]; then
  log_info "restoring Redis..."
  docker compose -f "${REPO_ROOT}/docker-compose.yml" stop redis
  docker cp "${RESTORE_DIR}/redis-dump.rdb" forgeops_redis:/data/dump.rdb
  docker compose -f "${REPO_ROOT}/docker-compose.yml" up -d redis
  log_ok "Redis restored"
fi

log_ok "restore complete from ${ARCHIVE} — run ./verify.sh to double-check"
