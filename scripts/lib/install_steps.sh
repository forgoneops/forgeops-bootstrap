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
  curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR=/usr/local/bin sh
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
  mkdir -p "${projects_dir}" "${REPO_ROOT}/backups" "${REPO_ROOT}/logs" "${REPO_ROOT}/logs/caddy"
  chmod 750 "${projects_dir}"
}

step_deploy_docker_stack() {
  # "Install Portainer/Postgres/Redis/Uptime Kuma" all happen here as one
  # docker compose up — there's no real way to install one service from a
  # compose file independent of the others.
  cd "${REPO_ROOT}"
  bash "${REPO_ROOT}/scripts/render_caddyfile.sh"
  docker pull "${PORTAINER_IMAGE}"
  docker pull "${POSTGRES_IMAGE}"
  docker pull "${REDIS_IMAGE}"
  docker pull "${UPTIME_KUMA_IMAGE}"
  docker pull "${WATCHTOWER_IMAGE}"
  CADDY_IMAGE="${CADDY_IMAGE}" PORTAINER_IMAGE="${PORTAINER_IMAGE}" \
    POSTGRES_IMAGE="${POSTGRES_IMAGE}" REDIS_IMAGE="${REDIS_IMAGE}" \
    UPTIME_KUMA_IMAGE="${UPTIME_KUMA_IMAGE}" WATCHTOWER_IMAGE="${WATCHTOWER_IMAGE}" \
    docker compose up -d caddy portainer postgres redis uptime-kuma
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
