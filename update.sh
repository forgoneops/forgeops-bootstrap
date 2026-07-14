#!/usr/bin/env bash
# Updates everything to the versions pinned in configs/versions.env — never
# to upstream "latest". Bails on any real failure and leaves whatever was
# already running in place, instead of leaving things half-upgraded.
#
# Usage:
#   sudo ./update.sh

set -uo pipefail   # no -e: we handle failure/abort ourselves below

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

for arg in "$@"; do
  case "${arg}" in
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

require_root
load_versions
[[ -f "${ENV_FILE}" ]] || die "no .env found — run install.sh first"

log_info "starting update. log: ${RUN_LOG}"

# 1. Snapshot what's currently running, in case we need to roll back by hand.
PREV_IMAGES_SNAPSHOT="${LOG_DIR}/pre-update-images-$(date -u +%Y%m%dT%H%M%SZ).txt"
docker compose -f "${REPO_ROOT}/docker-compose.yml" images >"${PREV_IMAGES_SNAPSHOT}" 2>/dev/null || true
log_info "pre-update image snapshot: ${PREV_IMAGES_SNAPSHOT}"

# 2. Ubuntu security patches.
if ! apt-get update -y; then
  die "apt-get update failed — stopping before touching anything running"
fi
if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
  die "apt-get upgrade failed — Ubuntu packages unchanged, Docker services untouched"
fi
log_ok "Ubuntu packages updated"

# 3. Pull pinned images, re-render the Caddyfile in case DOMAIN/EXPOSE_* changed.
cd "${REPO_ROOT}"
bash "${REPO_ROOT}/scripts/render_caddyfile.sh"

PULL_OK=1
for img in "${CADDY_IMAGE}" "${PORTAINER_IMAGE}" "${POSTGRES_IMAGE}" "${REDIS_IMAGE}" "${UPTIME_KUMA_IMAGE}" "${WATCHTOWER_IMAGE}"; do
  if ! docker pull "${img}"; then
    log_error "failed to pull ${img}"
    PULL_OK=0
  fi
done
if [[ "${PULL_OK}" -eq 0 ]]; then
  die "one or more images failed to pull — nothing running was touched"
fi
log_ok "all pinned images pulled"

# 4. Recreate at the pinned versions.
if ! CADDY_IMAGE="${CADDY_IMAGE}" PORTAINER_IMAGE="${PORTAINER_IMAGE}" \
    POSTGRES_IMAGE="${POSTGRES_IMAGE}" REDIS_IMAGE="${REDIS_IMAGE}" \
    UPTIME_KUMA_IMAGE="${UPTIME_KUMA_IMAGE}" WATCHTOWER_IMAGE="${WATCHTOWER_IMAGE}" \
    docker compose up -d --force-recreate caddy portainer postgres redis uptime-kuma; then
  die "docker compose up failed during recreate — check 'docker compose ps' and container logs. Manual rollback: docker compose up -d with the tags in ${PREV_IMAGES_SNAPSHOT}"
fi
log_ok "containers recreated at pinned versions"

# 5. Clean up dangling images from the recreate. Watchtower is profile-gated
# (see docker-compose.yml) so `up -d` never starts it on its own — this is
# the only place it actually runs. No extra args to `run`: they'd replace
# the command declared in the compose file instead of adding to it.
docker compose --profile ondemand run --rm watchtower >/dev/null 2>&1 || true

# 6. Prune what's no longer needed.
docker image prune -f >/dev/null
docker container prune -f >/dev/null
log_ok "unused Docker resources removed"

# 7. apt cache.
apt-get clean
log_ok "apt cache cleaned"

# 8. Rotate logs now too, not just on the weekly schedule.
logrotate -f /etc/logrotate.d/forgeops 2>/dev/null || log_warn "logrotate config missing — run install.sh"

# 9. Final gate: confirm everything's actually healthy.
if ! bash "${REPO_ROOT}/verify.sh"; then
  die "post-update verify.sh found problems — services are on the new versions but not healthy, check logs/verify-report.md now. Manual rollback: docker compose up -d with the tags in ${PREV_IMAGES_SNAPSHOT}"
fi

log_ok "update complete, everything healthy at the pinned versions"
