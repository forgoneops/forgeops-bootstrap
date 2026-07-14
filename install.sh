#!/usr/bin/env bash
# install.sh - provisions and configures the complete ForgeOps Bootstrap server.
#
# Idempotent and resumable: each step below is tracked in logs/.install-state.
# Re-running this script skips completed steps and resumes from any failure.
#
# Usage:
#   sudo ./install.sh              # run/resume the full install
#   sudo ./install.sh --reset-state    # forget progress, re-run every step
#   sudo ./install.sh --dry-run        # print the step order and exit

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/install_steps.sh"

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --reset-state) state_init; state_reset ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "Unknown argument: ${arg} (see --help)" ;;
  esac
done

# Each entry is name:function:mode. mode is "cached" (run once, skipped on
# future install.sh invocations once marked done in logs/.install-state —
# unless a step returns 75, see common.sh's run_step, used by
# configure_ssh_security's deferred path — or --reset-state is used) or
# "always" (re-evaluated on every install.sh invocation regardless of the
# state file, for steps that are already cheaply idempotent on their own —
# docker compose up -d only recreates containers if config actually
# changed — where caching would silently no-op a legitimate re-run after
# editing .env; see AUDIT.md IDEM-3).
STEPS=(
  update_ubuntu:step_update_ubuntu:cached
  upgrade_packages:step_upgrade_packages:cached
  configure_locale:step_configure_locale:cached
  configure_timezone:step_configure_timezone:cached
  install_base_packages:step_install_base_packages:cached
  install_uv:step_install_uv:cached
  install_nodejs:step_install_nodejs:cached
  install_docker:step_install_docker:cached
  verify_docker_compose:step_verify_docker_compose:cached
  install_caddy:step_install_caddy:cached
  create_project_directories:step_create_project_directories:cached
  ensure_env_file:ensure_env_file:cached
  deploy_docker_stack:step_deploy_docker_stack:always
  configure_backups:step_configure_backups:cached
  configure_automatic_security_updates:step_configure_automatic_security_updates:cached
  configure_log_rotation:step_configure_log_rotation:cached
  configure_firewall:step_configure_firewall:cached
  configure_fail2ban:step_configure_fail2ban:cached
  configure_ssh_security:step_configure_ssh_security:cached
  detect_kvm_support:step_detect_kvm_support:cached
  generate_installation_report:step_generate_installation_report:always
)

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry run — step order (nothing will be executed):"
  for entry in "${STEPS[@]}"; do
    name="${entry%%:*}"
    mode="${entry##*:}"
    echo "  - ${name} (${mode})"
  done
  exit 0
fi

require_root
require_ubuntu_2404
state_init
load_versions

log_info "ForgeOps Bootstrap install starting. Log: ${RUN_LOG}"

for entry in "${STEPS[@]}"; do
  IFS=':' read -r name fn mode <<<"${entry}"
  if [[ "${mode}" == "always" ]]; then
    run_step_always "${name}" "${fn}"
  else
    run_step "${name}" "${fn}"
  fi
done

log_ok "Install complete. Run ./verify.sh for a full health report."
