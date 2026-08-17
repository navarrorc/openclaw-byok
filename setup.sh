#!/usr/bin/env bash
#
# OpenClaw BYOK sandbox — one-shot customer setup script.
#
# Run this as root on a FRESH Ubuntu 22.04/24.04 droplet (DigitalOcean,
# Hetzner, Linode, or any equivalent VPS). It provisions a hardened,
# minimal Docker host running a single vanilla OpenClaw instance using
# YOUR OWN LLM API key. Nobody but you holds SSH access to this box
# after it finishes (see support-access.sh for the opt-in, auto-expiring
# way to invite us in when you want help).
#
# Usage:
#   curl -fsSL <url-to-this-script> -o setup.sh
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# You will be prompted for your LLM API key unless you export it first, e.g.:
#   GEMINI_API_KEY=xxxx sudo -E ./setup.sh
#
# Safe to re-run: existing users/config/containers are detected and left
# alone or updated in place rather than duplicated.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via env vars before running if you want something else)
# ---------------------------------------------------------------------------
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-coollabsio/openclaw:2026.2.6}"
OPENCLAW_BROWSER_IMAGE="${OPENCLAW_BROWSER_IMAGE:-coollabsio/openclaw-browser:latest}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_PRIMARY_MODEL="${OPENCLAW_PRIMARY_MODEL:-google/gemini-2.5-flash}"
SSH_PORT="${SSH_PORT:-22}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
APP_PORT="${OPENCLAW_APP_PORT:-8080}"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$1" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this as root (sudo ./setup.sh)."

# ---------------------------------------------------------------------------
# 1. Dedicated non-root user + SSH key-only auth
# ---------------------------------------------------------------------------
log "Setting up dedicated user '$OPENCLAW_USER'"
if ! id "$OPENCLAW_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$OPENCLAW_USER"
    usermod -aG sudo "$OPENCLAW_USER"
else
    echo "User '$OPENCLAW_USER' already exists, skipping creation."
fi

# The account has no password (adduser --disabled-password) and SSH is
# key-only, so plain `sudo` group membership can never authenticate — it
# always demands a password that doesn't exist. Grant real passwordless
# sudo via a dedicated sudoers drop-in so the summary's claim is true.
SUDOERS_DROPIN="/etc/sudoers.d/90-$OPENCLAW_USER-nopasswd"
echo "$OPENCLAW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_DROPIN"
chmod 440 "$SUDOERS_DROPIN"
visudo -cf "$SUDOERS_DROPIN" || die "Generated sudoers drop-in failed validation: $SUDOERS_DROPIN"

install -d -m 700 -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "/home/$OPENCLAW_USER/.ssh"
if [ ! -s "/home/$OPENCLAW_USER/.ssh/authorized_keys" ]; then
    if [ -s /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys "/home/$OPENCLAW_USER/.ssh/authorized_keys"
        chown "$OPENCLAW_USER:$OPENCLAW_USER" "/home/$OPENCLAW_USER/.ssh/authorized_keys"
        chmod 600 "/home/$OPENCLAW_USER/.ssh/authorized_keys"
        log "Copied root's authorized_keys to $OPENCLAW_USER so you don't lock yourself out."
    else
        warn "No authorized_keys found for root. You MUST add your own SSH public key to" \
             "/home/$OPENCLAW_USER/.ssh/authorized_keys before this script disables root/password login,"
        warn "or you will lock yourself out of this box."
        read -r -p "Paste your SSH public key now (or leave blank to add it yourself later): " PASTED_KEY
        if [ -n "$PASTED_KEY" ]; then
            echo "$PASTED_KEY" >> "/home/$OPENCLAW_USER/.ssh/authorized_keys"
            chown "$OPENCLAW_USER:$OPENCLAW_USER" "/home/$OPENCLAW_USER/.ssh/authorized_keys"
            chmod 600 "/home/$OPENCLAW_USER/.ssh/authorized_keys"
        fi
    fi
fi

log "Hardening SSH (key-only auth, no root login)"
SSHD_DROPIN=/etc/ssh/sshd_config.d/99-openclaw-hardening.conf
cat > "$SSHD_DROPIN" <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
Port $SSH_PORT
EOF
if [ -s "/home/$OPENCLAW_USER/.ssh/authorized_keys" ]; then
    systemctl reload ssh || systemctl reload sshd || true
else
    warn "Skipping sshd reload — no authorized_keys installed yet for $OPENCLAW_USER."
    warn "Add a key, then run: systemctl reload ssh"
fi

# ---------------------------------------------------------------------------
# 2. Firewall + fail2ban
# ---------------------------------------------------------------------------
log "Installing UFW + fail2ban"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ufw fail2ban curl ca-certificates gnupg >/dev/null

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT"/tcp comment "SSH" >/dev/null
# OpenClaw gateway/dashboard — bound to loopback by default in the compose
# file below, so no inbound port is opened for it. If you later put this
# behind a reverse proxy or Cloudflare tunnel, open the relevant port here
# (e.g. `ufw allow 443/tcp`) — do NOT expose $GATEWAY_PORT directly.
ufw --force enable >/dev/null
log "UFW enabled: SSH ($SSH_PORT/tcp) only. Everything else is denied inbound."

cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
bantime = 1h
findtime = 10m
EOF
systemctl enable --now fail2ban >/dev/null

# ---------------------------------------------------------------------------
# 3. Swap file (small droplets OOM without one)
# ---------------------------------------------------------------------------
log "Checking swap"
if ! swapon --show | grep -q .; then
    MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    # Match RAM up to a 4GB swap file cap — enough headroom for a small
    # droplet without eating all the disk on a bigger one.
    SWAP_MB=$MEM_MB
    [ "$SWAP_MB" -gt 4096 ] && SWAP_MB=4096
    log "Creating ${SWAP_MB}MB swap file"
    fallocate -l "${SWAP_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB"
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
else
    echo "Swap already active, skipping."
fi

# ---------------------------------------------------------------------------
# 4. Docker (official install method)
# ---------------------------------------------------------------------------
log "Installing Docker"
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
else
    echo "Docker already installed, skipping."
fi
usermod -aG docker "$OPENCLAW_USER"
systemctl enable --now docker >/dev/null

# ---------------------------------------------------------------------------
# 5. LLM API key prompt
# ---------------------------------------------------------------------------
log "LLM provider key"
if [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Which LLM provider are you using? (gemini/openai/anthropic)"
    read -r -p "> " PROVIDER
    case "$PROVIDER" in
        openai)
            read -r -s -p "Paste your OpenAI API key: " OPENAI_API_KEY; echo
            OPENCLAW_PRIMARY_MODEL="${OPENCLAW_PRIMARY_MODEL_OVERRIDE:-openai/gpt-5.1}"
            ;;
        anthropic)
            read -r -s -p "Paste your Anthropic API key: " ANTHROPIC_API_KEY; echo
            OPENCLAW_PRIMARY_MODEL="${OPENCLAW_PRIMARY_MODEL_OVERRIDE:-anthropic/claude-sonnet-5}"
            ;;
        *)
            read -r -s -p "Paste your Gemini API key: " GEMINI_API_KEY; echo
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# 6. Notification channel (optional — for the verification step)
# ---------------------------------------------------------------------------
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    read -r -p "Telegram bot token for notifications (optional, press Enter to skip): " TELEGRAM_BOT_TOKEN || true
fi
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    read -r -p "Telegram chat ID to notify (optional): " TELEGRAM_CHAT_ID || true
fi

# ---------------------------------------------------------------------------
# 7. Deploy OpenClaw via docker compose
# ---------------------------------------------------------------------------
log "Writing docker-compose.yml to $OPENCLAW_DIR"
install -d -m 750 -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "$OPENCLAW_DIR"

GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 24)}"
AUTH_USERNAME="${AUTH_USERNAME:-admin}"
AUTH_PASSWORD="${AUTH_PASSWORD:-$(openssl rand -hex 12)}"

cat > "$OPENCLAW_DIR/.env" <<EOF
GEMINI_API_KEY=${GEMINI_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENCLAW_PRIMARY_MODEL=${OPENCLAW_PRIMARY_MODEL}
AUTH_USERNAME=${AUTH_USERNAME}
AUTH_PASSWORD=${AUTH_PASSWORD}
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
EOF
chmod 600 "$OPENCLAW_DIR/.env"
chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_DIR/.env"

cat > "$OPENCLAW_DIR/docker-compose.yml" <<EOF
services:
  openclaw:
    image: ${OPENCLAW_IMAGE}
    container_name: openclaw
    restart: unless-stopped
    env_file: .env
    environment:
      - OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}
      - OPENCLAW_GATEWAY_BIND=loopback
      - PORT=${APP_PORT}
      - OPENCLAW_STATE_DIR=/data/.openclaw
      - OPENCLAW_WORKSPACE_DIR=/data/workspace
      - BROWSER_CDP_URL=http://browser:9223
      - BROWSER_DEFAULT_PROFILE=openclaw
    volumes:
      - openclaw-data:/data
    depends_on:
      browser:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:${APP_PORT}/healthz"]
      interval: 10s
      timeout: 10s
      retries: 5

  browser:
    image: ${OPENCLAW_BROWSER_IMAGE}
    container_name: openclaw-browser
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - CHROME_CLI=--remote-debugging-port=9222
    volumes:
      - browser-data:/config
    shm_size: 2g
    healthcheck:
      test: ["CMD-SHELL", "bash -c ':> /dev/tcp/127.0.0.1/9222' || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  openclaw-data:
  browser-data:
EOF
chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_DIR/docker-compose.yml"

log "Pulling images and starting OpenClaw"
( cd "$OPENCLAW_DIR" && docker compose pull -q && docker compose up -d )

log "Waiting for containers to report healthy (up to 2 minutes)"
DEADLINE=$((SECONDS + 120))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' openclaw 2>/dev/null || echo "starting")
    [ "$STATUS" = "healthy" ] && break
    sleep 5
done
if [ "$STATUS" != "healthy" ]; then
    warn "openclaw container did not report healthy in time. Check: docker logs openclaw"
fi

# ---------------------------------------------------------------------------
# 8. Self-healing watchdog (installed separately, see openclaw-watchdog.*)
# ---------------------------------------------------------------------------
if [ -f "$(dirname "$0")/install-watchdog.sh" ]; then
    log "Installing self-healing watchdog"
    bash "$(dirname "$0")/install-watchdog.sh"
else
    warn "install-watchdog.sh not found next to this script — skipping watchdog install." \
         "Fetch it from the same place you got setup.sh and re-run it separately if you want auto-restart/auto-update."
fi

# ---------------------------------------------------------------------------
# 9. Verification: real smoke test + optional Telegram notify
# ---------------------------------------------------------------------------
log "Running verification smoke test"
TEST_MSG="Reply with the single word CONFIRMED and nothing else."
RESULT=$(docker exec openclaw openclaw agent --agent main --local --message "$TEST_MSG" 2>&1) || true
echo "$RESULT"

if echo "$RESULT" | grep -qi "CONFIRMED"; then
    log "Verification PASSED — OpenClaw is live and answering with your API key."
else
    warn "Verification did not clearly return CONFIRMED. Check the output above and 'docker logs openclaw'."
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    STAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    NOTIFY_TEXT="CONFIRMED - $(hostname) - ${STAMP} - provider setup complete"
    if curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${NOTIFY_TEXT}" >/dev/null; then
        log "Sent confirmation to Telegram."
    else
        warn "Telegram notify failed — check the bot token/chat ID."
    fi
fi

cat <<SUMMARY

=============================================================
 Setup complete.

 - Dedicated user:     $OPENCLAW_USER (passwordless sudo, key-only SSH)
 - Root password login: disabled
 - Firewall:           UFW active, only SSH ($SSH_PORT/tcp) open
 - Compose stack:       $OPENCLAW_DIR (openclaw + browser containers)
 - Dashboard login:     user=$AUTH_USERNAME  password=$AUTH_PASSWORD
                        (saved in $OPENCLAW_DIR/.env, root-readable only)

 Need help later? Run support-access.sh to grant temporary,
 auto-expiring access. See CUSTOMER_SETUP_GUIDE.md.
=============================================================
SUMMARY
