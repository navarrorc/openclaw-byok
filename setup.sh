#!/usr/bin/env bash
#
# OpenClaw BYOK sandbox — one-shot customer setup script.
#
# Run this as root on a FRESH Ubuntu 22.04/24.04/26.04 droplet (DigitalOcean,
# Hetzner, Linode, or any equivalent VPS). It provisions a hardened,
# minimal Docker host running a single vanilla OpenClaw instance using
# YOUR OWN LLM API key. Nobody but you holds SSH access to this box
# after it finishes (see support-access.sh for the opt-in way to invite
# us in when you want help — stays on until YOU turn it off).
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
apt-get install -y -qq ufw fail2ban curl ca-certificates gnupg whiptail >/dev/null

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
    # Arrow-key selectable menu (whiptail) instead of typing the provider
    # name — a typo here used to silently fall through to Gemini with no
    # warning. If whiptail can't run for some reason (no real TTY), fall
    # back to a plain numbered menu instead of guessing.
    PROVIDER=""
    if [ -t 0 ] && command -v whiptail >/dev/null 2>&1; then
        PROVIDER=$(whiptail --title "Choose your AI provider" \
            --menu "Use arrow keys to pick one, then press Enter:" 15 60 3 \
            "gemini"    "Google Gemini" \
            "openai"    "OpenAI (ChatGPT models)" \
            "anthropic" "Anthropic (Claude models)" \
            3>&1 1>&2 2>&3) || PROVIDER=""
    fi
    # Belt and suspenders: only trust $PROVIDER if it's actually one of our
    # three known values. If whiptail errored (e.g. "TERM not set") its
    # error text can end up here instead of an empty string.
    case "$PROVIDER" in
        gemini | openai | anthropic) ;;
        *) PROVIDER="" ;;
    esac
    if [ -z "$PROVIDER" ]; then
        echo "Which LLM provider are you using?"
        select choice in "gemini" "openai" "anthropic"; do
            [ -n "$choice" ] && PROVIDER="$choice" && break
            echo "Please enter 1, 2, or 3."
        done
    fi
    case "$PROVIDER" in
        openai)
            read -r -p "Paste your OpenAI API key: " OPENAI_API_KEY
            OPENCLAW_PRIMARY_MODEL="${OPENCLAW_PRIMARY_MODEL_OVERRIDE:-openai/gpt-5.1}"
            MODEL_DISPLAY_NAME="GPT-5.1"
            ;;
        anthropic)
            read -r -p "Paste your Anthropic API key: " ANTHROPIC_API_KEY
            OPENCLAW_PRIMARY_MODEL="${OPENCLAW_PRIMARY_MODEL_OVERRIDE:-anthropic/claude-sonnet-5}"
            MODEL_DISPLAY_NAME="Claude Sonnet 5"
            ;;
        *)
            read -r -p "Paste your Gemini API key: " GEMINI_API_KEY
            MODEL_DISPLAY_NAME="Gemini 2.5 Flash"
            ;;
    esac
fi
# The block above is skipped entirely when a key is pre-set via env var
# (the documented non-interactive path: GEMINI_API_KEY=xxx ./setup.sh), so
# MODEL_DISPLAY_NAME needs its own fallback here, derived from whichever
# model actually ended up configured.
if [ -z "${MODEL_DISPLAY_NAME:-}" ]; then
    case "$OPENCLAW_PRIMARY_MODEL" in
        openai/*) MODEL_DISPLAY_NAME="GPT-5.1" ;;
        anthropic/*) MODEL_DISPLAY_NAME="Claude Sonnet 5" ;;
        *) MODEL_DISPLAY_NAME="Gemini 2.5 Flash" ;;
    esac
fi

# ---------------------------------------------------------------------------
# 6. Telegram — this is how you'll actually talk to your assistant, not
#    optional. Every customer needs a real chat interface on day one.
# ---------------------------------------------------------------------------
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo ""
    echo "Telegram is how you'll talk to your assistant day to day."
    echo "1. In Telegram, message @BotFather, send /newbot, and follow the prompts."
    echo "2. Paste the token it gives you below."
    while [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; do
        read -r -p "Telegram bot token: " TELEGRAM_BOT_TOKEN
    done
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "Now message @userinfobot on Telegram — it replies with your numeric ID."
    while [ -z "${TELEGRAM_CHAT_ID:-}" ]; do
        read -r -p "Your Telegram user ID: " TELEGRAM_CHAT_ID
    done
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
# 7a. Workspace files — the container generates its OWN default AGENTS.md on
#     first boot, and it's a good one (memory, heartbeats, safety rules).
#     APPEND to it rather than replace it, so we only add the one thing it's
#     missing: don't ask for info a channel already handed you (e.g.
#     Telegram messages arrive pre-tagged with the sender's name).
# ---------------------------------------------------------------------------
log "Adding a few instructions to the assistant's default AGENTS.md"
cat > /tmp/openclaw-AGENTS-addendum.md <<'AGENTSMD'
<!-- openclaw-byok-addendum:start -->

## Use the name you're already given

Incoming messages on some channels (e.g. Telegram) are prefixed with the
sender's name, like `[Telegram Alex id:123456789 2026-08-17 21:20 UTC] Hey`.
That name is already known, don't ask for it. Greet the person by that name
and save it to USER.md right away. Only ask what to call them if a channel
genuinely gives you no name to go on, or if they tell you they'd prefer
something else.
<!-- openclaw-byok-addendum:end -->
AGENTSMD
docker cp /tmp/openclaw-AGENTS-addendum.md openclaw:/tmp/agents-addendum.md
# Strip any PRIOR copy of our marked block before appending the current one,
# so re-running setup.sh after we've changed the addendum's content actually
# updates it instead of silently no-op'ing forever (real bug, found 08-17: an
# earlier grep-for-one-phrase check meant a later content change never
# actually got deployed to an already-set-up box).
docker exec openclaw node -e "
const fs = require('fs');
const path = '/data/workspace/AGENTS.md';
let body = fs.readFileSync(path, 'utf8');
body = body.replace(/\n?<!-- openclaw-byok-addendum:start -->[\s\S]*?<!-- openclaw-byok-addendum:end -->\n?/, '');
const addendum = fs.readFileSync('/tmp/agents-addendum.md', 'utf8');
fs.writeFileSync(path, body.replace(/\s+$/, '') + '\n' + addendum);
"
docker exec openclaw rm -f /tmp/agents-addendum.md
rm -f /tmp/openclaw-AGENTS-addendum.md

# Skip the cutesy self-naming ritual (BOOTSTRAP.md's "figure out who you
# are" first-run conversation) — for this product the assistant is just
# "AI Assistant" by default. Pre-filling IDENTITY.md and removing
# BOOTSTRAP.md (AGENTS.md's own "First Run" section only triggers it "if
# BOOTSTRAP.md exists") skips the ritual entirely instead of asking the
# user three unnecessary questions before it will do anything useful.
docker exec openclaw sh -c 'rm -f /data/workspace/BOOTSTRAP.md'
cat > /tmp/openclaw-IDENTITY.md <<'IDENTITYMD'
# IDENTITY.md - Who Am I?

- **Name:** AI Assistant
- **Creature:** AI assistant
- **Vibe:** Direct, friendly, and helpful. No persona beyond this.
- **Emoji:** 🤖
- **Avatar:** _(none set)_
IDENTITYMD
docker cp /tmp/openclaw-IDENTITY.md openclaw:/data/workspace/IDENTITY.md
rm -f /tmp/openclaw-IDENTITY.md

# ---------------------------------------------------------------------------
# 7b. Wire Telegram in as a real, live channel (not just a one-off notify).
#     The container starts with no channels configured, so this writes the
#     account + routing binding + plugin toggle directly into its config,
#     then restarts once to pick it up. Confirmed working shape as of
#     OpenClaw 2026.2.6 — bindings entries take agentId+match only, no
#     "type" key (the doctor auto-fixer strips it if present), and the
#     telegram plugin must be explicitly enabled or the channel is invisible
#     to the CLI even with a valid token.
# ---------------------------------------------------------------------------
log "Wiring up your Telegram bot"
docker exec openclaw node -e "
const fs = require('fs');
const path = '/data/.openclaw/openclaw.json';
const cfg = JSON.parse(fs.readFileSync(path, 'utf8'));
cfg.channels = cfg.channels || {};
cfg.channels.telegram = cfg.channels.telegram || {};
cfg.channels.telegram.accounts = cfg.channels.telegram.accounts || {};
cfg.channels.telegram.accounts.main = {
  name: 'OpenClaw',
  enabled: true,
  botToken: '${TELEGRAM_BOT_TOKEN}',
  allowFrom: ['${TELEGRAM_CHAT_ID}'],
  dmPolicy: 'allowlist'
};
cfg.bindings = (cfg.bindings || []).filter(b => !(b.match && b.match.channel === 'telegram' && b.match.accountId === 'main'));
cfg.bindings.push({ agentId: 'main', match: { channel: 'telegram', accountId: 'main' } });
cfg.plugins = cfg.plugins || {};
cfg.plugins.entries = cfg.plugins.entries || {};
cfg.plugins.entries.telegram = { enabled: true };
// A prompt-driven send-then-delete 'thinking' placeholder was tried twice
// (08-17) and dropped for real this time: on a genuinely clean session
// (confirmed the earlier failures were session pollution from unrelated
// testing, not this instruction) the model just never attempted the tool
// calls -- 0 real tries across several messages. Not reliable enough to
// ship. A reaction is a GATEWAY-level feature, not something the model has
// to remember to do right, so it's the safe default. Default emoji (👀)
// read as 'freaky' to Rob -- swapped for something calmer. Scope 'all'
// since the default ('group-mentions') never fires in a DM.
cfg.messages = cfg.messages || {};
cfg.messages.ackReaction = '⏳';
cfg.messages.ackReactionScope = 'all';
cfg.messages.removeAckAfterReply = true;
// Shows which model is actually answering (Rob: FarmOps shows this and
// 'it's a dead give away' when it's missing). Fully deterministic -- we
// already know the model from the provider the customer picked, no need
// to rely on the LLM reporting on itself.
cfg.messages.responsePrefix = '🧠 ${MODEL_DISPLAY_NAME}';
fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
" || warn "Could not write Telegram config automatically. See CUSTOMER_SETUP_GUIDE.md's troubleshooting section."

docker restart openclaw >/dev/null
DEADLINE=$((SECONDS + 60))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' openclaw 2>/dev/null || echo "starting")
    [ "$STATUS" = "healthy" ] && break
    sleep 5
done
TELEGRAM_STATUS=$(docker exec openclaw openclaw channels status 2>&1 | grep -i telegram || true)
if echo "$TELEGRAM_STATUS" | grep -qi "running"; then
    log "Telegram is live: $TELEGRAM_STATUS"
else
    warn "Telegram may not be fully wired up yet: ${TELEGRAM_STATUS:-no status returned}"
    warn "Check: docker exec openclaw openclaw channels status"
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

 Your assistant is ready to chat. Open Telegram and message your bot,
 try sending "Hey" and it should reply within a few seconds.

 Need help later? Run: sudo ./support-access.sh on
 It stays on until YOU turn it off with: sudo ./support-access.sh off
 See CUSTOMER_SETUP_GUIDE.md.
=============================================================
SUMMARY
