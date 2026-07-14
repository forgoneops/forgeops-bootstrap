#!/usr/bin/env bash
# backup.sh - takes a verified, timestamped backup of ForgeOps Bootstrap's
# stateful data: PostgreSQL (pg_dump custom format), Redis (RDB snapshot),
# and critical config (.env, docker-compose.yml, configs/versions.env).
#
# Run daily by the forgeops-backup.timer systemd unit (installed by
# install.sh's configure_backups step); also safe to run manually.
#
# Every backup is verified immediately after creation — a corrupt or
# incomplete backup is deleted and treated as a failed run, not silently
# kept. Retention is enforced via BACKUP_RETENTION_DAYS in .env.
#
# Usage:
#   ./scripts/backup.sh              # take a backup now
#   ./scripts/backup.sh --dry-run    # show what would happen, do nothing

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: ${arg}" ;;
  esac
done

[[ -f "${ENV_FILE}" ]] || die "No .env found — run install.sh first."
# shellcheck disable=SC1090
source "${ENV_FILE}"

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${REPO_ROOT}/backups/${TIMESTAMP}"
ARCHIVE="${REPO_ROOT}/backups/forgeops-backup-${TIMESTAMP}.tar.gz"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[dry-run] Would create ${BACKUP_DIR}, back up Postgres + Redis + config, archive to ${ARCHIVE}, verify it, then prune backups older than ${RETENTION_DAYS} days."
  exit 0
fi

mkdir -p "${BACKUP_DIR}/config"

# --- 1. PostgreSQL: pg_dump in custom format (supports pg_restore --list verification) ---
if docker ps --filter "name=forgeops_postgres" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_postgres; then
  log_info "Dumping PostgreSQL database '${POSTGRES_DB}'..."
  if ! docker exec forgeops_postgres pg_dump -U "${POSTGRES_USER}" -Fc "${POSTGRES_DB}" >"${BACKUP_DIR}/postgres.dump"; then
    rm -rf "${BACKUP_DIR}"
    die "pg_dump failed — backup aborted, no partial backup left behind."
  fi
else
  log_warn "forgeops_postgres is not running — skipping PostgreSQL backup for this run."
fi

# --- 2. Redis: trigger BGSAVE, wait for it to complete, then copy the RDB file ---
if docker ps --filter "name=forgeops_redis" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_redis; then
  log_info "Snapshotting Redis..."
  before_save="$(docker exec forgeops_redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning LASTSAVE)"
  docker exec forgeops_redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning BGSAVE >/dev/null
  waited=0
  while [[ "$(docker exec forgeops_redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning LASTSAVE)" == "${before_save}" ]]; do
    sleep 1
    waited=$((waited + 1))
    if [[ "${waited}" -ge 60 ]]; then
      rm -rf "${BACKUP_DIR}"
      die "Redis BGSAVE did not complete within 60s — backup aborted."
    fi
  done
  docker cp forgeops_redis:/data/dump.rdb "${BACKUP_DIR}/redis-dump.rdb"
else
  log_warn "forgeops_redis is not running — skipping Redis backup for this run."
fi

# --- 3. Critical config (never secrets-free, so this archive must be treated as sensitive) ---
cp "${ENV_FILE}" "${BACKUP_DIR}/config/.env"
cp "${REPO_ROOT}/docker-compose.yml" "${BACKUP_DIR}/config/docker-compose.yml"
cp "${VERSIONS_FILE}" "${BACKUP_DIR}/config/versions.env"
chmod 600 "${BACKUP_DIR}/config/.env"

# --- 4. Checksum manifest, then archive ---
( cd "${BACKUP_DIR}" && find . -type f -not -name SHA256SUMS -exec sha256sum {} \; | sort >SHA256SUMS )
tar -C "${REPO_ROOT}/backups" -czf "${ARCHIVE}" "${TIMESTAMP}"
rm -rf "${BACKUP_DIR}"
chmod 600 "${ARCHIVE}"

# --- 5. Verify the archive: extractable, checksums match, Postgres dump structurally valid ---
verify_dir="$(mktemp -d)"
trap 'rm -rf "${verify_dir}"' EXIT

if ! tar -xzf "${ARCHIVE}" -C "${verify_dir}"; then
  rm -f "${ARCHIVE}"
  die "Backup verification FAILED: archive did not extract cleanly. Deleted the bad archive — re-run backup.sh."
fi

if ! ( cd "${verify_dir}/${TIMESTAMP}" && sha256sum -c SHA256SUMS --quiet ); then
  rm -f "${ARCHIVE}"
  die "Backup verification FAILED: checksum mismatch. Deleted the bad archive — re-run backup.sh."
fi

if [[ -f "${verify_dir}/${TIMESTAMP}/postgres.dump" ]]; then
  if ! docker run --rm -v "${verify_dir}/${TIMESTAMP}:/backup:ro" postgres:16-alpine \
      pg_restore --list /backup/postgres.dump >/dev/null 2>&1; then
    rm -f "${ARCHIVE}"
    die "Backup verification FAILED: pg_restore could not read postgres.dump. Deleted the bad archive — re-run backup.sh."
  fi
fi

log_ok "Backup verified: ${ARCHIVE}"

# --- 6. Enforce retention ---
find "${REPO_ROOT}/backups" -maxdepth 1 -name 'forgeops-backup-*.tar.gz' -mtime "+${RETENTION_DAYS}" -print -delete \
  | while read -r pruned; do log_info "Pruned backup older than ${RETENTION_DAYS} days: ${pruned}"; done

log_ok "Backup complete: ${ARCHIVE}"
