#!/usr/bin/env bash
# common.sh - shared logging, state, and guard functions for all ForgeOps scripts.
# Sourced by install.sh, verify.sh, update.sh, uninstall.sh, migrate.sh.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (relative to repo root; callers must set REPO_ROOT before sourcing)
# ---------------------------------------------------------------------------
: "${REPO_ROOT:?REPO_ROOT must be set before sourcing common.sh}"
LOG_DIR="${REPO_ROOT}/logs"
STATE_FILE="${LOG_DIR}/.install-state"
VERSIONS_FILE="${REPO_ROOT}/configs/versions.env"
ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"

mkdir -p "${LOG_DIR}"
RUN_LOG="${LOG_DIR}/$(basename "${0:-forgeops}" .sh)-$(date -u +%Y%m%dT%H%M%SZ).log"

# ---------------------------------------------------------------------------
# Colors (disabled automatically when stdout is not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

# ---------------------------------------------------------------------------
# Logging: every line goes to console (colored) and to RUN_LOG (plain, timestamped)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Root / platform guards
# ---------------------------------------------------------------------------
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root (use sudo)."
  fi
}

require_ubuntu_2404() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    die "ForgeOps Bootstrap targets Ubuntu 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}."
  fi
}

# ---------------------------------------------------------------------------
# State tracking for install.sh resumability
# Each completed step is recorded as its own line: "<step_name>=done"
# ---------------------------------------------------------------------------
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
  log_warn "Install state cleared (${STATE_FILE}). Next run of install.sh will re-run every step."
}

# Runs $2.. as a named, idempotent, resumable step. The step function itself
# must be safe to call when already applied (e.g. `apt install -y` is already
# idempotent; custom steps must self-check before mutating state).
run_step() {
  local step="$1"; shift
  if state_is_done "${step}"; then
    log_info "Skipping '${step}' (already completed)."
    return 0
  fi
  log_info "Running step: ${step}"
  if "$@"; then
    state_mark_done "${step}"
    log_ok "Completed step: ${step}"
  else
    die "Step '${step}' failed. Fix the error above and re-run install.sh — completed steps will be skipped."
  fi
}

# ---------------------------------------------------------------------------
# versions.env / .env helpers
# ---------------------------------------------------------------------------
load_versions() {
  [[ -r "${VERSIONS_FILE}" ]] || die "Missing ${VERSIONS_FILE}."
  # shellcheck disable=SC1090
  source "${VERSIONS_FILE}"
}

ensure_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    log_info ".env already exists — leaving it untouched."
    return 0
  fi
  [[ -r "${ENV_EXAMPLE}" ]] || die "Missing ${ENV_EXAMPLE}; cannot generate .env."
  log_info "Generating .env from .env.example with fresh random secrets..."
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  # Replace every CHANGEME_* placeholder with a random 32-byte hex secret.
  local placeholder
  while IFS= read -r placeholder; do
    local secret
    secret="$(openssl rand -hex 32)"
    # Use a delimiter unlikely to appear in a hex string or key name.
    sed -i "s|${placeholder}|${secret}|" "${ENV_FILE}"
  done < <(grep -oE '=CHANGEME_[A-Za-z0-9_]*' "${ENV_FILE}" | sed 's/^=//' | sort -u)
  chmod 600 "${ENV_FILE}"
  log_ok ".env generated with random secrets (mode 600)."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}
