#!/usr/bin/env bash
# Removes what install.sh set up.
#
# "Components" = packages, containers, images, systemd units, Caddy config,
# UFW rules, installed binaries. "User data" = anything a component stored
# for you: Postgres/Redis volumes, backups/, logs/, PROJECTS_DIR.
#
# Removes components only by default. User data needs --purge-data plus a
# typed confirmation (or --yes for scripted teardown).
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
    *) die "unknown argument: ${arg}" ;;
  esac
done

[[ "${DRY_RUN}" -eq 1 ]] || require_root

PROJECTS_DIR="/opt/forgeops/projects"
[[ -f "${ENV_FILE}" ]] && PROJECTS_DIR="$(grep -E '^PROJECTS_DIR=' "${ENV_FILE}" | cut -d= -f2- || echo "${PROJECTS_DIR}")"

# Same default as .env.example / step_install_wireguard's `ufw allow
# "${WG_PORT:-51820}/udp"` — needed here so `ufw delete` targets the exact
# rule that was actually added, even if WG_PORT was customized.
WG_PORT="51820"
[[ -f "${ENV_FILE}" ]] && WG_PORT="$(grep -E '^WG_PORT=' "${ENV_FILE}" | cut -d= -f2- || echo "${WG_PORT}")"

DATA_VOLUMES=(forgeops_postgres_data forgeops_redis_data forgeops_portainer_data forgeops_uptime_kuma_data forgeops_caddy_data forgeops_caddy_config forgeops_wireguard_config forgeops_prometheus_data forgeops_grafana_data)
DATA_DIRS=("${REPO_ROOT}/backups" "${REPO_ROOT}/logs" "${PROJECTS_DIR}")

echo ""
echo "The following COMPONENTS will be removed:"
echo "  - docker compose stack (containers): caddy, portainer, postgres, redis, uptime-kuma, watchtower,"
echo "    wireguard, cadvisor, prometheus, grafana, mcp-filesystem, mcp-git, mcp-gateway, mcp-postgres"
echo "  - Docker images pinned in configs/versions.env (incl. WireGuard/wg-easy, cAdvisor, Prometheus,"
echo "    Grafana, postgres-mcp) + the locally-built mcp-filesystem/mcp-git bridge images"
echo "  - Docker networks: forgeops_edge, forgeops_internal"
echo "  - UFW rules added by install.sh (80/tcp, 443/tcp, 443/udp, ${WG_PORT}/udp for WireGuard)"
echo "  - Fail2Ban jails: forgeops-sshd.local, forgeops-caddy.local (+ its filter),"
echo "    forgeops-mcp-auth.local (+ its filter), forgeops-wg-abuse.local (+ its filter, ships disabled)"
echo "  - logrotate config: /etc/logrotate.d/forgeops"
echo "  - systemd units: forgeops-backup.timer, forgeops-backup.service"
echo ""

if [[ "${PURGE_DATA}" -eq 1 ]]; then
  echo "Because --purge-data was passed, the following USER DATA will ALSO be PERMANENTLY DELETED:"
  echo "  Docker volumes:"
  for v in "${DATA_VOLUMES[@]}"; do echo "    - ${v}"; done
  echo "  Directories:"
  for d in "${DATA_DIRS[@]}"; do echo "    - ${d}"; done
  echo ""
else
  echo "User data (Postgres/Redis/Portainer/Uptime Kuma/WireGuard/Prometheus/Grafana volumes, backups/, logs/, ${PROJECTS_DIR}) will be LEFT UNTOUCHED."
  echo "Pass --purge-data to also delete it."
  echo ""
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "dry run — nothing removed"
  exit 0
fi

if [[ "${PURGE_DATA}" -eq 1 && "${ASSUME_YES}" -eq 0 ]]; then
  read -r -p "Type 'delete my data' to confirm permanent deletion of everything listed above: " confirm
  [[ "${confirm}" == "delete my data" ]] || die "confirmation text didn't match — nothing deleted"
fi

cd "${REPO_ROOT}"
log_info "stopping and removing containers/networks..."
# --profile ondemand, otherwise `down` can miss a leftover watchtower
# container from an interrupted `docker compose run`.
docker compose --profile ondemand down --remove-orphans || log_warn "docker compose down complained, continuing anyway"

log_info "removing pinned images..."
if [[ -r "${VERSIONS_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${VERSIONS_FILE}"
  for img in "${CADDY_IMAGE:-}" "${PORTAINER_IMAGE:-}" "${POSTGRES_IMAGE:-}" "${REDIS_IMAGE:-}" "${UPTIME_KUMA_IMAGE:-}" "${WATCHTOWER_IMAGE:-}" \
             "${WGEASY_IMAGE:-}" "${CADVISOR_IMAGE:-}" "${PROMETHEUS_IMAGE:-}" "${GRAFANA_IMAGE:-}" "${POSTGRES_MCP_IMAGE:-}"; do
    if [[ -n "${img}" ]]; then
      docker image rm "${img}" >/dev/null 2>&1 || true
    fi
  done
fi

# mcp-filesystem/mcp-git have no `image:` in docker-compose.yml — they're
# built locally from docker/mcp-stdio-bridge (see configs/versions.env's
# PYTHON_BASE_IMAGE/MCP_PROXY_VERSION/MCP_*_SERVER_VERSION), so there's no
# fixed image name/tag to look up here the way the pulled images above have.
# Ask compose itself for whatever it tagged them as, instead of guessing the
# `<project>-<service>` naming convention.
log_info "removing locally-built MCP bridge images (mcp-filesystem, mcp-git)..."
if command_exists docker && [[ -f "${REPO_ROOT}/docker-compose.yml" ]]; then
  while IFS= read -r img_id; do
    if [[ -n "${img_id}" ]]; then
      docker image rm "${img_id}" >/dev/null 2>&1 || true
    fi
  done < <(cd "${REPO_ROOT}" && docker compose images -q mcp-filesystem mcp-git 2>/dev/null | sort -u)
fi

log_info "removing UFW rules..."
ufw delete allow 80/tcp >/dev/null 2>&1 || true
ufw delete allow 443/tcp >/dev/null 2>&1 || true
ufw delete allow 443/udp >/dev/null 2>&1 || true
# Mirrors step_install_wireguard's `ufw allow "${WG_PORT:-51820}/udp"`
# (scripts/lib/install_steps.sh) — same rule, same port var, deleted here.
ufw delete allow "${WG_PORT}/udp" >/dev/null 2>&1 || true

log_info "removing fail2ban jails and logrotate config..."
rm -f /etc/fail2ban/jail.d/forgeops-sshd.local /etc/fail2ban/jail.d/forgeops-caddy.local /etc/fail2ban/filter.d/forgeops-caddy-auth.conf
# forgeops-mcp-auth + forgeops-wg-abuse: added by step_install_mcp_gateway
# and step_install_wireguard respectively (scripts/lib/install_steps.sh) —
# same jail.d/filter.d file pairing as the sshd/caddy jails just above.
rm -f /etc/fail2ban/jail.d/forgeops-mcp-auth.local /etc/fail2ban/filter.d/forgeops-mcp-auth.conf
rm -f /etc/fail2ban/jail.d/forgeops-wg-abuse.local /etc/fail2ban/filter.d/forgeops-wg-abuse.conf
systemctl restart fail2ban 2>/dev/null || true
rm -f /etc/logrotate.d/forgeops

log_info "removing backup systemd units..."
systemctl disable --now forgeops-backup.timer 2>/dev/null || true
rm -f /etc/systemd/system/forgeops-backup.timer /etc/systemd/system/forgeops-backup.service
systemctl daemon-reload 2>/dev/null || true

if [[ "${PURGE_DATA}" -eq 1 ]]; then
  log_warn "purging user data as confirmed..."
  for v in "${DATA_VOLUMES[@]}"; do
    docker volume rm "${v}" >/dev/null 2>&1 || log_warn "couldn't remove volume ${v} (may not exist)"
  done
  for d in "${DATA_DIRS[@]}"; do
    [[ -d "${d}" ]] && rm -rf "${d}"
  done
  log_ok "user data purged"
fi

log_ok "uninstall complete — .env and the repo itself were left in place, delete the directory yourself if you're done with it"
