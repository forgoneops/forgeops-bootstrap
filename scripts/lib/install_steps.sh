#!/usr/bin/env bash
# One function per install.sh step. Sourced after common.sh. Each function
# needs to be safe to call again if the thing it sets up already exists.

set -euo pipefail

APT_PACKAGES_BASIC=(
  git python3 python3-venv python3-pip build-essential curl wget jq
  ripgrep fzf tmux btop htop tree ncdu rsync fail2ban ufw ca-certificates
  gnupg locales
)

step_update_ubuntu() {
  apt-get update -y
}

step_upgrade_packages() {
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

step_configure_locale() {
  locale-gen en_US.UTF-8
  update-locale LANG=en_US.UTF-8
}

step_configure_timezone() {
  local tz="${TIMEZONE:-UTC}"
  timedatectl set-timezone "${tz}"
}

step_install_base_packages() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES_BASIC[@]}"
}

step_install_uv() {
  if command_exists uv; then
    log_info "uv already installed ($(uv --version))"
    return 0
  fi
  curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR=/usr/local sh
}

step_install_nodejs() {
  if command_exists node && [[ "$(node -v)" == v"${NODE_MAJOR}".* ]]; then
    log_info "Node.js ${NODE_MAJOR}.x already installed ($(node -v))"
    return 0
  fi
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
}

step_install_docker() {
  if command_exists docker; then
    log_info "Docker already installed ($(docker --version))"
    return 0
  fi
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} ${DOCKER_APT_CHANNEL}" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

step_verify_docker_compose() {
  command_exists docker || die "Docker needs to be installed before this check makes sense"
  docker compose version >/dev/null 2>&1 || die "docker compose plugin isn't available"
  log_ok "docker compose: $(docker compose version --short)"
}

step_install_caddy() {
  if command_exists caddy; then
    log_info "system caddy binary found — we run Caddy via Docker instead, nothing to do"
    return 0
  fi
  # Caddy itself runs as a container. This just pre-pulls the image so the
  # first `docker compose up` isn't waiting on a slow pull.
  docker pull "${CADDY_IMAGE}"
}

step_create_project_directories() {
  local projects_dir="${PROJECTS_DIR:-/opt/forgeops/projects}"
  mkdir -p "${projects_dir}" "${REPO_ROOT}/backups" "${REPO_ROOT}/logs" "${REPO_ROOT}/logs/caddy" "${REPO_ROOT}/logs/mcp-gateway"
  chmod 750 "${projects_dir}"
}

step_deploy_docker_stack() {
  # "Install Portainer/Postgres/Redis/Uptime Kuma" all happen here as one
  # docker compose up — there's no real way to install one service from a
  # compose file independent of the others. The VPN-gated MCP engine
  # services join this same reconciliation for the same reason — their
  # one-time provisioning (secrets, DB roles) happens in the step_install_*
  # functions below, which must run before this one.
  #
  # mem0/mem0-mcp are deliberately NOT in this service list yet — see
  # step_install_mem0's die() message. Their compose service definitions
  # exist (docker-compose.yml) and build from ./build/mem0-server and
  # ./build/mem0-mcp, but nothing populates those directories until the
  # source-pinning question below is resolved with the operator.
  cd "${REPO_ROOT}"
  bash "${REPO_ROOT}/scripts/render_caddyfile.sh"
  docker pull "${PORTAINER_IMAGE}"
  docker pull "${POSTGRES_IMAGE}"
  docker pull "${REDIS_IMAGE}"
  docker pull "${UPTIME_KUMA_IMAGE}"
  docker pull "${WATCHTOWER_IMAGE}"
  docker pull "${WGEASY_IMAGE}"
  docker pull "${CADVISOR_IMAGE}"
  docker pull "${PROMETHEUS_IMAGE}"
  docker pull "${GRAFANA_IMAGE}"
  docker pull "${POSTGRES_MCP_IMAGE}"
  # mcp-proxy is no longer a `docker pull`-able registry image — it's a pip
  # package installed inside mcp-filesystem/mcp-git's own build (see
  # docker/mcp-stdio-bridge/Dockerfile + configs/versions.env's
  # MCP_PROXY_VERSION); nothing to pre-pull for it, `docker compose up
  # --build` below handles that build step directly.
  CADDY_IMAGE="${CADDY_IMAGE}" PORTAINER_IMAGE="${PORTAINER_IMAGE}" \
    POSTGRES_IMAGE="${POSTGRES_IMAGE}" REDIS_IMAGE="${REDIS_IMAGE}" \
    UPTIME_KUMA_IMAGE="${UPTIME_KUMA_IMAGE}" WATCHTOWER_IMAGE="${WATCHTOWER_IMAGE}" \
    WGEASY_IMAGE="${WGEASY_IMAGE}" CADVISOR_IMAGE="${CADVISOR_IMAGE}" \
    PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE}" GRAFANA_IMAGE="${GRAFANA_IMAGE}" \
    POSTGRES_MCP_IMAGE="${POSTGRES_MCP_IMAGE}" \
    PYTHON_BASE_IMAGE="${PYTHON_BASE_IMAGE}" MCP_PROXY_VERSION="${MCP_PROXY_VERSION}" \
    MCP_FILESYSTEM_SERVER_VERSION="${MCP_FILESYSTEM_SERVER_VERSION}" \
    MCP_GIT_SERVER_VERSION="${MCP_GIT_SERVER_VERSION:-}" \
    docker compose up -d --build \
      caddy portainer postgres redis uptime-kuma \
      wireguard cadvisor prometheus grafana \
      mcp-filesystem mcp-git mcp-postgres mcp-gateway
}

step_install_wireguard() {
  if [[ -z "${WG_HOST:-}" || "${WG_HOST}" == "CHANGEME_WG_HOST" ]]; then
    log_warn "WG_HOST not set in .env — set it to this VPS's public IP/hostname, then re-run install.sh. See docs/VPN_SETUP.md."
    return 75
  fi
  # UFW allow is additive-only (see step_configure_firewall) — safe to call
  # again, `ufw allow` is already a no-op if the rule exists.
  ufw allow "${WG_PORT:-51820}/udp"

  # Best-effort jail — wg-easy's log format/path wasn't independently
  # confirmed this session, so this filter is a starting point, not a
  # verified-working one. Left disabled until confirmed against real
  # wg-easy log output; a jail that never matches is safer than one with a
  # wrong filter that locks out legitimate peers.
  cat >/etc/fail2ban/filter.d/forgeops-wg-abuse.conf <<'EOF'
[Definition]
failregex = Invalid handshake initiation from <HOST>
ignoreregex =
EOF
  cat >/etc/fail2ban/jail.d/forgeops-wg-abuse.local <<EOF
[forgeops-wg-abuse]
enabled = false
filter = forgeops-wg-abuse
logpath = ${REPO_ROOT}/logs/wireguard/wireguard.log
maxretry = 10
bantime = 1h
findtime = 10m
EOF
  log_warn "forgeops-wg-abuse jail installed but left disabled (enabled = false) — verify its logpath/filter against real wg-easy output, then flip to enabled = true in /etc/fail2ban/jail.d/forgeops-wg-abuse.local."
  systemctl restart fail2ban
}

step_install_observability() {
  # No secrets or DB state to provision — cadvisor/prometheus/grafana are
  # entirely config-file-driven (configs/prometheus/prometheus.yml,
  # configs/grafana/provisioning/), both already committed to this repo.
  # This step's only job is pre-pulling so the first `docker compose up`
  # in step_deploy_docker_stack isn't waiting on a slow pull, same pattern
  # as step_install_caddy.
  docker pull "${CADVISOR_IMAGE}"
  docker pull "${PROMETHEUS_IMAGE}"
  docker pull "${GRAFANA_IMAGE}"
}

step_install_mem0() {
  # BLOCKED — see docs/MEMORY.md "Open decision: source pinning". Mem0's
  # self-hosted server ships no maintained, versioned Docker image, and the
  # MCP wrapper this plan named (coleam00/mcp-mem0) has had no commits in
  # 14+ months. Building either from source means cloning and running
  # code from a repo the operator hasn't explicitly named/audited — that
  # needs an explicit go-ahead per repo, not an inherited approval of
  # "build from source" as a general approach. Not implemented until that
  # decision is made; deploy_docker_stack does not include mem0/mem0-mcp
  # in its service list yet, so nothing here silently runs unvetted code.
  #
  # Returns 75 (not die()) deliberately: everything else in this install —
  # WireGuard, observability, the filesystem/git/postgres MCP servers — is
  # unaffected by this decision and shouldn't be blocked by it. This step
  # just keeps coming back on every install.sh run until it's resolved.
  log_warn "step_install_mem0 not implemented — source-pinning decision pending, see docs/MEMORY.md. Rest of install.sh proceeds; re-run later once resolved."
  return 75
}

step_install_mcp_gateway() {
  # Dedicated READ-ONLY Postgres role — no write grants at all, so this is
  # a real control, not just postgres-mcp's own --access-mode=restricted
  # flag (defense in depth, see SECURITY.md).
  docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres_mcp_ro') THEN
    CREATE ROLE postgres_mcp_ro LOGIN PASSWORD '${POSTGRES_MCP_RO_PASSWORD}';
  ELSE
    ALTER ROLE postgres_mcp_ro PASSWORD '${POSTGRES_MCP_RO_PASSWORD}';
  END IF;
END
\$\$;
GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO postgres_mcp_ro;
GRANT USAGE ON SCHEMA public TO postgres_mcp_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO postgres_mcp_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO postgres_mcp_ro;
SQL

  if [[ -z "${MCP_BEARER_TOKEN:-}" || "${MCP_BEARER_TOKEN}" == "CHANGEME_MCP_BEARER_TOKEN" ]]; then
    die "MCP_BEARER_TOKEN not set in .env — ensure_env_file should have generated one; check .env manually"
  fi

  # forgeops-mcp-auth watches mcp-gateway's own JSON access log — same
  # format/pattern as the existing forgeops-caddy-auth jail, so this one is
  # a confirmed-working filter, not a best-effort guess like the WG one.
  cat >/etc/fail2ban/filter.d/forgeops-mcp-auth.conf <<'EOF'
[Definition]
failregex = "remote_ip":"<HOST>".*"status":401
ignoreregex =
EOF
  cat >/etc/fail2ban/jail.d/forgeops-mcp-auth.local <<EOF
[forgeops-mcp-auth]
enabled = true
filter = forgeops-mcp-auth
logpath = ${REPO_ROOT}/logs/mcp-gateway/access.log
maxretry = 8
bantime = 1h
findtime = 10m
EOF
  systemctl restart fail2ban

  # mcp-postgres was already started by step_deploy_docker_stack and has
  # been crash-looping on a role that didn't exist yet — restart it now
  # instead of waiting out its backoff.
  ( cd "${REPO_ROOT}" && docker compose restart mcp-postgres ) || true
}

step_configure_backups() {
  chmod +x "${REPO_ROOT}/scripts/backup.sh" "${REPO_ROOT}/scripts/restore.sh"

  cat >/etc/systemd/system/forgeops-backup.service <<EOF
[Unit]
Description=ForgeOps Bootstrap daily backup (PostgreSQL + Redis + config)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${REPO_ROOT}
ExecStart=${REPO_ROOT}/scripts/backup.sh
EOF

  cat >/etc/systemd/system/forgeops-backup.timer <<'EOF'
[Unit]
Description=Run ForgeOps Bootstrap backup daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now forgeops-backup.timer
}

step_configure_automatic_security_updates() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades apt-listchanges
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades
}

step_configure_log_rotation() {
  cat >/etc/logrotate.d/forgeops <<EOF
${REPO_ROOT}/logs/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
}

step_configure_ssh_security() {
  local sshd_config="/etc/ssh/sshd_config.d/60-forgeops-hardening.conf"
  # Only turn off password auth once we know a key actually works — don't
  # want to lock anyone out.
  local key_present=0
  for home in /root /home/*; do
    [[ -s "${home}/.ssh/authorized_keys" ]] && key_present=1
  done
  if [[ "${key_present}" -eq 0 ]]; then
    log_warn "no authorized_keys found anywhere — leaving password auth on so you don't get locked out. Add a key, then re-run install.sh."
    cat >"${sshd_config}" <<'EOF'
# password auth left on — no SSH key detected yet
PermitRootLogin prohibit-password
EOF
    sshd -t || die "generated sshd config is invalid, not reloading"
    systemctl reload ssh
    # 75 = "come back and check again next run" rather than "done for good"
    return 75
  fi

  cat >"${sshd_config}" <<'EOF'
# hardened — an authorized_keys file was present at install time
PasswordAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  sshd -t || die "generated sshd config is invalid, not reloading"
  systemctl reload ssh
}

step_configure_firewall() {
  # No `ufw --force reset` here — that would nuke any rule someone added
  # by hand every time this step gets forced to re-run. `ufw default` and
  # `ufw allow` are already no-ops if the rule's already there.
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 443/udp
  ufw --force enable
}

step_configure_fail2ban() {
  systemctl enable --now fail2ban
  cat >/etc/fail2ban/jail.d/forgeops-sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
findtime = 10m
EOF

  # Second jail for the exposed admin UIs (Portainer/Uptime Kuma), once
  # Caddy is logging to a file. Does nothing if nothing's ever exposed.
  cat >/etc/fail2ban/filter.d/forgeops-caddy-auth.conf <<'EOF'
[Definition]
failregex = "remote_ip":"<HOST>".*"status":(401|403)
ignoreregex =
EOF

  cat >/etc/fail2ban/jail.d/forgeops-caddy.local <<EOF
[forgeops-caddy-auth]
enabled = true
filter = forgeops-caddy-auth
logpath = ${REPO_ROOT}/logs/caddy/access.log
maxretry = 8
bantime = 1h
findtime = 10m
EOF

  systemctl restart fail2ban
}

step_detect_kvm_support() {
  local kvm_ok="no"
  if [[ -e /dev/kvm ]] && command_exists kvm-ok; then
    kvm-ok >/dev/null 2>&1 && kvm_ok="yes"
  elif [[ -e /dev/kvm ]]; then
    kvm_ok="likely (kvm-ok not installed to confirm)"
  fi
  echo "${kvm_ok}" >"${REPO_ROOT}/logs/.kvm-support"
  log_info "KVM support: ${kvm_ok}"
}

step_generate_installation_report() {
  bash "${REPO_ROOT}/verify.sh" --report-only || true
  log_ok "report written to logs/verify-report.{md,json}"
}
