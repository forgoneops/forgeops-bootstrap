#!/usr/bin/env bash
# Provisions and configures the ForgeOps Bootstrap server.
#
# Idempotent and resumable — each step is tracked in logs/.install-state.
# If it fails partway, fix the problem and run it again; finished steps
# get skipped.
#
# Usage:
#   sudo ./install.sh              # run/resume the full install
#   sudo ./install.sh --reset-state    # forget progress, start over
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
    *) die "unknown argument: ${arg} (see --help)" ;;
  esac
done

# name:function:mode. "cached" runs once and gets skipped on later runs
# unless a step returns 75 (see common.sh's run_step) or --reset-state was
# used. "always" runs every time regardless of the state file — for steps
# that are already cheap to repeat (docker compose up -d) where caching
# would mean an .env edit never actually takes effect.
STEPS=(
  update_ubuntu:step_update_ubuntu:cached
  upgrade_packages:step_upgrade_packages:cached
  configure_locale:step_configure_locale:cached
  configure_timezone:step_configure_timezone:cached
  install_base_packages:step_install_base_packages:cached
  install_uv:step_install_uv:always
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
  log_info "step order (dry run, nothing executed):"
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

log_info "starting install. log: ${RUN_LOG}"

for entry in "${STEPS[@]}"; do
  IFS=':' read -r name fn mode <<<"${entry}"
  if [[ "${mode}" == "always" ]]; then
    run_step_always "${name}" "${fn}"
  else
    run_step "${name}" "${fn}"
  fi
done

log_ok "install complete — run ./verify.sh for a health report"
