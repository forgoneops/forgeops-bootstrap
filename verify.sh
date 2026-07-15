#!/usr/bin/env bash
# Checks every installed component and writes a health report as console
# output, Markdown, and JSON.
#
# Usage:
#   ./verify.sh                # console report, exits 1 if anything FAILed
#   ./verify.sh --report-only  # write the reports but always exit 0 (install.sh uses this)
#   ./verify.sh --json         # JSON on stdout instead of the console table

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/verify_checks.sh"

REPORT_ONLY=0
JSON_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --report-only) REPORT_ONLY=1 ;;
    --json) JSON_ONLY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

CHECKS=(
  "Operating System:check_operating_system"
  "Kernel:check_kernel"
  "CPU:check_cpu"
  "Memory:check_memory"
  "Disk:check_disk"
  "Networking:check_networking"
  "Docker:check_docker"
  "Docker Compose:check_docker_compose"
  "Git:check_git"
  "Python:check_python"
  "uv:check_uv"
  "Node.js:check_nodejs"
  "Claude CLI:check_claude_cli"
  "Caddy:check_caddy"
  "Portainer:check_portainer"
  "Redis:check_redis"
  "PostgreSQL:check_postgresql"
  "WireGuard:check_wireguard"
  "Observability Stack:check_observability_stack"
  "Mem0:check_mem0"
  "MCP Gateway:check_mcp_gateway_running"
  "MCP Auth:check_mcp_auth"
  "MCP VPN-Only:check_mcp_reachable_only_via_vpn"
  "Fail2Ban:check_fail2ban"
  "Firewall:check_firewall"
  "Docker Networks:check_docker_networks"
  "Docker Volumes:check_docker_volumes"
  "Running Containers:check_running_containers"
  "Health Endpoints:check_health_endpoints"
  "KVM Availability:check_kvm_availability"
  "Secrets Integrity:check_secrets_integrity"
)

declare -a NAMES STATUSES DETAILS
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0

for entry in "${CHECKS[@]}"; do
  name="${entry%%:*}"
  fn="${entry##*:}"
  result="$("${fn}" 2>&1)"
  status="${result%%|*}"
  detail="${result#*|}"
  NAMES+=("${name}")
  STATUSES+=("${status}")
  DETAILS+=("${detail}")
  case "${status}" in
    PASS) ((PASS_COUNT+=1)) ;;
    WARN) ((WARN_COUNT+=1)) ;;
    FAIL) ((FAIL_COUNT+=1)) ;;
  esac
done

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Console report -----------------------------------------------------------
print_console() {
  printf '\n%sForgeOps Bootstrap — Health Report (%s)%s\n\n' "${C_BOLD}" "${TIMESTAMP}" "${C_RESET}"
  for i in "${!NAMES[@]}"; do
    local color="${C_GREEN}"
    [[ "${STATUSES[$i]}" == "WARN" ]] && color="${C_YELLOW}"
    [[ "${STATUSES[$i]}" == "FAIL" ]] && color="${C_RED}"
    printf '  %s%-6s%s %-20s %s\n' "${color}" "${STATUSES[$i]}" "${C_RESET}" "${NAMES[$i]}" "${DETAILS[$i]}"
  done
  printf '\n%d passed, %d warnings, %d failed\n\n' "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
}

# --- Markdown report ------------------------------------------------------------
write_markdown() {
  local out="${LOG_DIR}/verify-report.md"
  {
    echo "# ForgeOps Bootstrap — Health Report"
    echo ""
    echo "Generated: ${TIMESTAMP}"
    echo ""
    echo "| Status | Check | Detail |"
    echo "|---|---|---|"
    for i in "${!NAMES[@]}"; do
      echo "| ${STATUSES[$i]} | ${NAMES[$i]} | ${DETAILS[$i]} |"
    done
    echo ""
    echo "**Summary:** ${PASS_COUNT} passed, ${WARN_COUNT} warnings, ${FAIL_COUNT} failed."
  } >"${out}"
  echo "${out}"
}

# --- JSON report ------------------------------------------------------------
write_json() {
  local out="${LOG_DIR}/verify-report.json"
  {
    printf '{\n  "timestamp": "%s",\n  "summary": {"pass": %d, "warn": %d, "fail": %d},\n  "checks": [\n' \
      "${TIMESTAMP}" "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
    for i in "${!NAMES[@]}"; do
      local esc_detail="${DETAILS[$i]//\"/\\\"}"
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}%s\n' \
        "${NAMES[$i]}" "${STATUSES[$i]}" "${esc_detail}" \
        "$([[ $i -lt $((${#NAMES[@]}-1)) ]] && echo ',')"
    done
    printf '  ]\n}\n'
  } >"${out}"
  echo "${out}"
}

MD_PATH="$(write_markdown)"
JSON_PATH="$(write_json)"

if [[ "${JSON_ONLY}" -eq 1 ]]; then
  cat "${JSON_PATH}"
else
  print_console
  log_info "Markdown report: ${MD_PATH}"
  log_info "JSON report: ${JSON_PATH}"
fi

if [[ "${REPORT_ONLY}" -eq 1 ]]; then
  exit 0
fi

[[ "${FAIL_COUNT}" -eq 0 ]] || exit 1
