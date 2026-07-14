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

STEPS=(
  update_ubuntu:step_update_ubuntu
  upgrade_packages:step_upgrade_packages
  configure_locale:step_configure_locale
  configure_timezone:step_configure_timezone
  install_base_packages:step_install_base_packages
  install_uv:step_install_uv
  install_nodejs:step_install_nodejs
  install_docker:step_install_docker
  verify_docker_compose:step_verify_docker_compose
  install_caddy:step_install_caddy
  create_project_directories:step_create_project_directories
  ensure_env_file:ensure_env_file
  deploy_docker_stack:step_deploy_docker_stack
  configure_backups:step_configure_backups
  configure_automatic_security_updates:step_configure_automatic_security_updates
  configure_log_rotation:step_configure_log_rotation
  configure_firewall:step_configure_firewall
  configure_fail2ban:step_configure_fail2ban
  configure_ssh_security:step_configure_ssh_security
  detect_kvm_support:step_detect_kvm_support
  generate_installation_report:step_generate_installation_report
)

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry run — step order (nothing will be executed):"
  for entry in "${STEPS[@]}"; do
    echo "  - ${entry%%:*}"
  done
  exit 0
fi

require_root
require_ubuntu_2404
state_init
load_versions

log_info "ForgeOps Bootstrap install starting. Log: ${RUN_LOG}"

for entry in "${STEPS[@]}"; do
  name="${entry%%:*}"
  fn="${entry##*:}"
  run_step "${name}" "${fn}"
done

log_ok "Install complete. Run ./verify.sh for a full health report."
