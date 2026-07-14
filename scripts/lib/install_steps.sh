#!/usr/bin/env bash
# install_steps.sh - one idempotent function per install.sh step.
# Sourced by install.sh after common.sh. Every function here must be safe
# to call even when the thing it installs/configures is already present.

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
  # Covers: Git, Python, build-essential, curl, wget, jq, ripgrep, fzf, tmux,
  # btop, htop, tree, ncdu, rsync, Fail2Ban, UFW — all plain apt packages.
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES_BASIC[@]}"
}

step_install_uv() {
  if command_exists uv; then
    log_info "uv already installed ($(uv --version))."
    return 0
  fi
  curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR=/usr/local/bin sh
}

step_install_nodejs() {
  if command_exists node && [[ "$(node -v)" == v"${NODE_MAJOR}".* ]]; then
    log_info "Node.js ${NODE_MAJOR}.x already installed ($(node -v))."
    return 0
  fi
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
}

step_install_docker() {
  if command_exists docker; then
    log_info "Docker already installed ($(docker --version))."
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
  command_exists docker || die "Docker must be installed before verifying Compose."
  docker compose version >/dev/null 2>&1 || die "docker compose plugin not available."
  log_ok "docker compose: $(docker compose version --short)"
}

step_install_caddy() {
  if command_exists caddy; then
    log_info "System 'caddy' binary detected — ForgeOps runs Caddy via Docker instead; nothing to do."
    return 0
  fi
  # Caddy itself runs as a container (see docker-compose.yml); this step just
  # pre-pulls the pinned image so `docker compose up` on first boot is fast
  # and so verify.sh can confirm the image is present offline.
  docker pull "${CADDY_IMAGE}"
}

step_create_project_directories() {
  local projects_dir="${PROJECTS_DIR:-/opt/forgeops/projects}"
  mkdir -p "${projects_dir}" "${REPO_ROOT}/backups" "${REPO_ROOT}/logs"
  chmod 750 "${projects_dir}"
}

step_deploy_docker_stack() {
  # Covers: Install Portainer, Install PostgreSQL, Install Redis,
  # Install Uptime Kuma — all delivered as pinned-image containers defined
  # in docker-compose.yml. Docker Compose has no meaningful notion of
  # "installing" one service independently of rendering the stack, so these
  # four spec items are implemented as one idempotent `docker compose up -d`
  # covering all of them (documented in ARCHITECTURE.md).
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
  # Only disable password auth once we've confirmed at least one key-based
  # login is possible (an authorized_keys file exists for root or the sudo
  # user) — never lock out the operator.
  local key_present=0
  for home in /root /home/*; do
    [[ -s "${home}/.ssh/authorized_keys" ]] && key_present=1
  done
  if [[ "${key_present}" -eq 0 ]]; then
    log_warn "No authorized_keys found for any user — leaving password auth ENABLED so you don't get locked out. Add an SSH key, then re-run install.sh to harden SSH."
    cat >"${sshd_config}" <<'EOF'
# ForgeOps: password auth left enabled — no SSH key detected yet.
PermitRootLogin prohibit-password
EOF
  else
    cat >"${sshd_config}" <<'EOF'
# ForgeOps SSH hardening — applied because at least one authorized_keys file
# was verified present at install time.
PasswordAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  fi
  sshd -t || die "Generated sshd config is invalid — aborting before reload."
  systemctl reload ssh
}

step_configure_firewall() {
  ufw --force reset
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
  log_info "KVM support: ${kvm_ok} (informational only — no KVM-dependent components installed in v1)."
}

step_generate_installation_report() {
  bash "${REPO_ROOT}/verify.sh" --report-only || true
  log_ok "Installation report written to logs/verify-report.md and logs/verify-report.json"
}
