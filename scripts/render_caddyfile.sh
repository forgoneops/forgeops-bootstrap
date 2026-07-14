#!/usr/bin/env bash
# Generates docker/Caddyfile from templates/Caddyfile.template, based on
# the current .env (DOMAIN, EXPOSE_PORTAINER, EXPOSE_UPTIME_KUMA).
#
# Called by install.sh and update.sh. Safe to run again any time.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

[[ -f "${ENV_FILE}" ]] || die "no .env found — run install.sh first"
# shellcheck disable=SC1090
source "${ENV_FILE}"

OUT="${REPO_ROOT}/docker/Caddyfile"
TEMPLATE="${REPO_ROOT}/templates/Caddyfile.template"
[[ -r "${TEMPLATE}" ]] || die "missing template: ${TEMPLATE}"

domain_or_localhost="${DOMAIN:-localhost}"
sed "s|{{DOMAIN_OR_LOCALHOST}}|${domain_or_localhost}|g" "${TEMPLATE}" >"${OUT}"

if [[ -n "${DOMAIN:-}" ]]; then
  {
    echo ""
    echo "# --- Auto-generated site blocks (DOMAIN=${DOMAIN}) ---"
    if [[ "${EXPOSE_PORTAINER:-false}" == "true" ]]; then
      cat <<EOF
portainer.${DOMAIN} {
	reverse_proxy forgeops_portainer:9000
	encode gzip zstd
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
	}
	log
}
EOF
    fi
    if [[ "${EXPOSE_UPTIME_KUMA:-false}" == "true" ]]; then
      cat <<EOF
status.${DOMAIN} {
	reverse_proxy forgeops_uptime_kuma:3001
	encode gzip zstd
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
	}
	log
}
EOF
    fi
  } >>"${OUT}"
fi

log_ok "Rendered ${OUT}"
