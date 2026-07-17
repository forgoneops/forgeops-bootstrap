#!/usr/bin/env bash
# One check per verify.sh row. Each function prints one line:
# "STATUS|detail" where STATUS is PASS, WARN, or FAIL.

set -uo pipefail   # no -e on purpose: a failing check shouldn't kill the whole script

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
    echo "WARN|${avail_mb}MB free / ${total_mb}MB total (under 1GB is tight for this stack)"
  else
    echo "PASS|${avail_mb}MB free / ${total_mb}MB total"
  fi
}

check_disk() {
  local line avail_pct
  line="$(df -h / | tail -1)"
  avail_pct="$(df / | tail -1 | awk '{gsub("%","",$5); print $5}')"
  if (( avail_pct >= 90 )); then
    echo "FAIL|root filesystem ${avail_pct}% full: ${line}"
  elif (( avail_pct >= 80 )); then
    echo "WARN|root filesystem ${avail_pct}% full: ${line}"
  else
    echo "PASS|${line}"
  fi
}

check_networking() {
  if ip route get 1.1.1.1 >/dev/null 2>&1; then
    echo "PASS|default route present"
  else
    echo "FAIL|no default route to the internet"
  fi
}

check_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "PASS|$(docker --version)"
  else
    echo "FAIL|docker not installed or daemon unreachable"
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
    echo "WARN|claude CLI not found (optional)"
  fi
}

check_caddy() {
  if docker ps --filter "name=forgeops_caddy" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_caddy; then
    echo "PASS|forgeops_caddy running"
  else
    echo "FAIL|forgeops_caddy not running"
  fi
}

check_portainer() {
  if docker ps --filter "name=forgeops_portainer" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_portainer; then
    echo "PASS|forgeops_portainer running"
  else
    echo "FAIL|forgeops_portainer not running"
  fi
}

check_redis() {
  if docker ps --filter "name=forgeops_redis" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_redis; then
    echo "PASS|forgeops_redis running"
  else
    echo "FAIL|forgeops_redis not running"
  fi
}

check_postgresql() {
  if docker ps --filter "name=forgeops_postgres" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_postgres; then
    echo "PASS|forgeops_postgres running"
  else
    echo "FAIL|forgeops_postgres not running"
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
    echo "PASS|${n} forgeops_* networks"
  else
    echo "FAIL|expected 2 forgeops_* networks (edge, internal), found ${n}"
  fi
}

check_docker_volumes() {
  local n
  n="$(docker volume ls --filter "name=forgeops_" --format '{{.Name}}' | wc -l)"
  if (( n >= 6 )); then
    echo "PASS|${n} forgeops_* volumes"
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
    echo "WARN|not checked yet — run install.sh"
  fi
}

check_wireguard() {
  if docker ps --filter "name=forgeops_wireguard" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_wireguard; then
    echo "PASS|forgeops_wireguard running"
  else
    echo "FAIL|forgeops_wireguard not running"
  fi
}

check_observability_stack() {
  local expected=(forgeops_cadvisor forgeops_prometheus forgeops_grafana)
  local missing=()
  for c in "${expected[@]}"; do
    docker ps --filter "name=${c}" --filter "status=running" --format '{{.Names}}' | grep -q "${c}" || missing+=("${c}")
  done
  if (( ${#missing[@]} == 0 )); then
    echo "PASS|cadvisor, prometheus, grafana all running"
  else
    echo "FAIL|not running: ${missing[*]}"
  fi
}

check_mem0() {
  if docker ps --filter "name=forgeops_mem0$" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_mem0; then
    echo "PASS|forgeops_mem0 running"
  else
    echo "WARN|not deployed — source-pinning decision pending, see docs/MEMORY.md"
  fi
}

check_mcp_gateway_running() {
  local expected=(forgeops_mcp_gateway forgeops_mcp_filesystem forgeops_mcp_git forgeops_mcp_postgres)
  local missing=()
  for c in "${expected[@]}"; do
    docker ps --filter "name=${c}" --filter "status=running" --format '{{.Names}}' | grep -q "${c}" || missing+=("${c}")
  done
  if (( ${#missing[@]} == 0 )); then
    echo "PASS|mcp-gateway + filesystem/git/postgres MCP servers all running"
  else
    echo "FAIL|not running: ${missing[*]} (mem0-mcp intentionally excluded, see docs/MEMORY.md)"
  fi
}

check_mcp_auth() {
  if ! docker ps --filter "name=forgeops_mcp_gateway" --filter "status=running" --format '{{.Names}}' | grep -q forgeops_mcp_gateway; then
    echo "WARN|mcp-gateway not running, can't check auth"
    return
  fi
  # Request from inside the internal network (via the caddy container,
  # which already has wget) with no Authorization header — must get 401.
  # A 200 here would mean the bearer-token check isn't actually enforcing.
  local status
  status="$(docker compose -f "${REPO_ROOT}/docker-compose.yml" exec -T caddy wget -S -O /dev/null http://mcp-gateway:8443/ 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]+' | awk '{print $2}' | head -1)"
  if [[ "${status}" == "401" ]]; then
    echo "PASS|unauthenticated request correctly rejected (401)"
  else
    echo "FAIL|expected 401 for an unauthenticated request, got: ${status:-no response}"
  fi
}

check_mcp_reachable_only_via_vpn() {
  # What this actually checks: none of the MCP-facing containers publish a
  # host port. That's the honest, locally-verifiable proxy for "not
  # reachable from the public internet" — a real probe from an external
  # vantage point is out of scope for a script that runs on the host
  # itself and isn't something verify.sh can meaningfully simulate. This
  # check fails loud if that assumption is ever violated (e.g. someone
  # adds a `ports:` line to one of these services later).
  local containers=(forgeops_mcp_gateway forgeops_mcp_filesystem forgeops_mcp_git forgeops_mcp_postgres forgeops_mem0_mcp)
  local exposed=()
  for c in "${containers[@]}"; do
    local ports
    ports="$(docker port "${c}" 2>/dev/null || true)"
    [[ -n "${ports}" ]] && exposed+=("${c}: ${ports}")
  done
  if (( ${#exposed[@]} == 0 )); then
    echo "PASS|no MCP-facing container publishes a host port"
  else
    echo "FAIL|host port(s) published on an MCP-facing container: ${exposed[*]}"
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
    echo "PASS|.env present, mode 600, nothing empty"
  fi
}
