#!/usr/bin/env bash
# Pulls an existing VPS's data onto this one over SSH.
#
# Two phases:
#   --sync      Repeatable, non-destructive. Copies data from the source
#               while it keeps running. Run it as many times as you want.
#   --finalize  One-time cutover. Stops only the migrated containers on
#               the source, does one last --sync, verifies checksums, and
#               only then starts things on the destination. If
#               verification fails, nothing starts on the destination and
#               the source is left stopped but intact.
#   --rollback  Restarts what --finalize stopped on the source.
#
# The source is never modified beyond that stop in --finalize — no files
# touched, nothing deleted — so it stays a valid rollback target until you
# decide to decommission it yourself.
#
# Usage:
#   ./migrate.sh --host user@source-host --sync   [targets...] [--dry-run] [--verbose]
#   ./migrate.sh --host user@source-host --finalize [targets...] [--verbose]
#   ./migrate.sh --host user@source-host --rollback
#
# Targets (any combination; default = --projects --claude-config --docker-config):
#   --projects        sync ${PROJECTS_DIR}
#   --claude-config    sync ~/.claude on the source
#   --docker-config    sync docker-compose files + docker/ + configs/ from the source repo
#   --ssh-config       sync ~/.ssh (optional — keys are copied, not regenerated)
#   --volumes          sync named Docker volumes (postgres, redis, portainer, uptime-kuma)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

HOST=""
MODE=""
DRY_RUN=0
VERBOSE=0
DO_PROJECTS=0
DO_CLAUDE=0
DO_DOCKER=0
DO_SSH=0
DO_VOLUMES=0
ANY_TARGET_SET=0

RSYNC_FLAGS=(-a --partial --info=progress2)

MIGRATION_STATE="${LOG_DIR}/.migrate-state"
SOURCE_REPO_PATH_DEFAULT="/opt/forgeops-bootstrap"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --sync) MODE="sync"; shift ;;
    --finalize) MODE="finalize"; shift ;;
    --rollback) MODE="rollback"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --projects) DO_PROJECTS=1; ANY_TARGET_SET=1; shift ;;
    --claude-config) DO_CLAUDE=1; ANY_TARGET_SET=1; shift ;;
    --docker-config) DO_DOCKER=1; ANY_TARGET_SET=1; shift ;;
    --ssh-config) DO_SSH=1; ANY_TARGET_SET=1; shift ;;
    --volumes) DO_VOLUMES=1; ANY_TARGET_SET=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "${VERBOSE}" -eq 1 ]] && RSYNC_FLAGS+=(-v)
[[ "${DRY_RUN}" -eq 1 ]] && RSYNC_FLAGS+=(--dry-run)

[[ -n "${MODE}" ]] || die "need one of --sync, --finalize, --rollback (see --help)"

if [[ "${MODE}" != "rollback" && "${ANY_TARGET_SET}" -eq 0 ]]; then
  DO_PROJECTS=1; DO_CLAUDE=1; DO_DOCKER=1
  log_info "no targets given — defaulting to --projects --claude-config --docker-config"
fi

if [[ "${MODE}" != "rollback" ]]; then
  [[ -n "${HOST}" ]] || die "--host user@source-host is required"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${HOST}" 'true' \
    || die "can't reach ${HOST} over SSH with key auth — fix that before migrating"
fi

remote_projects_dir() {
  # Reads PROJECTS_DIR from the source's own ForgeOps .env, not from
  # $HOME/.env — that's almost never where it actually lives.
  local repo_path="${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}}"
  ssh "${HOST}" "test -f '${repo_path}/.env' && grep -E '^PROJECTS_DIR=' '${repo_path}/.env' | cut -d= -f2- || echo /opt/forgeops/projects"
}

# --- --sync: repeatable, non-destructive ------------------------------------
do_sync() {
  mkdir -p "${REPO_ROOT}/backups/migrate-manifests"

  if [[ "${DO_PROJECTS}" -eq 1 ]]; then
    local src_projects
    src_projects="$(remote_projects_dir)"
    local dst_projects="${PROJECTS_DIR:-/opt/forgeops/projects}"
    mkdir -p "${dst_projects}"
    log_info "syncing projects: ${HOST}:${src_projects}/ -> ${dst_projects}/"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_projects}/" "${dst_projects}/"
  fi

  if [[ "${DO_CLAUDE}" -eq 1 ]]; then
    log_info "syncing Claude config: ${HOST}:~/.claude/ -> ${HOME}/.claude/"
    mkdir -p "${HOME}/.claude"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:.claude/" "${HOME}/.claude/" 2>/dev/null \
      || log_warn "no ~/.claude on ${HOST}, skipping"
  fi

  if [[ "${DO_DOCKER}" -eq 1 ]]; then
    local src_repo="${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}}"
    log_info "syncing docker config: ${HOST}:${src_repo}/{docker,configs,docker-compose.yml} -> ${REPO_ROOT}/"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_repo}/docker/" "${REPO_ROOT}/docker/" 2>/dev/null || true
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_repo}/configs/" "${REPO_ROOT}/configs/" 2>/dev/null || true
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_repo}/docker-compose.yml" "${REPO_ROOT}/docker-compose.yml.from-source" 2>/dev/null \
      && log_warn "source docker-compose.yml saved as docker-compose.yml.from-source for you to review — not applied automatically"
  fi

  if [[ "${DO_SSH}" -eq 1 ]]; then
    log_info "syncing SSH config: ${HOST}:~/.ssh/ -> ${HOME}/.ssh/"
    mkdir -p "${HOME}/.ssh"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:.ssh/" "${HOME}/.ssh/" 2>/dev/null || log_warn "no ~/.ssh on ${HOST}, skipping"
    [[ "${DRY_RUN}" -eq 0 ]] && chmod 700 "${HOME}/.ssh" && find "${HOME}/.ssh" -type f -exec chmod 600 {} \;
  fi

  if [[ "${DO_VOLUMES}" -eq 1 ]]; then
    # Fresh status file every call — one line per volume (OK/FAILED/
    # SKIPPED) so --finalize can tell a real pass from one that checked
    # nothing.
    local status_file="${LOG_DIR}/.migrate-volume-status"
    : >"${status_file}"
    for vol in postgres redis portainer uptime_kuma; do
      log_info "syncing volume ${vol} (live snapshot, source keeps running)..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[dry-run] would tar forgeops_${vol}_data on ${HOST}, transfer, checksum, extract"
        continue
      fi

      local remote_sha
      remote_sha="$(ssh "${HOST}" "docker run --rm -v forgeops_${vol}_data:/from -v /tmp:/to alpine sh -c 'tar czf /to/forgeops_${vol}_data.tar.gz -C /from . && sha256sum /to/forgeops_${vol}_data.tar.gz'" 2>/dev/null | awk '{print $1}')"
      if [[ -z "${remote_sha}" ]]; then
        log_warn "volume forgeops_${vol}_data not on source (or tar failed there), skipping"
        echo "${vol}:SKIPPED:not present or tar failed on source" >>"${status_file}"
        continue
      fi

      if ! scp -q "${HOST}:/tmp/forgeops_${vol}_data.tar.gz" "${LOG_DIR}/"; then
        log_error "scp failed for forgeops_${vol}_data.tar.gz — not synced"
        echo "${vol}:FAILED:scp transfer failed" >>"${status_file}"
        ssh "${HOST}" "rm -f /tmp/forgeops_${vol}_data.tar.gz" 2>/dev/null || true
        continue
      fi
      ssh "${HOST}" "rm -f /tmp/forgeops_${vol}_data.tar.gz" 2>/dev/null || true

      local local_sha
      local_sha="$(sha256sum "${LOG_DIR}/forgeops_${vol}_data.tar.gz" 2>/dev/null | awk '{print $1}')"
      if [[ "${local_sha}" != "${remote_sha}" ]]; then
        log_error "checksum mismatch for forgeops_${vol}_data.tar.gz (remote=${remote_sha} local=${local_sha:-<missing>}) — not synced, kept at ${LOG_DIR}/forgeops_${vol}_data.tar.gz for a look"
        echo "${vol}:FAILED:checksum mismatch after transfer" >>"${status_file}"
        continue
      fi

      docker volume create "forgeops_${vol}_data" >/dev/null
      if ! docker run --rm -v "forgeops_${vol}_data:/to" -v "${LOG_DIR}:/from" alpine \
          sh -c "tar xzf /from/forgeops_${vol}_data.tar.gz -C /to"; then
        log_error "extraction failed for forgeops_${vol}_data — not synced"
        echo "${vol}:FAILED:local extraction failed" >>"${status_file}"
        rm -f "${LOG_DIR}/forgeops_${vol}_data.tar.gz"
        continue
      fi
      rm -f "${LOG_DIR}/forgeops_${vol}_data.tar.gz"
      echo "${vol}:OK:${local_sha}" >>"${status_file}"
      log_ok "volume ${vol} synced and checksum-verified (${local_sha:0:12}...)"
    done
  fi

  log_ok "sync done — run --sync again any time, nothing on ${HOST} was touched"
}

# --- --finalize: one-time cutover with real verification --------------------
do_finalize() {
  [[ "${DO_VOLUMES}" -eq 1 ]] || die "--finalize needs --volumes so the final snapshot includes the stopped-container data — re-run with --volumes"

  log_warn "this stops containers on ${HOST} for a final sync. Destination won't start until checksums verify."
  read -r -p "Type 'finalize' to proceed: " confirm
  [[ "${confirm}" == "finalize" ]] || die "confirmation didn't match — nothing stopped"

  echo "stopping" >"${MIGRATION_STATE}"
  echo "host=${HOST}" >>"${MIGRATION_STATE}"

  log_info "stopping migrated services on ${HOST}..."
  ssh "${HOST}" "cd ${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}} && docker compose stop postgres redis portainer uptime-kuma" \
    || die "couldn't stop source containers — aborting, treat them as still running"
  echo "stopped" >>"${MIGRATION_STATE}"

  log_info "running the final sync pass..."
  DRY_RUN=0 do_sync

  log_info "checking checksums..."
  local mismatch=0
  local verified_summary=""

  if [[ "${DO_PROJECTS}" -eq 1 ]]; then
    local src_projects dst_projects
    src_projects="$(remote_projects_dir)"
    dst_projects="${PROJECTS_DIR:-/opt/forgeops/projects}"
    local src_sum dst_sum
    src_sum="$(ssh "${HOST}" "find '${src_projects}' -type f -exec sha256sum {} \; | sort" | sha256sum | cut -d' ' -f1)"
    dst_sum="$(find "${dst_projects}" -type f -exec sha256sum {} \; | sort | sha256sum | cut -d' ' -f1)"
    if [[ "${src_sum}" != "${dst_sum}" ]]; then
      log_error "checksum mismatch for projects: source=${src_sum} dest=${dst_sum}"
      mismatch=1
    else
      verified_summary+="projects "
    fi
  fi

  # --volumes is required above, and do_sync just wrote a status line per
  # volume. Every volume actually present on the source needs to have come
  # back OK — a FAILED line stops the whole finalize.
  local status_file="${LOG_DIR}/.migrate-volume-status"
  local ok_volumes=() failed_volumes=() skipped_volumes=()
  if [[ -f "${status_file}" ]]; then
    while IFS=: read -r vol result _detail; do
      case "${result}" in
        OK) ok_volumes+=("${vol}") ;;
        FAILED) failed_volumes+=("${vol}"); mismatch=1 ;;
        SKIPPED) skipped_volumes+=("${vol}") ;;
      esac
    done <"${status_file}"
  else
    mismatch=1
    log_error "no volume status file at ${status_file} — the sync pass didn't record anything"
  fi

  if (( ${#ok_volumes[@]} == 0 )); then
    log_error "zero volumes verified OK — refusing to call this finalized"
    mismatch=1
  else
    verified_summary+="volumes:[${ok_volumes[*]}] "
  fi
  (( ${#skipped_volumes[@]} > 0 )) && log_warn "volumes skipped (not on source): ${skipped_volumes[*]}"
  (( ${#failed_volumes[@]} > 0 )) && log_error "volumes that failed: ${failed_volumes[*]}"

  if [[ "${mismatch}" -eq 1 ]]; then
    echo "verify_failed" >>"${MIGRATION_STATE}"
    die "verification failed — destination not started, source still stopped. Run './migrate.sh --host ${HOST} --rollback' to bring it back, fix the mismatch, retry."
  fi
  log_ok "checksums verified (${verified_summary})"
  echo "verified" >>"${MIGRATION_STATE}"

  log_info "starting the destination stack..."
  cd "${REPO_ROOT}"
  docker compose up -d postgres redis portainer uptime-kuma \
    || die "destination containers failed to start after verification passed — source is still stopped, run './migrate.sh --host ${HOST} --rollback' while you debug this"

  echo "finalized" >>"${MIGRATION_STATE}"
  log_ok "finalize done, destination is live. Source stays stopped (not deleted) — decommission it yourself once you trust the destination."
}

# --- --rollback: restart what --finalize stopped -----------------------------
do_rollback() {
  [[ -f "${MIGRATION_STATE}" ]] || die "no migration state at ${MIGRATION_STATE} — nothing to roll back"
  local host
  host="$(grep '^host=' "${MIGRATION_STATE}" | cut -d= -f2-)"
  [[ -n "${host}" ]] || die "state file has no recorded host"

  log_warn "restarting migrated services on ${host}..."
  ssh "${host}" "cd ${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}} && docker compose start postgres redis portainer uptime-kuma" \
    || die "couldn't restart source containers over SSH — log in and run 'docker compose start postgres redis portainer uptime-kuma' yourself"

  echo "rolled_back" >>"${MIGRATION_STATE}"
  log_ok "source restarted. If the destination is also running, stop it so you don't end up with two live copies."
}

case "${MODE}" in
  sync) do_sync ;;
  finalize) do_finalize ;;
  rollback) do_rollback ;;
esac
