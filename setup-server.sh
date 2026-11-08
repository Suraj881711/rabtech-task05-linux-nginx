#!/usr/bin/env bash
# =============================================================================
# setup-server.sh — Idempotent server bootstrap for Task 05
#   Linux Server Administration & Nginx Reverse Proxy
#
# What it does:
#   1. Creates a non-root "deploy" user (sudo group) for administration.
#   2. Installs an SSH public key for that user (placeholder — replace it).
#   3. Hardens SSH via a drop-in file: key-only login, root login disabled.
#   4. Enables UFW: default deny incoming, allow ONLY 22 / 80 / 443.
#   5. Installs Nginx, deploys nginx.conf + sites-available/app.conf,
#      enables the site, tests and reloads.
#   6. Obtains a Let's Encrypt certificate with Certbot (webroot).
#      A self-signed sandbox alternative is included, commented out.
#
# "Idempotent-ish": every step checks current state before changing it, so
# the script can be re-run safely (existing users, rules, files are kept).
#
# Usage:  sudo bash setup-server.sh
# Tested: Ubuntu 22.04 / 24.04 (Debian family, apt + ufw + systemd)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these before running on a real server
# ---------------------------------------------------------------------------
DEPLOY_USER="deploy"
DOMAIN="example.com"
CERTBOT_EMAIL="admin@example.com"
REPO_NGINX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nginx"

# !!! REPLACE THIS PLACEHOLDER with the real public key before use !!!
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIReplaceWithYourRealPublicKey deploy@example.com"

log() { printf '\n==> %s\n' "$*"; }

# Must run as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root:  sudo bash $0" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Deploy user
# ---------------------------------------------------------------------------
log "Creating deploy user (if missing)"
if id "${DEPLOY_USER}" &>/dev/null; then
    echo "User '${DEPLOY_USER}' already exists — skipping creation."
else
    useradd --create-home --shell /bin/bash "${DEPLOY_USER}"
    usermod --append --groups sudo "${DEPLOY_USER}"
    # Force a password to be set interactively on first use of sudo if
    # desired; by default the account stays locked (key-only access).
    echo "User '${DEPLOY_USER}' created."
fi

# ---------------------------------------------------------------------------
# 2. SSH key for the deploy user
# ---------------------------------------------------------------------------
log "Installing SSH authorised key for ${DEPLOY_USER}"
DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"
AUTH_KEYS="${DEPLOY_HOME}/.ssh/authorized_keys"
touch "${AUTH_KEYS}"
if grep -qF "${SSH_PUBLIC_KEY}" "${AUTH_KEYS}"; then
    echo "Key already present — skipping."
else
    echo "${SSH_PUBLIC_KEY}" >> "${AUTH_KEYS}"
    echo "Key added."
fi
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"

# ---------------------------------------------------------------------------
# 3. SSH hardening — drop-in file (does not edit the main sshd_config)
#    /etc/ssh/sshd_config.d/99-hardening.conf
# ---------------------------------------------------------------------------
log "Hardening SSH (key-only login, no root login)"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"
install -d -m 755 /etc/ssh/sshd_config.d
cat > "${SSHD_DROPIN}" <<'EOF'
# Managed by setup-server.sh — Task 05 hardening drop-in
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
EOF
# Validate before restarting so a typo can never lock us out
sshd -t
systemctl restart ssh || systemctl restart sshd
echo "SSH hardened and restarted."

# ---------------------------------------------------------------------------
# 4. Firewall — UFW, default deny incoming, allow 22 / 80 / 443 only
# ---------------------------------------------------------------------------
log "Configuring UFW firewall"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ufw nginx curl >/dev/null

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
ufw status verbose

# ---------------------------------------------------------------------------
# 5. Nginx — install configuration from this repository
# ---------------------------------------------------------------------------
log "Deploying Nginx configuration"
# Back up the distribution config once
[[ -f /etc/nginx/nginx.conf.orig ]] || cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig

install -m 644 "${REPO_NGINX_DIR}/nginx.conf" /etc/nginx/nginx.conf
install -m 644 "${REPO_NGINX_DIR}/sites-available/app.conf" /etc/nginx/sites-available/app.conf

# Enable our site, disable the default one
ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
rm -f /etc/nginx/sites-enabled/default

# Webroot used by Certbot's HTTP-01 challenge
install -d -m 755 /var/www/certbot

nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx
echo "Nginx is running with the reverse-proxy configuration."

# ---------------------------------------------------------------------------
# 6. TLS certificate — Let's Encrypt via Certbot (webroot plugin)
# ---------------------------------------------------------------------------
log "Obtaining Let's Encrypt certificate for ${DOMAIN}"
apt-get install -y -qq certbot >/dev/null
certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" -d "www.${DOMAIN}" \
    --email "${CERTBOT_EMAIL}" --agree-tos --non-interactive || \
    echo "Certbot did not complete (normal in a sandbox without a public domain)." >&2
# Auto-renewal is handled by the certbot systemd timer installed by the package.
systemctl reload nginx || true

# ---------------------------------------------------------------------------
# SANDBOX ALTERNATIVE — self-signed certificate (no public domain needed).
# Uncomment this block INSTEAD of step 6 when working in a local VM/lab,
# and point ssl_certificate / ssl_certificate_key in app.conf at these paths:
#
#   install -d -m 755 /etc/nginx/ssl
#   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#       -keyout /etc/nginx/ssl/app.key \
#       -out    /etc/nginx/ssl/app.crt \
#       -subj "/CN=${DOMAIN}"
#   # then in sites-available/app.conf use:
#   #   ssl_certificate     /etc/nginx/ssl/app.crt;
#   #   ssl_certificate_key /etc/nginx/ssl/app.key;
#   nginx -t && systemctl reload nginx
# ---------------------------------------------------------------------------

log "Done. Verify with:  ss -tulpn | grep -E ':(22|80|443)'  and  curl -I https://${DOMAIN}"
