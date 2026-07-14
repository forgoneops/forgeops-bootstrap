#!/usr/bin/env bash
# update.sh - safely updates the complete ForgeOps Bootstrap infrastructure.
#
# Moves every component to exactly the version declared in
# configs/versions.env — never to upstream "latest". Aborts on any critical
# failure and leaves the previously-working versions running (no
# partially-updated state is left active).
#
# Usage:
#   sudo ./update.sh

set -uo pipefail   # no -e: we need to control abort/rollback ourselves

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

for arg in "$@"; do
  case "${arg}" in
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

require_root
load_versions
[[ -f "${ENV_FILE}" ]] || die "No .env found — run install.sh first."

log_info "Starting update run. Log: ${RUN_LOG}"

# --- 1. Snapshot currently-running image digests, for rollback reference ----
PREV_IMAGES_SNAPSHOT="${LOG_DIR}/pre-update-images-$(date -u +%Y%m%dT%H%M%SZ).txt"
docker compose -f "${REPO_ROOT}/docker-compose.yml" images >"${PREV_IMAGES_SNAPSHOT}" 2>/dev/null || true
log_info "Pre-update image snapshot saved: ${PREV_IMAGES_SNAPSHOT}"

# --- 2. Update Ubuntu packages (security patches only) ----------------------
if ! apt-get update -y; then
  die "apt-get update failed — aborting before touching running services."
fi
if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
  die "apt-get upgrade failed — aborting before touching running services. Ubuntu packages are unchanged from before this run; Docker services were never touched."
fi
log_ok "Ubuntu packages updated."

# --- 3. Pull pinned images and re-render Caddyfile ---------------------------
cd "${REPO_ROOT}"
bash "${REPO_ROOT}/scripts/render_caddyfile.sh"

PULL_OK=1
for img in "${CADDY_IMAGE}" "${PORTAINER_IMAGE}" "${POSTGRES_IMAGE}" "${REDIS_IMAGE}" "${UPTIME_KUMA_IMAGE}" "${WATCHTOWER_IMAGE}"; do
  if ! docker pull "${img}"; then
    log_error "Failed to pull ${img}"
    PULL_OK=0
  fi
done
if [[ "${PULL_OK}" -eq 0 ]]; then
  die "One or more pinned images failed to pull — aborting before restarting anything. Currently-running containers are untouched."
fi
log_ok "All pinned images pulled successfully."

# --- 4. Recreate containers at the pinned versions ---------------------------
if ! CADDY_IMAGE="${CADDY_IMAGE}" PORTAINER_IMAGE="${PORTAINER_IMAGE}" \
    POSTGRES_IMAGE="${POSTGRES_IMAGE}" REDIS_IMAGE="${REDIS_IMAGE}" \
    UPTIME_KUMA_IMAGE="${UPTIME_KUMA_IMAGE}" WATCHTOWER_IMAGE="${WATCHTOWER_IMAGE}" \
    docker compose up -d --force-recreate caddy portainer postgres redis uptime-kuma; then
  die "docker compose up failed during recreate. Check 'docker compose ps' and container logs; the pre-update image snapshot is at ${PREV_IMAGES_SNAPSHOT} for manual rollback (docker compose up -d with the prior tags)."
fi
log_ok "Containers recreated at pinned versions."

# --- 5. Run watchtower once to clean up any dangling images from the recreate
# --profile ondemand is required: watchtower is profile-gated in
# docker-compose.yml specifically so a bare `up -d` never starts it (see
# AUDIT.md DOCKER-2) — `docker compose run` also respects profile gating.
# No extra args passed to `run`: they would override (not append to) the
# service's declared `command:`, silently dropping --no-startup-message
# (see AUDIT.md SC-1) — relying on the compose file's own command instead.
docker compose --profile ondemand run --rm watchtower >/dev/null 2>&1 || true

# --- 6. Prune unused Docker resources ------------------------------------------
docker image prune -f >/dev/null
docker container prune -f >/dev/null
log_ok "Unused Docker resources removed."

# --- 7. Clean apt package cache -----------------------------------------------
apt-get clean
log_ok "apt package cache cleaned."

# --- 8. Rotate logs now (in addition to the scheduled weekly logrotate) -----
logrotate -f /etc/logrotate.d/forgeops 2>/dev/null || log_warn "logrotate config not found — run install.sh to configure it."

# --- 9. Verify all services (final gate) --------------------------------------
if ! bash "${REPO_ROOT}/verify.sh"; then
  die "Post-update verify.sh reported failures. Services are running at the new pinned versions but are NOT healthy — inspect logs/verify-report.md immediately. Manual rollback: docker compose up -d with the tags recorded in ${PREV_IMAGES_SNAPSHOT}."
fi

log_ok "Update complete — all services verified healthy at the versions pinned in configs/versions.env."
