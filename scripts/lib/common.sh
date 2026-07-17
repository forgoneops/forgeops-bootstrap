#!/usr/bin/env bash
# Shared logging, state tracking, and guard functions. Sourced by every
# top-level script (install.sh, verify.sh, update.sh, uninstall.sh,
# migrate.sh) and by scripts/backup.sh, scripts/restore.sh,
# scripts/render_caddyfile.sh.

set -euo pipefail

# Caller must set REPO_ROOT before sourcing this.
: "${REPO_ROOT:?REPO_ROOT must be set before sourcing common.sh}"
LOG_DIR="${REPO_ROOT}/logs"
STATE_FILE="${LOG_DIR}/.install-state"
VERSIONS_FILE="${REPO_ROOT}/configs/versions.env"
ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"

mkdir -p "${LOG_DIR}"
RUN_LOG="${LOG_DIR}/$(basename "${0:-forgeops}" .sh)-$(date -u +%Y%m%dT%H%M%SZ).log"

# Colors off automatically when piped/redirected.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
  # shellcheck disable=SC2034  # C_BOLD is used by scripts that source this file (e.g. verify.sh)
  C_BOLD=""
fi

# Every line goes to the console (colored) and to RUN_LOG (plain, timestamped).
_log() {
  local level="$1" color="$2"; shift 2
  local ts msg
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  msg="$*"
  printf '%s[%s]%s %s\n' "${color}" "${level}" "${C_RESET}" "${msg}"
  printf '%s [%s] %s\n' "${ts}" "${level}" "${msg}" >>"${RUN_LOG}"
}

log_info()  { _log "INFO"  "${C_BLUE}"   "$@"; }
log_ok()    { _log "OK"    "${C_GREEN}"  "$@"; }
log_warn()  { _log "WARN"  "${C_YELLOW}" "$@"; }
log_error() { _log "ERROR" "${C_RED}"    "$@"; }

die() {
  log_error "$*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "run this as root (sudo)"
  fi
}

require_ubuntu_2404() {
  [[ -r /etc/os-release ]] || die "can't read /etc/os-release, so can't confirm this is Ubuntu"
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    die "this targets Ubuntu 24.04 — detected ${PRETTY_NAME:-something else}"
  fi
}

# install.sh state tracking. Each finished step gets its own line:
# "<step_name>=done" in logs/.install-state.
state_init() {
  touch "${STATE_FILE}"
}

state_is_done() {
  local step="$1"
  grep -qxF "${step}=done" "${STATE_FILE}" 2>/dev/null
}

state_mark_done() {
  local step="$1"
  grep -qxF "${step}=done" "${STATE_FILE}" 2>/dev/null || echo "${step}=done" >>"${STATE_FILE}"
}

state_reset() {
  : >"${STATE_FILE}"
  log_warn "state cleared (${STATE_FILE}) — next install.sh run starts from scratch"
}

# Runs $2.. as a named, resumable step. Step functions need to be safe to
# call again if already applied — `apt install -y` already is; anything
# custom has to check for itself before mutating state.
#
# A step can return 75 instead of 0 to mean "done for now, but come back
# and try again next run" (used by SSH hardening while it's waiting on an
# authorized_keys file to show up). Anything else non-zero is a real
# failure and stops the install.
#
# The step runs as `set +e; ( set -e; "$@" ); rc=$?; set -e` rather than
# the more obvious `"$@" || rc=$?`. Reason: bash disables errexit for the
# whole body of a function called on the left side of `||`, so a step with
# more than one command could have an early command fail and nobody notice
# as long as the last command in the function still succeeded. Tried
# wrapping just the function call in a subshell first (`( set -e; "$@" ) ||
# rc=$?`) — same problem, the exemption follows the subshell across the
# `||` too. This version actually catches it; confirmed with a step body
# of `false; true`, which used to report success.
run_step() {
  local step="$1"; shift
  if state_is_done "${step}"; then
    log_info "skipping ${step}, already done"
    return 0
  fi
  log_info "running: ${step}"
  set +e
  ( set -e; "$@" )
  local rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    state_mark_done "${step}"
    log_ok "done: ${step}"
  elif [[ "${rc}" -eq 75 ]]; then
    log_warn "${step} is waiting on something — will retry next run"
  else
    die "${step} failed (exit ${rc}) — fix it and re-run install.sh, finished steps get skipped"
  fi
}

# Same as run_step but never cached — for steps that are already cheap to
# re-run (docker compose up -d only touches containers whose config
# actually changed) where caching would just mean an .env edit never takes
# effect on the next plain install.sh run.
run_step_always() {
  local step="$1"; shift
  log_info "running: ${step}"
  set +e
  ( set -e; "$@" )
  local rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    log_ok "done: ${step}"
  else
    die "${step} failed (exit ${rc}) — fix it and re-run install.sh"
  fi
}

load_versions() {
  [[ -r "${VERSIONS_FILE}" ]] || die "missing ${VERSIONS_FILE}"
  # shellcheck disable=SC1090
  source "${VERSIONS_FILE}"
}

# Secrets ensure_env_file is allowed to randomize on first run. Deliberately
# an explicit allowlist, not a broad `=CHANGEME_*` regex match: WG_HOST also
# ships as CHANGEME_WG_HOST in .env.example, but it's a real hostname/IP the
# operator must supply, not a secret -- randomizing it used to hand
# WireGuard a fabricated endpoint that looked resolved but wasn't.
# step_install_wireguard (scripts/lib/install_steps.sh) refuses to proceed
# (exit 75) until a real value is set; see docs/VPN_SETUP.md.
ENV_SECRET_VARS=(
  POSTGRES_PASSWORD
  REDIS_PASSWORD
  WG_PASSWORD
  MCP_BEARER_TOKEN
  MEM0_DB_PASSWORD
  POSTGRES_MCP_RO_PASSWORD
)

ensure_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    log_info ".env already exists, leaving it alone"
    return 0
  fi
  [[ -r "${ENV_EXAMPLE}" ]] || die "missing ${ENV_EXAMPLE}, can't generate .env"
  log_info "generating .env with fresh secrets..."
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  local var placeholder secret
  for var in "${ENV_SECRET_VARS[@]}"; do
    placeholder="CHANGEME_${var}"
    if grep -qE "^${var}=${placeholder}\$" "${ENV_FILE}"; then
      secret="$(openssl rand -hex 32)"
      sed -i "s|^${var}=${placeholder}\$|${var}=${secret}|" "${ENV_FILE}"
    fi
  done
  chmod 600 "${ENV_FILE}"
  log_ok ".env ready (mode 600)"
}

# Loads .env into the current shell's exported environment so install.sh's
# step functions (step_install_wireguard, step_install_mcp_gateway,
# step_reconcile_mcp_postgres_role, etc.) see WG_HOST/POSTGRES_*/
# MCP_BEARER_TOKEN/etc. without each one re-sourcing the file itself.
# Called after ensure_env_file on every install.sh run, including reruns --
# `set -a` / `set +a` auto-exports whatever ensure_env_file just wrote (or
# whatever the operator has since hand-edited into .env) rather than
# leaving later steps to rely on a stale export from a previous run. Never
# echoes the file's contents -- nothing here logs secret values.
load_env_file() {
  [[ -r "${ENV_FILE}" ]] || die "missing ${ENV_FILE} — ensure_env_file should have created it"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  log_info ".env loaded"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}
