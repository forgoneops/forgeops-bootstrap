#!/usr/bin/env bash
# migrate.sh - migrates an existing Linux VPS into this ForgeOps Bootstrap
# environment over SSH.
#
# Two-phase safety model (see MIGRATION.md for full detail):
#   --sync      Repeatable, non-destructive. Copies data from the source host
#               to this (destination) host while source services keep running.
#               Run it as many times as you like to converge the destination.
#   --finalize  One-time cutover. Stops only the migrated containers on the
#               source, does one last --sync delta pass, verifies checksums,
#               and only then starts services on the destination. If
#               verification fails, it aborts BEFORE starting destination
#               services and leaves the source stopped-but-intact.
#   --rollback  Restarts the containers that --finalize stopped on the
#               source, for use if something goes wrong after finalize.
#
# The source host's data is never modified. --finalize only ever stops
# containers on the source (via SSH) — it does not delete or alter files
# there, so the source remains a valid rollback target until you decide to
# decommission it yourself.
#
# Usage:
#   ./migrate.sh --host user@source-host --sync   [targets...] [--dry-run] [--verbose]
#   ./migrate.sh --host user@source-host --finalize [targets...] [--verbose]
#   ./migrate.sh --host user@source-host --rollback
#
# Targets (choose any combination; default = --projects --claude-config --docker-config):
#   --projects        sync ${PROJECTS_DIR}
#   --claude-config    sync ~/.claude on the source
#   --docker-config    sync docker-compose files + docker/ + configs/ from the source repo path
#   --ssh-config       sync ~/.ssh (optional; keys are copied, not regenerated)
#   --volumes          sync named Docker volumes (postgres, redis, portainer, uptime-kuma data)

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
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ "${VERBOSE}" -eq 1 ]] && RSYNC_FLAGS+=(-v)
[[ "${DRY_RUN}" -eq 1 ]] && RSYNC_FLAGS+=(--dry-run)

[[ -n "${MODE}" ]] || die "Specify one of --sync, --finalize, --rollback (see --help)."

if [[ "${MODE}" != "rollback" && "${ANY_TARGET_SET}" -eq 0 ]]; then
  DO_PROJECTS=1; DO_CLAUDE=1; DO_DOCKER=1
  log_info "No targets specified — defaulting to --projects --claude-config --docker-config."
fi

if [[ "${MODE}" != "rollback" ]]; then
  [[ -n "${HOST}" ]] || die "--host user@source-host is required."
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${HOST}" 'true' \
    || die "Cannot reach ${HOST} over SSH with key-based auth. Fix connectivity/auth before migrating."
fi

remote_projects_dir() {
  # Must read the source's PROJECTS_DIR from its ForgeOps repo's .env, not
  # from $HOME/.env (which is almost never where it lives) — see AUDIT.md
  # MIG-1. Every other remote lookup in this script already uses
  # SOURCE_REPO_PATH; this one had been missed.
  local repo_path="${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}}"
  ssh "${HOST}" "test -f '${repo_path}/.env' && grep -E '^PROJECTS_DIR=' '${repo_path}/.env' | cut -d= -f2- || echo /opt/forgeops/projects"
}

# ---------------------------------------------------------------------------
# --sync : repeatable, non-destructive
# ---------------------------------------------------------------------------
do_sync() {
  mkdir -p "${REPO_ROOT}/backups/migrate-manifests"

  if [[ "${DO_PROJECTS}" -eq 1 ]]; then
    local src_projects
    src_projects="$(remote_projects_dir)"
    local dst_projects="${PROJECTS_DIR:-/opt/forgeops/projects}"
    mkdir -p "${dst_projects}"
    log_info "Syncing projects: ${HOST}:${src_projects}/ -> ${dst_projects}/"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_projects}/" "${dst_projects}/"
  fi

  if [[ "${DO_CLAUDE}" -eq 1 ]]; then
    log_info "Syncing Claude configuration: ${HOST}:~/.claude/ -> ${HOME}/.claude/"
    mkdir -p "${HOME}/.claude"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:.claude/" "${HOME}/.claude/" 2>/dev/null \
      || log_warn "No ~/.claude found on ${HOST} — skipping."
  fi

  if [[ "${DO_DOCKER}" -eq 1 ]]; then
    local src_repo="${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}}"
    log_info "Syncing Docker configuration: ${HOST}:${src_repo}/{docker,configs,docker-compose.yml} -> ${REPO_ROOT}/"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_repo}/docker/" "${REPO_ROOT}/docker/" 2>/dev/null || true
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_repo}/configs/" "${REPO_ROOT}/configs/" 2>/dev/null || true
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:${src_repo}/docker-compose.yml" "${REPO_ROOT}/docker-compose.yml.from-source" 2>/dev/null \
      && log_warn "Source docker-compose.yml saved as docker-compose.yml.from-source for manual review/merge — not auto-applied."
  fi

  if [[ "${DO_SSH}" -eq 1 ]]; then
    log_info "Syncing SSH configuration: ${HOST}:~/.ssh/ -> ${HOME}/.ssh/"
    mkdir -p "${HOME}/.ssh"
    rsync "${RSYNC_FLAGS[@]}" -e ssh "${HOST}:.ssh/" "${HOME}/.ssh/" 2>/dev/null || log_warn "No ~/.ssh found on ${HOST} — skipping."
    [[ "${DRY_RUN}" -eq 0 ]] && chmod 700 "${HOME}/.ssh" && find "${HOME}/.ssh" -type f -exec chmod 600 {} \;
  fi

  if [[ "${DO_VOLUMES}" -eq 1 ]]; then
    # Fresh status file every do_sync call: one line per volume, OK/FAILED/
    # SKIPPED, so do_finalize can tell real verification from a no-op (see
    # AUDIT.md MIG-2/MIG-3 — previously a failed scp/tar was logged as
    # success, and volumes were never checksummed at all).
    local status_file="${LOG_DIR}/.migrate-volume-status"
    : >"${status_file}"
    for vol in postgres redis portainer uptime_kuma; do
      log_info "Syncing Docker volume data for ${vol} (live snapshot; source containers keep running)..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[dry-run] would tar forgeops_${vol}_data on ${HOST}, transfer, checksum-verify, and extract into forgeops_${vol}_data here"
        continue
      fi

      local remote_sha
      remote_sha="$(ssh "${HOST}" "docker run --rm -v forgeops_${vol}_data:/from -v /tmp:/to alpine sh -c 'tar czf /to/forgeops_${vol}_data.tar.gz -C /from . && sha256sum /to/forgeops_${vol}_data.tar.gz'" 2>/dev/null | awk '{print $1}')"
      if [[ -z "${remote_sha}" ]]; then
        log_warn "Volume forgeops_${vol}_data not found on source (or remote tar failed) — skipping."
        echo "${vol}:SKIPPED:not present or tar failed on source" >>"${status_file}"
        continue
      fi

      if ! scp -q "${HOST}:/tmp/forgeops_${vol}_data.tar.gz" "${LOG_DIR}/"; then
        log_error "scp failed for forgeops_${vol}_data.tar.gz — volume NOT synced."
        echo "${vol}:FAILED:scp transfer failed" >>"${status_file}"
        ssh "${HOST}" "rm -f /tmp/forgeops_${vol}_data.tar.gz" 2>/dev/null || true
        continue
      fi
      ssh "${HOST}" "rm -f /tmp/forgeops_${vol}_data.tar.gz" 2>/dev/null || true

      local local_sha
      local_sha="$(sha256sum "${LOG_DIR}/forgeops_${vol}_data.tar.gz" 2>/dev/null | awk '{print $1}')"
      if [[ "${local_sha}" != "${remote_sha}" ]]; then
        log_error "Checksum mismatch for forgeops_${vol}_data.tar.gz (remote=${remote_sha} local=${local_sha:-<missing>}) — volume NOT synced. Archive kept at ${LOG_DIR}/forgeops_${vol}_data.tar.gz for inspection."
        echo "${vol}:FAILED:checksum mismatch after transfer" >>"${status_file}"
        continue
      fi

      docker volume create "forgeops_${vol}_data" >/dev/null
      if ! docker run --rm -v "forgeops_${vol}_data:/to" -v "${LOG_DIR}:/from" alpine \
          sh -c "tar xzf /from/forgeops_${vol}_data.tar.gz -C /to"; then
        log_error "Extraction failed for forgeops_${vol}_data — volume NOT synced."
        echo "${vol}:FAILED:local extraction failed" >>"${status_file}"
        rm -f "${LOG_DIR}/forgeops_${vol}_data.tar.gz"
        continue
      fi
      rm -f "${LOG_DIR}/forgeops_${vol}_data.tar.gz"
      echo "${vol}:OK:${local_sha}" >>"${status_file}"
      log_ok "Volume forgeops_${vol}_data synced and checksum-verified (sha256=${local_sha:0:12}...) — live snapshot, see --finalize for a consistent final copy."
    done
  fi

  log_ok "Sync pass complete. Re-run --sync any time to converge further; nothing on ${HOST} was modified."
}

# ---------------------------------------------------------------------------
# --finalize : one-time cutover with checksummed verification
# ---------------------------------------------------------------------------
do_finalize() {
  [[ "${DO_VOLUMES}" -eq 1 ]] || die "--finalize requires --volumes so the final consistent snapshot includes stopped-container data. Re-run with --volumes."

  log_warn "FINALIZE: this will stop containers on ${HOST} for a final consistent sync. The destination stack will NOT start until checksums verify."
  read -r -p "Type 'finalize' to proceed: " confirm
  [[ "${confirm}" == "finalize" ]] || die "Confirmation did not match — aborting. Nothing was stopped."

  echo "stopping" >"${MIGRATION_STATE}"
  echo "host=${HOST}" >>"${MIGRATION_STATE}"

  log_info "Stopping migrated services on source (${HOST})..."
  ssh "${HOST}" "cd ${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}} && docker compose stop postgres redis portainer uptime-kuma" \
    || die "Failed to stop source containers — aborting finalize. Source services were NOT confirmed stopped; treat as still running."
  echo "stopped" >>"${MIGRATION_STATE}"

  log_info "Running final delta sync pass..."
  DRY_RUN=0 do_sync

  log_info "Verifying checksums between source and destination..."
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
      log_error "Checksum mismatch for projects: source=${src_sum} dest=${dst_sum}"
      mismatch=1
    else
      verified_summary+="projects "
    fi
  fi

  # --volumes is mandatory for --finalize (checked at the top of this
  # function) — its per-volume status was written by the do_sync call above.
  # Previously this block never inspected volume results at all, so a
  # `--finalize --volumes` run with no --projects would print "verified"
  # having checked nothing (AUDIT.md MIG-2). Every volume present on the
  # source must have synced OK; a FAILED line is a hard stop.
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
    log_error "No volume status file found at ${status_file} — the final sync pass did not record any volume results."
  fi

  if (( ${#ok_volumes[@]} == 0 )); then
    log_error "Zero volumes verified OK (source may have had none running, or every transfer failed) — refusing to treat this as a verified finalize."
    mismatch=1
  else
    verified_summary+="volumes:[${ok_volumes[*]}] "
  fi
  (( ${#skipped_volumes[@]} > 0 )) && log_warn "Volumes skipped (not present on source): ${skipped_volumes[*]}"
  (( ${#failed_volumes[@]} > 0 )) && log_error "Volumes that FAILED to sync/verify: ${failed_volumes[*]}"

  if [[ "${mismatch}" -eq 1 ]]; then
    echo "verify_failed" >>"${MIGRATION_STATE}"
    die "Checksum verification FAILED. Destination services were NOT started. Source containers remain stopped — run './migrate.sh --host ${HOST} --rollback' to restart them, then investigate the mismatch before retrying."
  fi
  log_ok "Checksums verified — source and destination match (${verified_summary})."
  echo "verified" >>"${MIGRATION_STATE}"

  log_info "Starting destination stack..."
  cd "${REPO_ROOT}"
  docker compose up -d postgres redis portainer uptime-kuma \
    || die "Destination containers failed to start after verification passed. Source is still stopped — run './migrate.sh --host ${HOST} --rollback' to restart it while you debug the destination."

  echo "finalized" >>"${MIGRATION_STATE}"
  log_ok "Finalize complete. Destination is live. Source containers remain stopped (not deleted) — decommission the source host manually once you've confirmed the destination is healthy."
}

# ---------------------------------------------------------------------------
# --rollback : restart what --finalize stopped on the source
# ---------------------------------------------------------------------------
do_rollback() {
  [[ -f "${MIGRATION_STATE}" ]] || die "No migration state found at ${MIGRATION_STATE} — nothing to roll back."
  local host
  host="$(grep '^host=' "${MIGRATION_STATE}" | cut -d= -f2-)"
  [[ -n "${host}" ]] || die "Migration state file exists but has no recorded host."

  log_warn "Restarting migrated services on source (${host})..."
  ssh "${host}" "cd ${SOURCE_REPO_PATH:-${SOURCE_REPO_PATH_DEFAULT}} && docker compose start postgres redis portainer uptime-kuma" \
    || die "Failed to restart source containers via SSH. Log into ${host} manually and run 'docker compose start postgres redis portainer uptime-kuma'."

  echo "rolled_back" >>"${MIGRATION_STATE}"
  log_ok "Source services restarted. If the destination stack is also running, stop it manually to avoid two live copies of the same data."
}

case "${MODE}" in
  sync) do_sync ;;
  finalize) do_finalize ;;
  rollback) do_rollback ;;
esac
