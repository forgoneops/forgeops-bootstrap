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
  install_wireguard:step_install_wireguard:cached
  install_observability:step_install_observability:cached
  deploy_docker_stack:step_deploy_docker_stack:always
  # install_mem0/install_mcp_gateway/reconcile_mcp_postgres_role run their
  # `docker compose exec postgres psql` role-creation AFTER
  # deploy_docker_stack on purpose — postgres has to actually be running
  # for `exec` to work. mcp-postgres itself is already up by this point
  # (started above) and will simply keep retrying via its restart policy
  # until the postgres_mcp_ro role that reconcile_mcp_postgres_role
  # creates/updates actually exists with the current password — a brief,
  # self-recovering crash-loop rather than a hard ordering dependency, since
  # Compose has no cross-container "wait for this SQL to run" primitive.
  #
  # reconcile_mcp_postgres_role runs in "always" mode, unlike
  # install_mcp_gateway (cached, one-time bearer-token check + fail2ban
  # setup) — deploy_docker_stack above already recreates mcp-postgres with
  # a new connection URI whenever POSTGRES_MCP_RO_PASSWORD changes in .env,
  # so the actual database role's password has to be reconciled on every
  # run too, not just the first one, or a rotated password only ever
  # reaches mcp-postgres's env and never the role itself.
  install_mem0:step_install_mem0:cached
  install_mcp_gateway:step_install_mcp_gateway:cached
  reconcile_mcp_postgres_role:step_reconcile_mcp_postgres_role:always
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
  # Every step after ensure_env_file needs WG_HOST/POSTGRES_*/
  # MCP_BEARER_TOKEN/etc. in its own environment. Reload on every run
  # (not just the first, when ensure_env_file actually wrote the file) so
  # a rerun after hand-editing .env — or after ensure_env_file's own
  # early-return on an already-existing file — sees current values
  # instead of nothing at all.
  if [[ "${name}" == "ensure_env_file" ]]; then
    load_env_file
  fi
done

log_ok "install complete — run ./verify.sh for a health report"
