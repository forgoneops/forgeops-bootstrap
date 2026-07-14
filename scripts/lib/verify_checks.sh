#!/usr/bin/env bash
# verify_checks.sh - one check function per verify.sh row.
# Each function prints exactly one line: "STATUS|detail"
# STATUS is one of PASS, WARN, FAIL. Sourced by verify.sh.

set -uo pipefail   # deliberately no -e: a failing check must not kill verify.sh

check_operating_system() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
      echo "PASS|${PRETTY_NAME}"
    else
      echo "WARN|${PRETTY_NAME:-unknown} (expected Ubuntu 24.04 LTS)"
    fi
  else
    echo "FAIL|/etc/os-release not found"
  fi
}

check_kernel() {
  echo "PASS|$(uname -r)"
}

check_cpu() {
  local cores
  cores="$(nproc --all 2>/dev/null || echo "unknown")"
  echo "PASS|${cores} vCPU(s)"
}

check_memory() {
  local total_mb avail_mb
  total_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  avail_mb="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
  if (( total_mb < 1024 )); then
    echo "WARN|${avail_mb}MB free / ${total_mb}MB total (< 1GB total is tight for this stack)"
  else
    echo "PASS|${avail_mb}MB free / ${total_mb}MB total"
  fi
}

check_disk() {
  local line avail_pct
  line="$(df -h / | tail -1)"
  avail_pct="$(df / | tail -1 | awk '{gsub("%","",$5); print $5}')"
  if (( avail_pct >= 90 )); then
    echo "FAIL|Root filesystem ${avail_pct}% full: ${line}"
  elif (( avail_pct >= 80 )); then
    echo "WARN|Root filesystem ${avail_pct}% full: ${line}"
  else
    echo "PASS|${line}"
  fi
}

check_networking() {
  if ip route get 1.1.1.1 >/dev/null 2>&1; then
    echo "PASS|Default route present"
  else
    echo "FAIL|No default route to the internet"
  fi
}

check_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "PASS|$(docker --version)"
  else
    echo "FAIL|docker not installed or daemon not reachable"
  fi
}

check_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    echo "PASS|$(docker compose version --short)"
  else
    echo "FAIL|docker compose plugin not available"
  fi
}

check_git() {
  command -v git >/dev/null 2>&1 && echo "PASS|$(git --version)" || echo "FAIL|git not found"
}

check_python() {
  command -v python3 >/dev/null 2>&1 && echo "PASS|$(python3 --version)" || echo "FAIL|python3 not found"
}

check_uv() {
  command -v uv >/dev/null 2>&1 && echo "PASS|$(uv --version)" || echo "FAIL|uv not found"
}

check_nodejs() {
  command -v node >/dev/null 2>&1 && echo "PASS|$(node -v)" || echo "FAIL|node not found"
}

check_claude_cli() {
  if command -v claude >/dev/null 2>&1; then
    echo "PASS|$(claude --version 2>/dev/null || echo present)"
  else
    echo "WARN|claude CLI not found (optional — install separately if needed)"
  fi
}

check_caddy() {
  if docker ps --filter "name=forgeops_caddy" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_caddy; then
    echo "PASS|forgeops_caddy container running"
  else
    echo "FAIL|forgeops_caddy container not running"
  fi
}

check_portainer() {
  if docker ps --filter "name=forgeops_portainer" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_portainer; then
    echo "PASS|forgeops_portainer container running"
  else
    echo "FAIL|forgeops_portainer container not running"
  fi
}

check_redis() {
  if docker ps --filter "name=forgeops_redis" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_redis; then
    echo "PASS|forgeops_redis container running"
  else
    echo "FAIL|forgeops_redis container not running"
  fi
}

check_postgresql() {
  if docker ps --filter "name=forgeops_postgres" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_postgres; then
    echo "PASS|forgeops_postgres container running"
  else
    echo "FAIL|forgeops_postgres container not running"
  fi
}

check_fail2ban() {
  systemctl is-active --quiet fail2ban && echo "PASS|fail2ban active" || echo "FAIL|fail2ban not active"
}

check_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "PASS|ufw active"
  else
    echo "FAIL|ufw not active"
  fi
}

check_docker_networks() {
  local n
  n="$(docker network ls --filter "name=forgeops_" --format '{{.Name}}' | wc -l)"
  if (( n >= 2 )); then
    echo "PASS|${n} forgeops_* networks present"
  else
    echo "FAIL|expected 2 forgeops_* networks (edge, internal), found ${n}"
  fi
}

check_docker_volumes() {
  local n
  n="$(docker volume ls --filter "name=forgeops_" --format '{{.Name}}' | wc -l)"
  if (( n >= 6 )); then
    echo "PASS|${n} forgeops_* volumes present"
  else
    echo "WARN|expected 6 forgeops_* volumes, found ${n}"
  fi
}

check_running_containers() {
  local expected=(forgeops_caddy forgeops_portainer forgeops_postgres forgeops_redis forgeops_uptime_kuma)
  local missing=()
  for c in "${expected[@]}"; do
    docker ps --filter "name=${c}" --filter "status=running" --format '{{.Names}}' | grep -q "${c}" || missing+=("${c}")
  done
  if (( ${#missing[@]} == 0 )); then
    echo "PASS|all ${#expected[@]} core containers running"
  else
    echo "FAIL|not running: ${missing[*]}"
  fi
}

check_health_endpoints() {
  local unhealthy
  unhealthy="$(docker ps --filter "name=forgeops_" --format '{{.Names}}' | xargs -r -I{} docker inspect --format '{{.Name}}={{.State.Health.Status}}' {} 2>/dev/null | grep -v '=healthy' | grep -v '=$' || true)"
  if [[ -z "${unhealthy}" ]]; then
    echo "PASS|all containers with healthchecks report healthy"
  else
    echo "WARN|${unhealthy//$'\n'/, }"
  fi
}

check_kvm_availability() {
  if [[ -f "${REPO_ROOT}/logs/.kvm-support" ]]; then
    echo "PASS|$(cat "${REPO_ROOT}/logs/.kvm-support")"
  else
    echo "WARN|KVM detection has not run yet (run install.sh)"
  fi
}

check_secrets_integrity() {
  local env_file="${REPO_ROOT}/.env"
  if [[ ! -f "${env_file}" ]]; then
    echo "FAIL|.env does not exist"
    return
  fi
  local perms
  perms="$(stat -c '%a' "${env_file}" 2>/dev/null || stat -f '%OLp' "${env_file}" 2>/dev/null)"
  if [[ "${perms}" != "600" ]]; then
    echo "FAIL|.env permissions are ${perms}, expected 600"
    return
  fi
  local empty_keys
  empty_keys="$(grep -E '^[A-Z_]+=$' "${env_file}" | cut -d= -f1 | tr '\n' ',' || true)"
  if [[ -n "${empty_keys}" ]]; then
    echo "FAIL|empty required keys: ${empty_keys%,}"
  else
    echo "PASS|.env present, mode 600, no empty required keys"
  fi
}
