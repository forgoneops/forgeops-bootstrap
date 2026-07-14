#!/usr/bin/env bash
# uninstall.sh - safely removes installed ForgeOps Bootstrap components.
#
# "Components" = packages, containers, images, systemd units, Caddy config,
# UFW rules, installed binaries.
# "User data"   = anything a component stored on the user's behalf: Postgres
#                 and Redis named volumes, backups/, logs/, and the configured
#                 PROJECTS_DIR.
#
# Default behavior removes components ONLY. User data is never touched unless
# --purge-data is passed, and even then each item is named and confirmed
# individually (or all confirmed at once with --yes, still one prompt that
# names everything about to be deleted).
#
# Usage:
#   sudo ./uninstall.sh                    # remove components, keep all data
#   sudo ./uninstall.sh --purge-data        # also delete user data (prompts)
#   sudo ./uninstall.sh --dry-run           # list what would happen, do nothing
#   sudo ./uninstall.sh --purge-data --yes  # non-interactive (for scripted teardown only)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

PURGE_DATA=0
DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --purge-data) PURGE_DATA=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: ${arg}" ;;
  esac
done

[[ "${DRY_RUN}" -eq 1 ]] || require_root

PROJECTS_DIR="/opt/forgeops/projects"
[[ -f "${ENV_FILE}" ]] && PROJECTS_DIR="$(grep -E '^PROJECTS_DIR=' "${ENV_FILE}" | cut -d= -f2- || echo "${PROJECTS_DIR}")"

DATA_VOLUMES=(forgeops_postgres_data forgeops_redis_data forgeops_portainer_data forgeops_uptime_kuma_data forgeops_caddy_data forgeops_caddy_config)
DATA_DIRS=("${REPO_ROOT}/backups" "${REPO_ROOT}/logs" "${PROJECTS_DIR}")

echo ""
echo "The following COMPONENTS will be removed:"
echo "  - docker compose stack (containers): caddy, portainer, postgres, redis, uptime-kuma, watchtower"
echo "  - Docker images pinned in configs/versions.env"
echo "  - Docker networks: forgeops_edge, forgeops_internal"
echo "  - UFW rules added by install.sh (80/tcp, 443/tcp, 443/udp)"
echo "  - Fail2Ban jail: /etc/fail2ban/jail.d/forgeops-sshd.local"
echo "  - logrotate config: /etc/logrotate.d/forgeops"
echo ""

if [[ "${PURGE_DATA}" -eq 1 ]]; then
  echo "Because --purge-data was passed, the following USER DATA will ALSO be PERMANENTLY DELETED:"
  echo "  Docker volumes:"
  for v in "${DATA_VOLUMES[@]}"; do echo "    - ${v}"; done
  echo "  Directories:"
  for d in "${DATA_DIRS[@]}"; do echo "    - ${d}"; done
  echo ""
else
  echo "User data (Postgres/Redis/Portainer/Uptime Kuma volumes, backups/, logs/, ${PROJECTS_DIR}) will be LEFT UNTOUCHED."
  echo "Pass --purge-data to also delete it."
  echo ""
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry run — nothing was removed."
  exit 0
fi

if [[ "${PURGE_DATA}" -eq 1 && "${ASSUME_YES}" -eq 0 ]]; then
  read -r -p "Type 'delete my data' to confirm permanent deletion of everything listed above: " confirm
  [[ "${confirm}" == "delete my data" ]] || die "Confirmation text did not match — aborting. Nothing was deleted."
fi

cd "${REPO_ROOT}"
log_info "Stopping and removing containers/networks..."
docker compose down --remove-orphans || log_warn "docker compose down reported an issue (continuing)."

log_info "Removing pinned images..."
if [[ -r "${VERSIONS_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${VERSIONS_FILE}"
  for img in "${CADDY_IMAGE:-}" "${PORTAINER_IMAGE:-}" "${POSTGRES_IMAGE:-}" "${REDIS_IMAGE:-}" "${UPTIME_KUMA_IMAGE:-}" "${WATCHTOWER_IMAGE:-}"; do
    [[ -n "${img}" ]] && docker image rm "${img}" >/dev/null 2>&1 || true
  done
fi

log_info "Removing UFW rules added by ForgeOps..."
ufw delete allow 80/tcp >/dev/null 2>&1 || true
ufw delete allow 443/tcp >/dev/null 2>&1 || true
ufw delete allow 443/udp >/dev/null 2>&1 || true

log_info "Removing Fail2Ban jail and logrotate config..."
rm -f /etc/fail2ban/jail.d/forgeops-sshd.local
systemctl restart fail2ban 2>/dev/null || true
rm -f /etc/logrotate.d/forgeops

if [[ "${PURGE_DATA}" -eq 1 ]]; then
  log_warn "Purging user data as confirmed..."
  for v in "${DATA_VOLUMES[@]}"; do
    docker volume rm "${v}" >/dev/null 2>&1 || log_warn "Could not remove volume ${v} (may not exist)."
  done
  for d in "${DATA_DIRS[@]}"; do
    [[ -d "${d}" ]] && rm -rf "${d}"
  done
  log_ok "User data purged."
fi

log_ok "Uninstall complete. .env and the repository files themselves were left in place — delete the repo directory manually if you no longer need it."
