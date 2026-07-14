#!/usr/bin/env bash
# Takes a verified backup: PostgreSQL (pg_dump), Redis (RDB snapshot), and
# config (.env, docker-compose.yml, configs/versions.env).
#
# Runs daily via the forgeops-backup.timer systemd unit, also fine to run
# by hand. A backup that fails verification gets deleted, not kept around
# to give a false sense of safety. Retention is BACKUP_RETENTION_DAYS in
# .env.
#
# Usage:
#   ./scripts/backup.sh              # back up now
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
    *) die "unknown argument: ${arg}" ;;
  esac
done

[[ -f "${ENV_FILE}" ]] || die "no .env found — run install.sh first"
# shellcheck disable=SC1090
source "${ENV_FILE}"

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${REPO_ROOT}/backups/${TIMESTAMP}"
ARCHIVE="${REPO_ROOT}/backups/forgeops-backup-${TIMESTAMP}.tar.gz"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[dry-run] would back up Postgres + Redis + config to ${ARCHIVE}, verify it, prune anything older than ${RETENTION_DAYS} days"
  exit 0
fi

mkdir -p "${BACKUP_DIR}/config"

# 1. Postgres — custom format so pg_restore --list can sanity-check it later.
if docker ps --filter "name=forgeops_postgres" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_postgres; then
  log_info "dumping ${POSTGRES_DB}..."
  # PGPASSWORD explicit rather than relying on the image's default
  # local-socket trust auth — works either way, but this doesn't depend on
  # that default staying put.
  if ! docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" forgeops_postgres pg_dump -U "${POSTGRES_USER}" -Fc "${POSTGRES_DB}" >"${BACKUP_DIR}/postgres.dump"; then
    rm -rf "${BACKUP_DIR}"
    die "pg_dump failed — nothing partial left behind"
  fi
else
  log_warn "forgeops_postgres isn't running, skipping Postgres backup this time"
fi

# 2. Redis — BGSAVE, wait for it, copy the RDB file.
if docker ps --filter "name=forgeops_redis" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_redis; then
  log_info "snapshotting Redis..."
  # REDISCLI_AUTH instead of -a so the password isn't sitting in argv where
  # `docker top`/`ps aux` could see it.
  before_save="$(docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD}" forgeops_redis redis-cli --no-auth-warning LASTSAVE)"
  docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD}" forgeops_redis redis-cli --no-auth-warning BGSAVE >/dev/null
  waited=0
  while [[ "$(docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD}" forgeops_redis redis-cli --no-auth-warning LASTSAVE)" == "${before_save}" ]]; do
    sleep 1
    waited=$((waited + 1))
    if [[ "${waited}" -ge 60 ]]; then
      rm -rf "${BACKUP_DIR}"
      die "Redis BGSAVE didn't finish in 60s"
    fi
  done
  docker cp forgeops_redis:/data/dump.rdb "${BACKUP_DIR}/redis-dump.rdb"
else
  log_warn "forgeops_redis isn't running, skipping Redis backup this time"
fi

# 3. Config — this makes the archive sensitive, treat it like .env.
cp "${ENV_FILE}" "${BACKUP_DIR}/config/.env"
cp "${REPO_ROOT}/docker-compose.yml" "${BACKUP_DIR}/config/docker-compose.yml"
cp "${VERSIONS_FILE}" "${BACKUP_DIR}/config/versions.env"
chmod 600 "${BACKUP_DIR}/config/.env"

# 4. Checksum manifest, then archive.
( cd "${BACKUP_DIR}" && find . -type f -not -name SHA256SUMS -exec sha256sum {} \; | sort >SHA256SUMS )
tar -C "${REPO_ROOT}/backups" -czf "${ARCHIVE}" "${TIMESTAMP}"
rm -rf "${BACKUP_DIR}"
chmod 600 "${ARCHIVE}"

# 5. Verify: extracts cleanly, checksums match, Postgres dump is readable.
verify_dir="$(mktemp -d)"
trap 'rm -rf "${verify_dir}"' EXIT

if ! tar -xzf "${ARCHIVE}" -C "${verify_dir}"; then
  rm -f "${ARCHIVE}"
  die "backup verification failed: archive wouldn't extract, deleted it — try again"
fi

if ! ( cd "${verify_dir}/${TIMESTAMP}" && sha256sum -c SHA256SUMS --quiet ); then
  rm -f "${ARCHIVE}"
  die "backup verification failed: checksum mismatch, deleted the archive — try again"
fi

if [[ -f "${verify_dir}/${TIMESTAMP}/postgres.dump" ]]; then
  # Checked against the live forgeops_postgres container rather than a
  # separately pinned image, so this can't drift out of sync with whatever
  # POSTGRES_IMAGE is actually running.
  if docker ps --filter "name=forgeops_postgres" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_postgres; then
    docker cp "${verify_dir}/${TIMESTAMP}/postgres.dump" forgeops_postgres:/tmp/verify.dump
    verify_ok=1
    docker exec forgeops_postgres pg_restore --list /tmp/verify.dump >/dev/null 2>&1 || verify_ok=0
    docker exec forgeops_postgres rm -f /tmp/verify.dump
    if [[ "${verify_ok}" -eq 0 ]]; then
      rm -f "${ARCHIVE}"
      die "backup verification failed: pg_restore couldn't read postgres.dump, deleted the archive — try again"
    fi
  else
    log_warn "forgeops_postgres isn't running, skipped the pg_restore check (checksums already passed)"
  fi
fi

log_ok "verified: ${ARCHIVE}"

# 6. Retention.
find "${REPO_ROOT}/backups" -maxdepth 1 -name 'forgeops-backup-*.tar.gz' -mtime "+${RETENTION_DAYS}" -print -delete \
  | while read -r pruned; do log_info "pruned (older than ${RETENTION_DAYS}d): ${pruned}"; done

log_ok "backup complete: ${ARCHIVE}"
