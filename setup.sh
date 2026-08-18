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
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-coollabsio/openclaw:2026.7.1-2}"
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
THINKING_BUBBLE_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
THINKING_BUBBLE_MODEL_LABEL=${MODEL_DISPLAY_NAME:-}
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
# 7a0. Force the workspace bootstrap. On older images AGENTS.md/SOUL.md/etc
#      already existed by this point (created during the container's own
#      boot sequence). On 2026.6+ that no longer happens automatically --
#      confirmed live: the files genuinely don't exist until something
#      triggers a real agent run. One throwaway local call forces OpenClaw
#      to generate its own default workspace files, which the next step
#      then appends to.
# ---------------------------------------------------------------------------
log "Bootstrapping the assistant's workspace files"
docker exec openclaw openclaw agent --agent main --local --message "." >/dev/null 2>&1 || true

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

## Show it, don't just describe it

When the user asks for something visual — a dashboard, a form, a small
interactive tool, anything better shown than described in chat — build a
complete, self-contained HTML page (inline CSS/JS, no external build step)
and call `publish_website` with it. Share the link it returns in your reply
as plain text, not as a button — Telegram will auto-link it. Calling
`publish_website` again replaces the page currently open for this chat, so
just call it again with updated HTML rather than asking to "close" first.
Call `close_website` when the user says they're done with it or asks to
close it.
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
# 7a1. Install the cloudflared static binary INSIDE the openclaw container.
#      The website plugin (installed below) spawns `cloudflared tunnel --url
#      http://127.0.0.1:<port>` from plugin code running in-process inside
#      that container, so the binary has to be on PATH there, not just on
#      this VPS host. Cloudflare ships a single dependency-free static
#      binary per architecture with no account/install step — download the
#      right one, docker cp it onto the same PATH directory node already
#      resolves from (confirmed live: `docker exec openclaw which node` ->
#      /usr/local/bin/node), chmod +x, verify.
# ---------------------------------------------------------------------------
log "Installing cloudflared (for the website plugin's Quick Tunnels)"
case "$(uname -m)" in
    x86_64|amd64)   CLOUDFLARED_ARCH="amd64" ;;
    aarch64|arm64)  CLOUDFLARED_ARCH="arm64" ;;
    *) die "Unsupported architecture for cloudflared: $(uname -m)" ;;
esac
curl -fsSL -o /tmp/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}"
docker cp /tmp/cloudflared openclaw:/usr/local/bin/cloudflared
docker exec openclaw chmod +x /usr/local/bin/cloudflared
rm -f /tmp/cloudflared
if docker exec openclaw cloudflared --version >/dev/null 2>&1; then
    log "cloudflared installed: $(docker exec openclaw cloudflared --version)"
else
    warn "cloudflared did not install correctly — the website plugin's publish_website tool will fail until this is fixed."
fi

# ---------------------------------------------------------------------------
# 7a2. Install the "thinking bubble" plugin — the real, deterministic
#      version of the FarmOps/Nelita pattern. Sends a placeholder message on
#      Telegram the instant a reply starts generating, then edits that SAME
#      message in place with the real answer. This is plain code (not a
#      prompt instruction), using OpenClaw's message-lifecycle plugin hooks
#      (before_agent_run / message_sending), introduced in OpenClaw 2026.6+
#      — this is why OPENCLAW_IMAGE was bumped off 2026.2.x.
# ---------------------------------------------------------------------------
log "Installing the thinking-bubble plugin"
PLUGIN_DIR=/tmp/openclaw-thinking-bubble
mkdir -p "$PLUGIN_DIR"
cat > "$PLUGIN_DIR/openclaw.plugin.json" <<'PLUGINJSON'
{
  "id": "thinking-bubble",
  "name": "Thinking Bubble",
  "description": "Sends a placeholder message on Telegram when a reply starts generating, then edits it in place with the real answer once it's ready.",
  "version": "1.0.0",
  "activation": {
    "onStartup": true
  },
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {}
  }
}
PLUGINJSON
cat > "$PLUGIN_DIR/index.ts" <<'PLUGINTS'
// Thinking Bubble plugin
//
// Replicates the FarmOps/Nelita pattern: send a placeholder message the
// instant a reply starts generating, then delete that message right before
// the real answer is delivered as a fresh message. It should visibly
// disappear, not turn into the answer in place (Rob, 08-18: "it stays
// around, and it should disappear"). No LLM involvement -- this is plain
// code that runs on every turn, not a prompt instruction the model has to
// remember to follow (that approach was tried and proved unreliable -- see
// ARCHITECTURE.md).
//
// Uses the Telegram Bot API directly (sendMessage / deleteMessage), the
// same way FarmOps' own bridge does it -- OpenClaw's plugin hooks give us
// the right moments to act (message_received, reply_payload_sending), but
// the actual send/delete calls are just plain HTTPS, nothing
// framework-specific.
//
// Note: before_agent_run was tried first and never fired even once, for
// any real message (confirmed live 08-18) -- it's gated behind
// hooks.allowConversationAccess and something about that permission grant
// wasn't taking effect. message_received needs no special permission and
// fires on the raw inbound message before agent routing even happens, an
// earlier and simpler point to act from anyway.
//
// message_sending was tried next for the delivery-side hook and never
// fired either (confirmed live 08-18 across several real messages) --
// it appears to only cover explicit tool-initiated sends, not the normal
// agent-turn reply. reply_payload_sending is the hook that actually fires
// for a turn's final reply routed back to the originating channel.
//
// Config injection (ctx.pluginConfig) was also confirmed empty for both
// hooks in this OpenClaw version (live debug 08-18: event.context === {}).
// So the bot token and model label come from process.env instead --
// setup.sh writes them into .env, which docker-compose already passes
// through to the container.
//
// The manifest must set activation.onStartup: true (openclaw.plugin.json)
// -- this plugin has no tools/channels to give the loader a lazy trigger,
// and OpenClaw no longer startup-loads plugins implicitly. Without it,
// `openclaw plugins list` still misleadingly reports status "loaded", but
// register() is never actually called by the live gateway (confirmed live
// 08-18 via a debug log at the top of register()).
//
// The model tag (e.g. "🧠 Gemini 2.5 Flash") is baked into the PLACEHOLDER
// text only -- it's the loading indicator, shown while the real answer is
// generating, and never appears on the final answer. Do not also set
// messages.responsePrefix in config, or the tag will show up twice.
//
// Correlation is keyed by session key, not chat id -- message_received's
// event carries senderId/chatId but no sessionKey-independent id shared
// with reply_payload_sending, whose event carries sessionKey/runId/channel
// but NO chat or sender id at all (confirmed live 08-18: reply_payload_sending
// events look like {payload, kind, channel, sessionKey, runId, usageState},
// with an empty ctx). sessionKey is the one field both events share.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

type Placeholder = { chatId: string; messageId: number };

const pendingBySession = new Map<string, Placeholder>();

function placeholderText(): string {
  const label = process.env.THINKING_BUBBLE_MODEL_LABEL;
  return label ? `🧠 ${label} …` : "…";
}

async function tg(botToken: string, method: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json().catch(() => ({}))) as {
    ok?: boolean;
    result?: { message_id?: number };
    description?: string;
  };
  if (!json.ok) {
    throw new Error(`Telegram ${method} failed: ${json.description ?? res.status}`);
  }
  return json;
}

function extractChatId(event: Record<string, unknown>, ctx: Record<string, unknown>): string | undefined {
  const metadata = (event as { metadata?: Record<string, unknown> }).metadata ?? {};
  const candidates = [
    (metadata as { senderId?: string | number }).senderId,
    (event as { chatId?: string | number }).chatId,
    (event as { senderId?: string | number }).senderId,
    (ctx as { chatId?: string | number }).chatId,
    (ctx as { senderId?: string | number }).senderId,
    (ctx as { channelContext?: { chat?: { id?: string | number } } }).channelContext?.chat?.id,
  ];
  for (const c of candidates) {
    if (c !== undefined && c !== null && String(c).length > 0) return String(c);
  }
  return undefined;
}

function extractProvider(event: Record<string, unknown>, ctx: Record<string, unknown>): string | undefined {
  const metadata = (event as { metadata?: Record<string, unknown> }).metadata ?? {};
  return (
    (metadata as { provider?: string }).provider ??
    (event as { channel?: string }).channel ??
    (ctx as { messageProvider?: string }).messageProvider ??
    (ctx as { channel?: string }).channel
  );
}

function extractSessionKey(event: Record<string, unknown>, ctx: Record<string, unknown>): string | undefined {
  return (
    (event as { sessionKey?: string }).sessionKey ??
    (ctx as { sessionKey?: string }).sessionKey
  );
}

export default definePluginEntry({
  id: "thinking-bubble",
  name: "Thinking Bubble",
  description: "Send a placeholder Telegram message while a reply generates, then delete it once the real answer is about to arrive.",
  register(api) {
    api.on(
      "message_received",
      async (event) => {
        const ctx = (event.context ?? {}) as Record<string, unknown>;
        const botToken = process.env.THINKING_BUBBLE_BOT_TOKEN;

        if (!botToken) return;

        const provider = extractProvider(event as Record<string, unknown>, ctx);
        const chatId = extractChatId(event as Record<string, unknown>, ctx);
        const sessionKey = extractSessionKey(event as Record<string, unknown>, ctx);

        if (provider !== "telegram" || !chatId || !sessionKey) return;

        try {
          const sent = await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text: placeholderText(),
          });
          const messageId = sent.result?.message_id;
          if (typeof messageId === "number") {
            pendingBySession.set(sessionKey, { chatId, messageId });
          }
        } catch (err) {
          console.error("[thinking-bubble] failed to send placeholder:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );

    api.on(
      "reply_payload_sending",
      async (event) => {
        const ctx = (event.context ?? {}) as Record<string, unknown>;
        const botToken = process.env.THINKING_BUBBLE_BOT_TOKEN;

        const sessionKey = extractSessionKey(event as Record<string, unknown>, ctx);

        if (!botToken || !sessionKey) return;

        const placeholder = pendingBySession.get(sessionKey);
        if (!placeholder) return; // nothing we're tracking for this session

        pendingBySession.delete(sessionKey); // one-shot: don't act twice for the same placeholder

        // Delete the placeholder and let the normal send path deliver the
        // real answer as a fresh message -- the bubble should disappear,
        // not turn into the answer in place.
        try {
          await tg(botToken, "deleteMessage", {
            chat_id: placeholder.chatId,
            message_id: placeholder.messageId,
          });
        } catch (err) {
          console.error("[thinking-bubble] failed to delete placeholder:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );
  },
});
PLUGINTS
docker exec openclaw mkdir -p /data/workspace/.openclaw/extensions/thinking-bubble
docker cp "$PLUGIN_DIR/openclaw.plugin.json" openclaw:/data/workspace/.openclaw/extensions/thinking-bubble/openclaw.plugin.json
docker cp "$PLUGIN_DIR/index.ts" openclaw:/data/workspace/.openclaw/extensions/thinking-bubble/index.ts
rm -rf "$PLUGIN_DIR"

# ---------------------------------------------------------------------------
# 7a3. Install the "website" plugin — lets the agent publish a self-contained
#      HTML page it generates (dashboard/form/small tool) as a real, live,
#      token-gated website reachable from Telegram, via a per-session
#      Cloudflare Quick Tunnel (cloudflared, installed above), and close it
#      again on request. No idle auto-teardown by design — close_website is
#      the only way it comes down, matching support-access.sh's explicit
#      on/off philosophy elsewhere in this product.
# ---------------------------------------------------------------------------
log "Installing the website plugin"
PLUGIN_DIR=/tmp/openclaw-website
mkdir -p "$PLUGIN_DIR"
cat > "$PLUGIN_DIR/openclaw.plugin.json" <<'WEBSITEPLUGINJSON'
{
  "id": "website",
  "name": "Website",
  "description": "Publish a self-contained HTML page the agent builds as a live, token-gated website reachable from Telegram (via a Cloudflare Quick Tunnel), and close it when done.",
  "version": "1.0.0",
  "contracts": {
    "tools": ["publish_website", "close_website"]
  },
  "activation": {
    "onStartup": true
  },
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {}
  }
}
WEBSITEPLUGINJSON
cat > "$PLUGIN_DIR/index.ts" <<'WEBSITEPLUGINTS'
// Website plugin
//
// Lets the agent publish a self-contained HTML page it just generated (a
// dashboard, a form, a small tool) as a real, live, token-gated website the
// Telegram user can open in a browser, then close when done. The agent does
// its own HTML/CSS/JS generation -- this plugin only publishes it.
//
// Three product-owner decisions this encodes (do not redesign):
//   1. Tunnel: an unbranded Cloudflare Quick Tunnel spun up per session
//      (`cloudflared tunnel --url http://127.0.0.1:<port>`), not a shared
//      relay we operate -- this product's pitch is "we never touch your
//      infrastructure," and routing customer web-UI traffic through
//      infrastructure we control would be in tension with that.
//   2. Teardown is close_website-only. No idle auto-timeout -- explicit
//      on/off, matching this product's support-access.sh philosophy.
//   3. The link is shared as plain text, not a Telegram Web App button --
//      a `web_app` button needs its domain pre-registered with BotFather,
//      which a fresh random *.trycloudflare.com subdomain can never satisfy.
//
// --- Tool-call identity: the real finding from live testing (08-18) ---
//
// AgentTool.execute has signature (toolCallId, params, signal, onUpdate) --
// confirmed from the shipped .d.ts and live logging -- with NO context
// argument at all. There is no chatId/sessionKey available inside execute()
// itself, unlike message hooks.
//
// The docs' `factory` form (`api.registerTool((ctx) => ({...}))`) DOES get
// an OpenClawPluginToolContext with sessionKey/deliveryContext/etc, but it
// turned out to be a dead end: confirmed live that registering a tool via
// the factory form makes ANY real tool-call by the model fail with
// `LLM request failed. rawError=() => { return
// resolveApplicablePluginRuntimeConfig(...) } could not be cloned.` -- a
// real bug in this OpenClaw version's factory-tool runtime-config plumbing,
// reproduced twice, gone as soon as the same tool is registered as a plain
// object instead. So: plain-object `api.registerTool({...})` only, no
// factory, confirmed working live (EXECUTE fires, tool result returned).
//
// The mechanism that DOES carry identity, confirmed live: the
// `before_tool_call` hook's handler is genuinely two-argument,
// `(event, ctx) => ...` (the shipped .d.ts's generic single-arg
// `InternalHookHandler` type does not describe it -- `PluginHookName`'s
// `before_tool_call` entry is separately typed as
// `(event: PluginHookBeforeToolCallEvent, ctx: PluginHookToolContext) => ...`).
// Live dump of that second `ctx` argument for a real tool call:
//   {"toolName":"...", "agentId":"main", "sessionKey":"agent:main:main",
//    "sessionId":"...", "runId":"...", "trace":{...}, "toolCallId":"..."}
// `ctx.sessionKey` is there and stable -- the same key thinking-bubble
// already correlates Telegram turns through. So: this plugin registers an
// observation-only `before_tool_call` hook that stashes `ctx.sessionKey`
// into a small `Map` keyed by `event.toolCallId`, and each tool's
// `execute(toolCallId, ...)` looks its own sessionKey up (and deletes the
// entry) from that same map. sessionKey is the per-chat correlation key
// here (not a raw Telegram chat id) -- fine for this product's documented
// single-user-per-VPS assumption, and if a call somehow arrives with no
// hook-provided sessionKey, publish/close falls back to one shared "global"
// key, which is still correct for a single-user bot, just less precise.
//
// --- No typebox import ---
//
// The building-plugins.md quickstart imports `Type` from "typebox" for
// `parameters`. Confirmed live that this DOES NOT resolve for a
// workspace-extension plugin: `/data/workspace/.openclaw/extensions/website`
// has no ancestor `node_modules/typebox` (it only lives inside
// `/opt/openclaw/app/node_modules`, which Node's module resolution never
// walks up into from workspace paths) -- load fails with
// `Cannot find module 'typebox'`. Confirmed live too that a plain JSON
// Schema object works identically: TypeBox's own `Type.Object(...)` output,
// inspected directly at runtime, is just a plain object
// (`{type, required, properties}`, no symbols, no special prototype) -- so
// `parameters` here is hand-written JSON Schema, no import needed at all.
//
// --- cloudflared URL format, confirmed live ---
//
// Running the real installed binary inside this exact container prints the
// quick-tunnel URL on stdout/stderr as a line inside a bordered INF box,
// e.g. `https://workshops-briefs-rest-president.trycloudflare.com`. Parsed
// with a plain regex against the accumulated stdout+stderr text rather than
// matching the decorative box border, which is cosmetic and not a stable
// contract.

import http from "node:http";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const COOKIE_NAME = "website_k";
const TUNNEL_URL_RE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/;
const TUNNEL_STARTUP_TIMEOUT_MS = 20_000;

/** toolCallId -> sessionKey, populated by the before_tool_call hook below and
 * consumed (and deleted) by the matching tool's execute(). This is the only
 * way to get chat/session identity into a plain (non-factory) tool's
 * execute() call in this OpenClaw version -- see header comment. */
const sessionKeyByToolCallId = new Map();

/** sessionKey -> active Site. One active website per chat/session, per the
 * product spec ("don't leak a second tunnel/process per chat"). */
const sitesBySessionKey = new Map();

/** sessionKey -> in-flight createSite() Promise. Reserved synchronously
 * before the first await, so two publish_website calls that race for the
 * same session join the same tunnel/server creation instead of each
 * spawning their own (orphaning one on whichever `set()` lost the race). */
const pendingCreations = new Map();

/** Cap on sessionKeyByToolCallId's size: entries are only removed when
 * execute() runs, so a toolCallId whose execute() never fires (blocked by
 * another hook, aborted, etc.) would otherwise leak forever. Evicting the
 * oldest entry past this bound keeps it bounded without needing a TTL
 * timer. */
const MAX_TRACKED_TOOL_CALLS = 50;

function timingSafeTokenEqual(candidate, real) {
  if (typeof candidate !== "string" || typeof real !== "string" || !candidate || !real) return false;
  const a = Buffer.from(candidate, "utf8");
  const b = Buffer.from(real, "utf8");
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const part of header.split(";")) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const i = trimmed.indexOf("=");
    if (i < 0) continue;
    out[trimmed.slice(0, i)] = trimmed.slice(i + 1);
  }
  return out;
}

function makeRequestHandler(site) {
  return (req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { "content-type": "text/plain" }).end("method not allowed");
      return;
    }
    let url;
    try {
      url = new URL(req.url ?? "/", "http://127.0.0.1");
    } catch {
      res.writeHead(400, { "content-type": "text/plain" }).end("bad request");
      return;
    }
    const queryToken = url.searchParams.get("k");
    const cookies = parseCookies(req.headers.cookie);
    const queryOk = timingSafeTokenEqual(queryToken, site.token);
    const cookieOk = timingSafeTokenEqual(cookies[COOKIE_NAME], site.token);
    if (!queryOk && !cookieOk) {
      res.writeHead(403, { "content-type": "text/plain", "cache-control": "no-store" }).end("forbidden");
      return;
    }
    const headers = {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    };
    // Exchange the query token for a cookie on the request that carried it,
    // per the spec's "token in URL -> exchanged once for a cookie" model.
    if (queryOk) {
      headers["set-cookie"] = `${COOKIE_NAME}=${site.token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=86400`;
    }
    res.writeHead(200, headers);
    res.end(req.method === "HEAD" ? undefined : site.html);
  };
}

function waitForTunnelUrl(proc) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const onData = (chunk) => {
      buf += chunk.toString("utf8");
      const match = buf.match(TUNNEL_URL_RE);
      if (match) {
        cleanup();
        resolve(match[0]);
      }
    };
    const onExit = (code) => {
      cleanup();
      reject(new Error(`cloudflared exited before printing a tunnel URL (code ${code}): ${buf.slice(-1000)}`));
    };
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`cloudflared did not print a tunnel URL within ${TUNNEL_STARTUP_TIMEOUT_MS}ms: ${buf.slice(-1000)}`));
    }, TUNNEL_STARTUP_TIMEOUT_MS);
    function cleanup() {
      clearTimeout(timer);
      proc.stdout?.off("data", onData);
      proc.stderr?.off("data", onData);
      proc.off("exit", onExit);
    }
    proc.stdout?.on("data", onData);
    proc.stderr?.on("data", onData);
    proc.on("exit", onExit);
  });
}

async function createSite(sessionKey, html, title) {
  const server = http.createServer();
  const token = crypto.randomBytes(24).toString("base64url");
  const site = { sessionKey, server, token, html, title, cloudflaredProc: null, tunnelUrl: null };
  server.on("request", makeRequestHandler(site));

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve(undefined);
    });
  });
  const port = server.address().port;

  const proc = spawn("cloudflared", ["tunnel", "--url", `http://127.0.0.1:${port}`], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  site.cloudflaredProc = proc;
  // cloudflared can die on its own (network blip, process limits); if that
  // happens while we're still tracking this site, stop pretending it's
  // live so the next publish_website actually recreates a working tunnel
  // instead of silently returning a dead link.
  proc.on("exit", () => {
    if (sitesBySessionKey.get(sessionKey) === site) {
      sitesBySessionKey.delete(sessionKey);
      try {
        server.close();
      } catch {
        // already closed
      }
    }
  });

  try {
    site.tunnelUrl = await waitForTunnelUrl(proc);
  } catch (err) {
    try {
      proc.kill("SIGTERM");
    } catch {
      // already dead
    }
    try {
      server.close();
    } catch {
      // already closed
    }
    throw err;
  }

  sitesBySessionKey.set(sessionKey, site);
  return site;
}

function closeSite(site) {
  try {
    site.cloudflaredProc?.kill("SIGTERM");
  } catch {
    // already dead
  }
  try {
    site.server.close();
    site.server.closeAllConnections?.();
  } catch {
    // already closed
  }
}

function sessionKeyForToolCall(toolCallId) {
  const sessionKey = sessionKeyByToolCallId.get(toolCallId);
  sessionKeyByToolCallId.delete(toolCallId);
  return sessionKey ?? "global";
}

const publishParameters = {
  type: "object",
  required: ["html"],
  properties: {
    html: {
      type: "string",
      description:
        "A complete, self-contained HTML document (inline CSS/JS, no external build step or assets).",
    },
    title: {
      type: "string",
      description: "Optional short title for this page, used only for logging.",
    },
  },
};

const closeParameters = {
  type: "object",
  properties: {},
};

export default definePluginEntry({
  id: "website",
  name: "Website",
  description: "Publish a self-contained HTML page as a live, token-gated website and close it when done.",
  register(api) {
    // Observation-only: stash the session key for this tool call so
    // execute() (which gets no context of its own) can look it up by
    // toolCallId. See header comment for why this is the mechanism, not
    // the factory form of registerTool.
    api.on("before_tool_call", (event, ctx) => {
      if (
        (event.toolName === "publish_website" || event.toolName === "close_website") &&
        event.toolCallId
      ) {
        if (sessionKeyByToolCallId.size >= MAX_TRACKED_TOOL_CALLS) {
          const oldestKey = sessionKeyByToolCallId.keys().next().value;
          sessionKeyByToolCallId.delete(oldestKey);
        }
        sessionKeyByToolCallId.set(event.toolCallId, ctx?.sessionKey ?? "global");
      }
    });

    api.registerTool({
      name: "publish_website",
      label: "Publish Website",
      description:
        "Publish a self-contained HTML page (a dashboard, form, or small interactive tool) as a live, securely-reachable website and return its link to share with the user. Reuses and replaces the currently open page for this chat if one is already open.",
      parameters: publishParameters,
      async execute(toolCallId, params) {
        const sessionKey = sessionKeyForToolCall(toolCallId);
        const html = String(params.html ?? "");
        const title = typeof params.title === "string" ? params.title : undefined;

        let reused = true;
        let creating = pendingCreations.get(sessionKey);
        if (!sitesBySessionKey.has(sessionKey) && !creating) {
          // Reserve the slot synchronously, before the first await, so a
          // second publish_website call for this same session (racing in
          // the same turn, or a retry) joins this creation instead of
          // spawning its own tunnel/server -- see pendingCreations comment.
          reused = false;
          creating = createSite(sessionKey, html, title);
          pendingCreations.set(sessionKey, creating);
          creating.finally(() => pendingCreations.delete(sessionKey));
        }

        const site = creating ? await creating : sitesBySessionKey.get(sessionKey);
        // Whether we just created it or joined/reused an already-live one,
        // make sure the served content matches what THIS call asked for.
        site.html = html;
        site.title = title;

        const url = `${site.tunnelUrl}/?k=${site.token}`;
        return {
          content: [{ type: "text", text: `${reused ? "Website updated" : "Website published"}: ${url}` }],
          details: { url, reused },
        };
      },
    });

    api.registerTool({
      name: "close_website",
      label: "Close Website",
      description: "Tear down the currently published website for this chat, if one is open.",
      parameters: closeParameters,
      async execute(toolCallId) {
        const sessionKey = sessionKeyForToolCall(toolCallId);
        const site = sitesBySessionKey.get(sessionKey);
        if (!site) {
          return {
            content: [{ type: "text", text: "No active website to close." }],
            details: { closed: false },
          };
        }
        sitesBySessionKey.delete(sessionKey);
        closeSite(site);
        return {
          content: [{ type: "text", text: "Website closed." }],
          details: { closed: true },
        };
      },
    });
  },
});
WEBSITEPLUGINTS
docker exec openclaw mkdir -p /data/workspace/.openclaw/extensions/website
docker cp "$PLUGIN_DIR/openclaw.plugin.json" openclaw:/data/workspace/.openclaw/extensions/website/openclaw.plugin.json
docker cp "$PLUGIN_DIR/index.ts" openclaw:/data/workspace/.openclaw/extensions/website/index.ts
rm -rf "$PLUGIN_DIR"

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
// Real, deterministic thinking-bubble plugin (installed above as a
// workspace extension). Reads TELEGRAM_BOT_TOKEN / THINKING_BUBBLE_MODEL_LABEL
// straight from process.env (set in .env, passed through by docker-compose)
// -- confirmed live (08-18) that ctx.pluginConfig is always empty for the
// message_received/message_sending hooks in this OpenClaw version, so
// config-based injection here would silently no-op.
cfg.plugins.entries['thinking-bubble'] = { enabled: true };
// A workspace-extension plugin isn't trusted by default -- without this,
// OpenClaw logs 'plugin not found: thinking-bubble (stale config entry
// ignored)' even though the file is right there at the documented
// discovery path. Confirmed live (08-17): adding plugins.allow is what
// actually makes the entries.* config take effect.
cfg.plugins.allow = Array.from(new Set([...(cfg.plugins.allow || []), 'thinking-bubble']));
// Workspace-extension auto-discovery (<workspace>/.openclaw/extensions/) did
// NOT pick this up in testing (08-17) despite the files sitting exactly at
// the documented path -- 'plugin not found' every time. Rather than keep
// guessing at path/workspace-root conventions, point at it explicitly via
// the highest-precedence config option (plugins.load.paths), which sidesteps
// discovery-convention ambiguity entirely.
cfg.plugins.load = cfg.plugins.load || {};
cfg.plugins.load.paths = Array.from(new Set([...(cfg.plugins.load.paths || []), '/data/workspace/.openclaw/extensions/thinking-bubble']));
// Website plugin (installed above as a workspace extension), same
// allow/load-paths trust dance as thinking-bubble above -- confirmed live
// (08-18) it needs the exact same two entries or it's 'plugin not found'
// too.
cfg.plugins.entries['website'] = { enabled: true };
cfg.plugins.allow = Array.from(new Set([...(cfg.plugins.allow || []), 'website']));
cfg.plugins.load.paths = Array.from(new Set([...(cfg.plugins.load.paths || []), '/data/workspace/.openclaw/extensions/website']));
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
// Which model is answering (Rob: FarmOps shows this and 'it's a dead give
// away' when it's missing) is shown on the THINKING BUBBLE placeholder
// (see thinking-bubble plugin, THINKING_BUBBLE_MODEL_LABEL env var) while
// the reply is generating, then the placeholder is replaced by the clean
// final answer -- no permanent prefix on delivered messages. Rob (08-18):
// showing the tag only on the final message was 'backwards' -- it should
// be the loading indicator, not a permanent stamp.
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
