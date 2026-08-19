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
WEBSITE_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
QUICK_MENU_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
LOCATION_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
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

Make it look like a real product, not a bare unstyled page — the full
design system (theme choice, DaisyUI components, visual-quality checklist)
is already provided in your instructions, no need to look anything up
first. At minimum, every page you publish must include the Tailwind +
DaisyUI CDN tags and this layout-safety CSS in `<head>`:

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/themes.css">
<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :where(.grid, .flex) > * { min-width: 0; }
  :where(p, h1, h2, h3, h4, li, td, th) { overflow-wrap: anywhere; }
  :where(img, svg, video, canvas, iframe) { max-width: 100%; height: auto; }
</style>
```
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
#      The website plugin (installed below) spawns cloudflared from plugin
#      code running in-process inside that container.
#
#      Installed under /data/bin, NOT /usr/local/bin — /usr/local/bin lives
#      in the container's writable layer, which is discarded and rebuilt
#      from the base image on every `docker compose up -d --force-recreate`
#      (done routinely, e.g. to pick up new .env vars). /data is the
#      persistent volume (docker-compose.yml: openclaw-data:/data), the same
#      place the plugin files themselves live, so this survives recreation
#      the same way they do. This is a real fix for a real incident: an
#      earlier /usr/local/bin install got silently wiped by a recreate,
#      and the resulting `spawn cloudflared ENOENT` crashed the whole
#      gateway process (see plugins/website/index.ts's header comment for
#      the full incident writeup and the separate crash-proofing fix).
#      The plugin spawns the absolute path directly (CLOUDFLARED_PATH in
#      plugins/website/index.ts) rather than relying on PATH, so no
#      symlink or container-startup step is needed to make it resolve.
#
#      Cloudflare ships a single dependency-free static binary per
#      architecture with no account/install step — download the right one,
#      docker cp it into /data/bin, chmod +x, verify.
# ---------------------------------------------------------------------------
log "Installing cloudflared (for the website plugin's Quick Tunnels)"
case "$(uname -m)" in
    x86_64|amd64)   CLOUDFLARED_ARCH="amd64" ;;
    aarch64|arm64)  CLOUDFLARED_ARCH="arm64" ;;
    *) die "Unsupported architecture for cloudflared: $(uname -m)" ;;
esac
curl -fsSL -o /tmp/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}"
docker exec openclaw mkdir -p /data/bin
docker cp /tmp/cloudflared openclaw:/data/bin/cloudflared
docker exec openclaw chmod +x /data/bin/cloudflared
rm -f /tmp/cloudflared
if docker exec openclaw /data/bin/cloudflared --version >/dev/null 2>&1; then
    log "cloudflared installed: $(docker exec openclaw /data/bin/cloudflared --version)"
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
// --- Quick-menu keyboard: fully decoupled from this file now ---
//
// Two prior versions of this plugin attached the quick-menu
// ReplyKeyboardMarkup to this file's placeholder message -- first as a
// plain send-then-delete placeholder, then as a "permanent carrier"
// placeholder that got edited-in-place instead of deleted. Both were
// wrong for the same underlying reason, confirmed against FarmOps'
// own hard-won 2026-07-25 lesson (`ai-farm/scripts/bridge_common.py`
// clear_chat's docstring): a keyboard-carrying message must never be
// something that gets deleted OR edited away, full stop -- not "deleted
// less often" or "edited instead of deleted", but never touched again
// after it's sent. Coupling the keyboard to this placeholder's lifecycle
// at all was the mistake, regardless of which specific lifecycle event
// (delete vs. edit) triggered the loss Rob's real device testing (08-18)
// kept turning up. The fix lives entirely in plugins/quick-menu/index.ts
// now: a standalone message it sends directly on /start and /new,
// completely independent of this file's send-then-delete placeholder.
// This file has zero reply_markup involvement, matching FarmOps' own
// clean separation between its placeholder sends (TG.send_dim, never
// carries reply_markup) and its keyboard attach sites (TG.send on
// /start, /help, /new, clear_chat -- always a permanent message).
//
// --- Fix: reply_dispatch-delivered replies never fire reply_payload_sending ---
//
// Confirmed live, 08-19: `/website`'s bare-command follow-up and `/clearchat`
// were both moved today from `message_received` onto `api.on('reply_dispatch',
// handler)` returning `{ handled: true, ... }` (plugins/website/index.ts and
// plugins/quick-menu/index.ts) -- the correct fix for a DIFFERENT bug, since
// `reply_dispatch`'s `handled: true` is a structural short-circuit that stops
// the LLM from ALSO replying conversationally to the same message (confirmed
// against this deployed version's own dispatch-from-config.ts, same finding
// documented in those two files' own headers). But `reply_payload_sending`
// below only fires as part of the SAME normal agent-turn pipeline that
// short-circuit deliberately bypasses -- so a placeholder for a message that
// gets claimed via `reply_dispatch` has no trigger left to delete it. It sits
// until the 3-minute safety net above wrongly edits it to "didn't come
// through" next to a reply that actually arrived fine.
//
// Investigated and rejected: this file registering its OWN `reply_dispatch`
// handler to notice and delete the placeholder itself. Confirmed against this
// deployed version's own docs (`docs/plugins/sdk-overview.md`: "`reply_dispatch`:
// returning `{ handled: true, ... }` is terminal. Once any handler claims
// dispatch, lower-priority handlers ... are skipped.") and `docs/plugins/hooks.md`
// ("Handlers run sequentially in descending priority..."): `reply_dispatch`
// fires for EVERY inbound message, not just ones a plugin ends up claiming --
// it's the pre-agent-turn checkpoint, and normal chat passes straight through
// it. A second handler registered here at higher priority than website/
// quick-menu's would run on every message BEFORE anyone claims it, so it
// cannot tell "about to be claimed" from "about to go to the agent turn as
// normal" -- deleting the placeholder there would kill the bubble immediately
// for ordinary chat, before the agent even starts generating. A handler
// registered at LOWER priority never runs at all for a claimed message,
// because claiming is terminal and skips every lower-priority handler for
// that same event, this file's included. There is no priority ordering that
// makes a second, independent `reply_dispatch` listener in this file see "a
// claim just happened" -- structurally not possible with this hook's
// documented semantics, not a guess.
//
// So: the plugin that actually claims and delivers the reply (website,
// quick-menu) is the only code that runs at the right moment. Rather than
// duplicating this file's Map + Telegram delete-call logic into each of
// those separate plugin directories (no shared import path between
// workspace-extension plugins -- same constraint already noted below re:
// the duplicated tg() helper), this file publishes a tiny settle function on
// `globalThis` under a well-known `Symbol.for` key. That works because
// OpenClaw plugins are NOT sandboxed subprocesses -- confirmed in
// `docs/plugins/architecture.md`: "Native OpenClaw plugins run in-process
// with the Gateway... same process-level trust boundary as core code" -- so
// all three plugins share one JS heap and `globalThis`. This is also not a
// novel trick: OpenClaw's own compiled source uses the exact same
// `Symbol.for` singleton pattern internally for its plugin-commands registry
// (`Symbol.for("openclaw.pluginCommandsState")`, reverse-engineered in
// plugins/quick-menu/index.ts's own header). See getReplyDispatchSettler
// below for the actual mechanism, and that same symbol's use in
// plugins/website/index.ts and plugins/quick-menu/index.ts for the caller
// side.
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
//
// --- Why /start is the one slash command not skipped below ---
//
// Rob's report after tapping through an earlier design on a real phone:
// "/start doesn't show the toggle button." Root cause: the categorical
// slash-command skip below (content.startsWith("/")) caught /start along
// with every other command, so it never got a placeholder at all. But
// /start is NOT one of OpenClaw's fast built-ins: confirmed by reading
// dist/commands-registry.data-BKgJ3WoC.js's native-command table (which
// lists /help, /status, /usage, /new, etc. by textAlias) -- there is no
// "start" entry anywhere in it. With no bot.command("start", ...) handler
// registered (dist/telegram-ingress-spool-Dd3cDhXe.js:989-992 only
// registers handlers for that table's entries), a real /start falls
// through to the generic message handler at :4268 -> processInboundMessage
// (:3231) -> the normal dispatch/agent-turn path, the same one plain chat
// text takes, which DOES fire reply_payload_sending. That matches the
// earlier live observation that /start produces a natural, personalized,
// LLM-generated welcome -- it's a real agent turn, not a template. So
// /start is an explicit exception to the slash-command skip below: it gets
// a placeholder like normal chat. /help, /status, /usage, /new, /tts,
// /website, and the quick-menu's own button commands all stay skipped --
// they really are instant built-ins with no reply_payload_sending. (/new
// was re-confirmed as a native built-in, not a special case, when the
// quick-menu keyboard fix was designed -- key: "new", nativeName: "new",
// textAlias: "/new", tier: "essential" in that same registry table.)

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

/** /start is the one slash command that must NOT be skipped -- see header
 * comment for why it's a real agent turn, not a fast built-in. Matches
 * bare "/start", a deep-link payload ("/start payload"), and the
 * "/start@BotName" form Telegram uses in group chats. */
function isStartCommand(content: string): boolean {
  return /^\/start(@\w+)?(\s|$)/.test(content);
}

type Placeholder = {
  chatId: string;
  messageId: number;
  since: number;
};

const pendingBySession = new Map<string, Placeholder>();

/** Safety net for a confirmed OpenClaw platform quirk (live 08-18, both
 * before and after TTS config changes, on plain "Hi" messages): the model
 * call succeeds but the turn dispatches with zero queued reply payloads --
 * [turn/kernel] logs it, no error is thrown anywhere. reply_payload_sending
 * simply never fires for that turn, so without this the placeholder from
 * message_received sits there forever with no indication anything failed.
 * Not our bug to fix (nothing in our plugin code drops the payload), but our
 * bubble needs to resolve either way. 3 minutes is comfortably past any
 * legitimate turn -- including ones with tool calls or slow providers --
 * while still turning "stuck forever" into "stuck for a few minutes, then a
 * clear message telling the user to retry". Same style of constant as
 * WEBSITE_AWAIT_TIMEOUT_MS in plugins/website/index.ts. */
const PLACEHOLDER_TIMEOUT_MS = 3 * 60 * 1000;

const STUCK_PLACEHOLDER_TEXT = "That one didn't come through -- try sending it again.";

/** See plugins/website/index.ts's 08-19 "hang incident: root cause and fix"
 * header comment for the full story -- this file's `tg()` had the exact
 * same unbounded-`fetch()` shape, so its own `editMessageText` call inside
 * settleStuckPlaceholder (the last-resort safety net itself!) could
 * silently hang the same way, defeating the one mechanism this file exists
 * to guarantee. Must stay in sync with the copies of this same constant in
 * plugins/website/index.ts and plugins/quick-menu/index.ts (independent
 * copies -- no shared import path between workspace-extension plugins). */
const TG_FETCH_TIMEOUT_MS = 15_000;

/** Edits a placeholder that's being abandoned (past its timeout, or
 * superseded by a new message on the same session) into a plain retry
 * notice, and swallows/logs failure the same way every other Telegram call
 * in this plugin does -- there's no further recovery action to take if this
 * one fails too. */
function settleStuckPlaceholder(botToken: string, placeholder: Placeholder) {
  tg(botToken, "editMessageText", {
    chat_id: placeholder.chatId,
    message_id: placeholder.messageId,
    text: STUCK_PLACEHOLDER_TEXT,
  }).catch((err) => {
    console.error(
      "[thinking-bubble] failed to edit stuck placeholder:",
      err instanceof Error ? err.message : String(err),
    );
  });
}

function placeholderText(): string {
  const label = process.env.THINKING_BUBBLE_MODEL_LABEL;
  return label ? `🧠 ${label} <i>thinking</i>` : "<i>thinking</i>";
}

async function tg(botToken: string, method: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TG_FETCH_TIMEOUT_MS),
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

/** Well-known cross-plugin key -- see the "Fix: reply_dispatch-delivered
 * replies" header section above for why this exists and why it's a
 * `Symbol.for` lookup rather than an import. Must stay byte-identical to the
 * copy of this same string in plugins/website/index.ts and
 * plugins/quick-menu/index.ts (Symbol.for interns by exact string match). */
const REPLY_DISPATCH_SETTLER_KEY = Symbol.for("openclaw-byok.thinking-bubble.getReplyDispatchSettler");

/** Published on `globalThis` (see register() below) for website/quick-menu's
 * own `reply_dispatch` handlers to call. Returns `undefined` if no
 * placeholder is currently pending for this session -- nothing to settle.
 * Otherwise returns a one-shot settle function bound to THAT SPECIFIC
 * placeholder (captured by object reference here, not just re-looked-up by
 * sessionKey later): calling it deletes that exact placeholder, but is a
 * safe no-op if a newer placeholder has since replaced it in
 * `pendingBySession` (e.g. the caller awaited a slow LLM call and a fresh
 * message arrived on the same session in the meantime -- message_received's
 * own orphan-handling above would already have superseded the one this
 * caller captured). This is what stops the delete from racing a subsequent
 * message's placeholder: the caller should grab this settler as early as
 * possible (right after claiming, before any await) and invoke it right
 * before sending its real reply -- the same moment reply_payload_sending
 * deletes the placeholder in the normal path below, so the bubble stays
 * visible for the same duration either way. */
function getReplyDispatchSettler(sessionKey: string): (() => void) | undefined {
  const placeholder = pendingBySession.get(sessionKey);
  if (!placeholder) return undefined;

  return () => {
    if (pendingBySession.get(sessionKey) !== placeholder) return; // superseded, not ours to touch
    pendingBySession.delete(sessionKey);

    const botToken = process.env.THINKING_BUBBLE_BOT_TOKEN;
    if (!botToken) return;

    tg(botToken, "deleteMessage", {
      chat_id: placeholder.chatId,
      message_id: placeholder.messageId,
    }).catch((err) => {
      console.error(
        "[thinking-bubble] failed to delete placeholder (reply_dispatch path):",
        err instanceof Error ? err.message : String(err),
      );
    });
  };
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

/** message_received's event carries Telegram's own message send time (ms
 * since epoch, confirmed live 08-18 via dispatch source: ctx.Timestamp is
 * set from `msg.date * 1000` and flows through unchanged to the plugin
 * event's `timestamp` field). Diffing against it gives an exact,
 * self-contained placeholder-latency measurement -- no more guessing at the
 * gap from gateway log timestamps of unrelated lines. */
function extractTimestamp(event: Record<string, unknown>): number | undefined {
  const t = (event as { timestamp?: number }).timestamp;
  return typeof t === "number" ? t : undefined;
}

export default definePluginEntry({
  id: "thinking-bubble",
  name: "Thinking Bubble",
  description: "Send a placeholder Telegram message while a reply generates, then delete it once the real answer is about to arrive.",
  register(api) {
    // Cross-plugin coordination point for website/quick-menu's reply_dispatch
    // handlers -- see the "Fix: reply_dispatch-delivered replies" header
    // section and getReplyDispatchSettler's own doc comment above. Assigning
    // on every register() call (rather than at module load) keeps this
    // correct even if the plugin runtime ever re-enters register() -- always
    // points at the current pendingBySession closure, never a stale one.
    (globalThis as Record<PropertyKey, unknown>)[REPLY_DISPATCH_SETTLER_KEY] = getReplyDispatchSettler;

    // Sweeps for placeholders whose owning turn never called
    // reply_payload_sending (see PLACEHOLDER_TIMEOUT_MS comment above).
    // Same shape as the website plugin's awaitingDescriptionBySessionKey
    // eviction sweep: unref() so it can't keep the process alive on its own,
    // and it's the only thing that makes the timeout apply even when no
    // later event ever arrives for that session to trigger a lazy check.
    setInterval(() => {
      const botToken = process.env.THINKING_BUBBLE_BOT_TOKEN;
      if (!botToken) return;

      const now = Date.now();
      for (const [sessionKey, placeholder] of pendingBySession) {
        if (now - placeholder.since <= PLACEHOLDER_TIMEOUT_MS) continue;

        pendingBySession.delete(sessionKey); // evict first: don't act twice on the same placeholder
        settleStuckPlaceholder(botToken, placeholder);
      }
    }, 30_000).unref();

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

        // A prior placeholder still tracked for this session was never
        // claimed by reply_payload_sending -- ANY new message on this
        // session (command or plain text) means it's abandoned, not just
        // slow. Settle it now, independent of whether this particular
        // message will get a new placeholder of its own, rather than
        // leaving it orphaned (untracked, unedited) until the next 3-minute
        // sweep pass -- a command being the abandoning message shouldn't
        // delay that cleanup.
        const orphaned = pendingBySession.get(sessionKey);
        if (orphaned) {
          pendingBySession.delete(sessionKey);
          settleStuckPlaceholder(botToken, orphaned);
        }

        // Slash commands (OpenClaw built-ins, this product's own /website,
        // and quick-menu's keyboard shortcuts -- all literally /-prefixed
        // text, see plugins/quick-menu/index.ts) are answered instantly by
        // a non-agent path that never fires reply_payload_sending, so a
        // placeholder sent here would either orphan forever or get caught
        // by the stuck-placeholder safety net and wrongly edited to a
        // "didn't come through" retry notice next to a reply that already
        // arrived fine. Categorical skip, not a per-command allowlist --
        // Rob, 08-18: "when /commands are being executed... we should not
        // use or display the thinking bubble... The bubble would only come
        // when there's an LLM involved." /start is the one exception --
        // it's not a fast built-in, it's a real agent turn (see header
        // comment) and needs a placeholder like normal chat.
        const content = typeof (event as { content?: unknown }).content === "string"
          ? (event as { content: string }).content.trim()
          : "";
        if (content.startsWith("/") && !isStartCommand(content)) return;

        try {
          const inboundTimestamp = extractTimestamp(event as Record<string, unknown>);
          const sent = await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text: placeholderText(),
            parse_mode: "HTML",
          });
          if (typeof inboundTimestamp === "number") {
            console.log(`[thinking-bubble] placeholder sent ${Date.now() - inboundTimestamp}ms after inbound message`);
          }
          const messageId = sent.result?.message_id;
          if (typeof messageId === "number") {
            pendingBySession.set(sessionKey, { chatId, messageId, since: Date.now() });
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
  "commandAliases": [
    {
      "name": "website",
      "kind": "runtime-slash"
    }
  ],
  "activation": {
    "onStartup": true
  },
  "skills": ["./skills"],
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
// --- cloudflared binary path and crash-proofing (08-18 incident) ---
//
// This crashed a live customer gateway: `spawn("cloudflared", ...)` threw
// `Error: spawn cloudflared ENOENT` as an unhandled 'error' event on the
// ChildProcess, which is fatal for the whole Node process by default (not
// just this one request) -- Docker's `restart: unless-stopped` then quietly
// relaunched the entire container, which is why the visible symptom was
// "the bot got stuck," not an obvious crash log.
//
// Root cause: setup.sh used to `docker cp` cloudflared to
// /usr/local/bin/cloudflared, which lives in the container's writable
// layer, NOT the /data volume. Any `docker compose up -d --force-recreate`
// (done routinely to pick up new .env vars) discards that layer and wipes
// the binary, while this plugin file itself (under
// /data/workspace/.openclaw/extensions/website) survives -- so the plugin
// kept running, found nothing to spawn, and took the gateway down with it.
// Fixed by installing to CLOUDFLARED_PATH below, under /data, so it
// survives recreation the same way the plugin code does.
//
// Regardless of where the binary lives, a spawn failure (missing binary,
// bad permissions, OOM, anything) must never be able to crash the gateway
// again: every ChildProcess this file creates gets a permanent
// `.on("error", ...)` listener (so the EventEmitter always has one, for the
// life of the process, not just during startup) plus a temporary one inside
// waitForTunnelUrl that turns a startup-time spawn failure into a normal
// rejected Promise instead of an unhandled event. See createSite() below.
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
//
// --- Bare `/website` flow: inbound_claim researched and rejected (08-18) ---
//
// The product ask: bare `/website` should explain itself and wait for the
// next message as input, like Nelita's /editvideo. The docs' own hooks
// table names `inbound_claim` for exactly this ("Claim an inbound message
// before agent routing"), so it was researched first, not guessed at.
//
// Static analysis of the shipped bundle (not just the docs) found the real
// mechanism is much heavier than the one-line doc description implies: the
// ONLY call site that invokes `inbound_claim` (dist/dispatch-*.js, the
// `runInboundClaimForPluginOutcome` branch) is gated on
// `if (pluginOwnedBinding)` -- it only fires for a plugin that already owns
// a `PluginConversationBinding` for that conversation. The generic,
// unscoped claim runner (`runInboundClaim`, first-claim-wins across all
// plugins) exists in the hook runner but has zero callers anywhere in the
// bundle. And winning a binding is itself a heavyweight, interactive flow
// (`ctx.requestConversationBinding()`): the first request for a
// conversation returns `status: "pending"` and sends the OWNER an approval
// card ("plugin X wants to bind this conversation, approve?") unless a
// prior "allow always" was already granted. Confirmed no bundled extension
// in this build uses `inbound_claim` either. So the realistic behavior of
// wiring it up here would be: the very first bare `/website` interrupts the
// user with an unrelated approval prompt before they even get the
// explanation -- worse than the current one-line usage hint, not an
// upgrade. Rejected on that evidence; not registered.
//
// --- Fix (round 2), 08-18: reply_dispatch, not message_received ---
//
// Round 1 used `message_received` to notice the next plain-text message
// after a bare `/website` and independently generate+publish+reply to it.
// That's a pure observer hook -- it could not
// stop the normal agent turn from ALSO seeing that same plain text and
// replying to it conversationally, and this exact tradeoff (disclosed at the
// time) turned out to be the same live-confirmed "stray LLM reply" bug Rob
// hit with quick-menu's `/clearchat` (see that plugin's own header for the
// full incident). Same fix applies here: `reply_dispatch` fires BEFORE
// OpenClaw builds the agent turn (confirmed against this deployed version's
// own `src/auto-reply/reply/dispatch-from-config.ts`, ~2973-3020 -- a
// `handled: true` return there causes an early `return` several lines before
// the code that hands the turn to the agent), so claiming the follow-up
// description there is a structural short-circuit, not a race. Same
// proven call sequence as wizbid/reseller's own commands in ai-farm
// (onReplyStart -> do the work -> dispatcher.markComplete() ->
// recordProcessed('completed') -> markIdle(reason)), documented in
// `~/.claude/projects/-home-lenov-projects-ai-farm/memory/
// feedback_openclaw_plugin_for_fast_dispatch.md`.
//
// No default timeout applies to reply_dispatch handlers in this version
// (confirmed against `src/plugins/hooks.ts`'s
// `DEFAULT_MODIFYING_HOOK_TIMEOUT_MS_BY_HOOK` -- reply_dispatch isn't in that
// table, so `getClaimingHookTimeoutMs` returns undefined and `withHookTimeout`
// is skipped), so the `generateHtml()` LLM call this handler makes is safe to
// run inline here, same as it already was inline in message_received.
//
// Sending the plugin's own reply out-of-band (independent of the normal
// command-reply/`continueAgent` pipeline) requires the same direct-Telegram
// pattern thinking-bubble already proved live, not OpenClaw's internal
// `PluginRuntimeChannel` dispatch helpers (`dispatchReplyWithBufferedBlockDispatcher`
// et al.) -- that surface has no bundled-extension usage example either and
// is a much larger, riskier surface to get right untested than one more
// `fetch()` call to the Bot API. Needs its own bot token in-process, same
// as thinking-bubble: see `WEBSITE_BOT_TOKEN` in setup.sh's `.env` heredoc.
//
// HTML generation for the claimed follow-up message can't reuse
// `ctx.runtimeContext.llm` (that only exists on `PluginCommandContext`,
// which a hook handler never receives) -- it uses `api.runtime.llm.complete()`
// instead, captured once at `register(api)` time. Per the shipped
// `.d.ts`, `PluginRuntimeCore["llm"]` is the exact same type
// `PluginCommandContext.runtimeContext.llm` is typed as, so this should be
// the identical helper reached a different way -- plausible from the types,
// NOT independently confirmed live the way the tool-call/command-context
// findings above were (no owner Telegram access to trigger the claimed-message
// path end to end; see verification notes in the repo).

import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const COOKIE_NAME = "website_k";
const TUNNEL_URL_RE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/;
const TUNNEL_STARTUP_TIMEOUT_MS = 20_000;

/** --- 08-19 hang incident: root cause and fix ---
 *
 * A real follow-up request ("list of all the skulls in halo campaign
 * evolve...") got stuck with NO resolution at all -- not even the
 * thinking-bubble 3-minute stuck-placeholder safety net cleared it. Traced
 * live against root@2.29.7.145 with a diagnostic probe script that called
 * this file's own real `publish_website` tool handler (real spawn, real
 * cloudflared, real tunnel) directly: createSite()/waitForTunnelUrl()
 * resolved reliably in ~5-8s across 6 real runs, and the still-running
 * orphaned `cloudflared` process left over from the stuck request had an
 * ESTABLISHED TCP connection to Cloudflare's edge (confirmed via `ss -tnp`
 * inside the container) -- strong evidence the tunnel itself came up fine
 * and TUNNEL_STARTUP_TIMEOUT_MS never needed to fire.
 *
 * The real bottleneck: `tg()` below built its `fetch()` call with NO
 * timeout/AbortSignal at all. Confirmed live on this exact box that this
 * is a real, reachable hang, not a hypothetical: a `fetch()` with no signal
 * against a socket that accepts the TCP connection but never writes a
 * response was STILL PENDING 15 SECONDS later (undici's own documented
 * default is a 300-second/5-minute `headersTimeout`, which is not a
 * bound this product's "reasonable time" requirement can rely on, and
 * this incident had already run well past 12 minutes with zero
 * console.error ever printed from either of this handler's own catch
 * blocks -- meaning execution was still suspended mid-`await`, not
 * thrown). `reply_dispatch` handlers have no default timeout of their
 * own either (confirmed against this deployed version's own
 * `src/plugins/hooks.ts` `DEFAULT_MODIFYING_HOOK_TIMEOUT_MS_BY_HOOK`
 * table, and its `dispatch-from-config.ts` caller, which plainly
 * `await`s the handler with no race against a timer -- only against an
 * external abort signal that nothing here ever fires), so a hang inside
 * this file's own `reply_dispatch` handler is a hang OpenClaw's core has
 * no mechanism to ever rescue.
 *
 * Fix: give every `tg()` call its own hard ceiling via
 * `AbortSignal.timeout()` (turns an indefinite stall into a normal
 * rejected promise, same shape as every other failure this file already
 * handles), and wrap the reply_dispatch handler's real work (generate +
 * publish + deliver) in one more outer ceiling as a second, independent
 * backstop -- see REPLY_DISPATCH_WORK_TIMEOUT_MS below. Between the two,
 * nothing in this handler can hang past a bounded, known ceiling again.
 *
 * This also explains why the thinking-bubble safety net didn't fire as a
 * last resort (a real, separate bug, not just a consequence of the hang
 * above): this handler used to call `getThinkingBubbleSettler(sessionKey)
 * ?.()` -- which synchronously deletes thinking-bubble's own
 * `pendingBySession` tracking entry -- BEFORE `await`ing the final
 * `tg(sendMessage)` call that actually delivers the answer. The instant
 * that call started hanging, thinking-bubble's own bookkeeping already
 * believed this placeholder was resolved, so its 3-minute sweep had
 * nothing left to find -- not because the sweep is broken, but because it
 * was told (prematurely) that there was nothing to sweep. Fixed below by
 * only settling the placeholder once a reply (success or the caught-error
 * notice) has actually been delivered -- if even the error notice fails to
 * send, the placeholder is deliberately left tracked so the safety net
 * remains the true last resort. */
const TG_FETCH_TIMEOUT_MS = 15_000;

/** Second, independent backstop on top of TG_FETCH_TIMEOUT_MS and
 * TUNNEL_STARTUP_TIMEOUT_MS -- bounds the reply_dispatch handler's entire
 * generate+publish+deliver sequence so that no single step (including one
 * this file doesn't itself put an explicit ceiling on, like the LLM call
 * inside generateHtml) can hang the handler indefinitely, even one we
 * haven't specifically identified. Generous on purpose: real generation of
 * a substantial page plus tunnel startup (up to TUNNEL_STARTUP_TIMEOUT_MS)
 * plus Telegram delivery (up to TG_FETCH_TIMEOUT_MS), summed with margin. */
const REPLY_DISPATCH_WORK_TIMEOUT_MS = 90_000;

/** Turns any promise that doesn't settle within `ms` into a rejection with
 * a clear, labeled message -- see the header comment above for why this
 * exists. `timer.unref()` so a pending guard can't itself keep the process
 * alive if everything else has already shut down. */
function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
    timer.unref?.();
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/** Persistent path under the /data volume, installed there by setup.sh --
 * NOT /usr/local/bin (container writable layer, wiped on every
 * --force-recreate). See header comment for the incident this fixes. */
const CLOUDFLARED_PATH = "/data/bin/cloudflared";

/** The `website-design` skill, shipped alongside this plugin (declared via
 * `"skills": ["./skills"]` in openclaw.plugin.json, "always": true in its
 * own frontmatter) so it's always name-discoverable in the compact
 * `<available_skills>` entry every turn gets.
 *
 * Its FULL BODY is no longer relied on to reach the main agent turn (the
 * path `publish_website` itself is reached through: the agent generates
 * HTML itself, per AGENTS.md's addendum, then calls the tool with it -- the
 * tool handler here never talks to the LLM at all) via progressive-
 * disclosure skill discovery. That mechanism was live-measured (08-19) to
 * cost a real, unconditional round trip on a cold session: agent turn 1
 * decides to `read` the skill file, turn 2 (only after that result comes
 * back) finally decides to call `publish_website` -- a ~7s gap between the
 * two tool-call dispatch timestamps in the same run, before any real page
 * content gets generated. See the `before_prompt_build` hook registered in
 * register() below for the fix: this file is now read directly at request
 * time (loadDesignGuidance below) for THREE call sites, not two -- that
 * hook (main agent-turn path), generateHtml() (/website fast path), and the
 * reply_dispatch claimed-follow-up handler -- one file, one read function,
 * no copy to drift, and no agent-side discovery step required for any of
 * them. The skill declaration stays (cheap, and keeps the compact entry
 * available in case a future turn wants to `read` it explicitly for some
 * reason), it's just no longer load-bearing for getting the full body in
 * front of the model before it generates. */
const SKILL_PATH = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "skills",
  "website-design",
  "SKILL.md",
);

/** How long a bare `/website`'s "awaiting description" state stays claimable.
 * Distinct concern from sitesBySessionKey's own no-timeout policy (that one
 * governs how long a *published* site stays up -- explicit close_website
 * only, by design, see header above). This is just "how long the mic stays
 * open after I asked a question" -- a fixed few minutes is plenty; nobody
 * describing a page they just asked to build takes longer than that. */
const WEBSITE_AWAIT_TIMEOUT_MS = 5 * 60 * 1000;

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

/** sessionKey -> { since }. Set by a bare `/website`, consumed by the
 * reply_dispatch handler below when the next plain-text message for that
 * session arrives (claimed as the description), cleared early by any slash
 * command for that session, and evicted past WEBSITE_AWAIT_TIMEOUT_MS. See
 * header comment for why this is reply_dispatch-based rather than
 * inbound_claim-based. */
const awaitingDescriptionBySessionKey = new Map();

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
    // Spawn failures (missing binary, bad permissions, ...) surface
    // asynchronously as an 'error' event on `proc`, never as a thrown
    // exception -- a try/catch around spawn() would never see this. Without
    // a listener here (or the permanent one added in createSite right after
    // spawn()), this is an unhandled EventEmitter 'error', which is fatal to
    // the whole Node process by default. This one turns it into a normal
    // rejection for this request instead.
    const onError = (err) => {
      cleanup();
      reject(new Error(`failed to start cloudflared (${CLOUDFLARED_PATH}): ${err.message}`));
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
      proc.off("error", onError);
    }
    proc.stdout?.on("data", onData);
    proc.stderr?.on("data", onData);
    proc.on("exit", onExit);
    proc.on("error", onError);
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

  // Cheap upfront check for the common case (binary genuinely missing, e.g.
  // a container recreation that predates this fix) so the reported error is
  // immediate and specific rather than whatever spawn()'s ENOENT happens to
  // say. Not a substitute for the 'error' handlers below -- this can't catch
  // every failure mode (permissions, a binary that vanishes between the
  // check and the spawn, etc.), just the most common one, faster.
  if (!fs.existsSync(CLOUDFLARED_PATH)) {
    try {
      server.close();
    } catch {
      // already closed
    }
    throw new Error(`cloudflared not found at ${CLOUDFLARED_PATH} -- was setup.sh's install step run?`);
  }

  const proc = spawn(CLOUDFLARED_PATH, ["tunnel", "--url", `http://127.0.0.1:${port}`], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  site.cloudflaredProc = proc;
  // Permanent listener for the life of this process (not just the startup
  // window waitForTunnelUrl below covers) -- an EventEmitter's 'error' event
  // is fatal to the whole gateway process if nothing is ever listening, and
  // waitForTunnelUrl's own listener is removed once startup finishes. This
  // is the actual fix for the incident described in the header comment:
  // whatever goes wrong with this child process, ever, gets logged for this
  // one session instead of taking down every other conversation.
  proc.on("error", (err) => {
    console.error(`[website] cloudflared process error (session ${sessionKey}):`, err.message);
  });
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

/** Shared by publish_website (tool) and the /website command: reuse the
 * currently open site for this session if one exists, otherwise create one.
 * Callers are responsible for resolving `sessionKey` first (differs by
 * caller -- see header comment for the tool's toolCallId->sessionKey path
 * and the command handler's direct ctx.sessionKey). */
async function publishForSession(sessionKey, html, title) {
  let reused = true;
  let creating = pendingCreations.get(sessionKey);
  if (!sitesBySessionKey.has(sessionKey) && !creating) {
    reused = false;
    creating = createSite(sessionKey, html, title);
    pendingCreations.set(sessionKey, creating);
    // .finally() returns a NEW promise that mirrors creating's rejection --
    // `creating` itself is properly handled by the `await creating` below
    // (or by whichever concurrent caller joined this same in-flight
    // creation), but this discarded `.finally()` promise is not awaited by
    // anyone. Left uncaught, that's a second, independent unhandled
    // rejection for the exact same failure -- and an unhandled rejection is
    // fatal to the whole process by default, same as the unhandled
    // ChildProcess 'error' event this file otherwise guards against. Caught
    // live by scripts/test-website-crash-safety.mjs -- run it after
    // touching this function.
    creating.finally(() => pendingCreations.delete(sessionKey)).catch(() => {});
  }

  const site = creating ? await creating : sitesBySessionKey.get(sessionKey);
  site.html = html;
  site.title = title;

  const url = `${site.tunnelUrl}/?k=${site.token}`;
  return { url, reused };
}

/** Strip a ```html ... ``` (or bare ```) fence the model may wrap its output
 * in despite being told not to -- cheap insurance, not a parser. */
function stripCodeFence(text) {
  const trimmed = text.trim();
  const match = trimmed.match(/^```(?:html)?\s*\n([\s\S]*?)\n?```$/i);
  return match ? match[1] : trimmed;
}

const WEBSITE_COMMAND_SYSTEM_PROMPT_BASE =
  "You build a single self-contained HTML page on request. Output ONLY the raw HTML document " +
  "(starting with <!DOCTYPE html> or <html>) -- no markdown code fences, no commentary before or " +
  "after. Inline all CSS and JS; do not reference external files or a build step.";

/** Cached after first read -- this only changes on a redeploy, and
 * generateHtml() may run often within one gateway process lifetime. `null`
 * means "already tried, file unavailable" so a missing/broken skill file
 * degrades to the bare base prompt instead of retrying a failing read (and
 * logging a warning) on every single generation. */
let cachedDesignGuidance;

/** Reads the `website-design` skill's own body (see SKILL_PATH comment
 * above) and strips its YAML frontmatter, so the exact same design-system
 * text that ships as a real OpenClaw skill also gets folded directly into
 * the system prompt for the two generation paths that bypass skill
 * injection entirely. One file, no second copy to drift out of sync. */
function loadDesignGuidance() {
  if (cachedDesignGuidance !== undefined) return cachedDesignGuidance;
  try {
    const raw = fs.readFileSync(SKILL_PATH, "utf8");
    const body = raw.replace(/^---\n[\s\S]*?\n---\n/, "").trim();
    cachedDesignGuidance = body;
  } catch (err) {
    console.error(
      `[website] couldn't read design skill at ${SKILL_PATH}, generating with the bare prompt instead:`,
      err instanceof Error ? err.message : String(err),
    );
    cachedDesignGuidance = "";
  }
  return cachedDesignGuidance;
}

function buildWebsiteCommandSystemPrompt() {
  const guidance = loadDesignGuidance();
  return guidance ? `${WEBSITE_COMMAND_SYSTEM_PROMPT_BASE}\n\n${guidance}` : WEBSITE_COMMAND_SYSTEM_PROMPT_BASE;
}

/** Plain text, not markdown -- this goes through the normal command-reply
 * pipeline, which nothing else in this file assumes renders markdown. */
const WEBSITE_INTRO =
  "Website: I build a real, live page from your description -- a dashboard, a form, a small " +
  "internal tool, a landing page, whatever you can picture -- and publish it as a link you can " +
  "open right now. No setup, no build step, just describe it.\n\n" +
  "Send your description as your next message: what it should do, what it should show, how it " +
  "should look if you care. I'll generate it and hand you the link.\n\n" +
  "Already have a site open in this chat? A new description replaces it -- one live page per " +
  "chat at a time.";

/** Shared by the fast path (/website <description> in one message) and the
 * claimed-follow-up path (reply_dispatch below): turn a description into
 * raw HTML via whichever llm.complete() the caller has access to.
 *
 * --- Prompt caching investigation (08-19), UPDATED with live results ---
 *
 * The design guidance folded into systemPrompt above is large (~4.7KB,
 * ~1,150 tokens) and byte-identical on every single call, so in principle
 * this is exactly the shape Gemini's *implicit* caching wants -- on by
 * default for Gemini 2.5+ models, zero client-side setup, and Google's own
 * guidance is "keep the content at the beginning of the request the same."
 *
 * - OpenClaw's plugin-SDK `llm.complete()` has a typed `cacheRetention`
 *   option, but it's dead for this transport -- confirmed by reading the
 *   real shipped transport code: `buildGoogleGenerativeAiParams` never
 *   reads it. The actual Gemini *explicit* cache create/manage path
 *   (`cachedContents`) exists in this OpenClaw build but only for the
 *   embedded agent-turn runner's own session pipeline, with zero plugin
 *   entry point -- a plugin would have to bypass the SDK and hand-roll
 *   Gemini's raw `cachedContents` REST lifecycle itself to get *explicit*
 *   caching. Not done here: substantially bigger, riskier engineering than
 *   what follows shows is actually justified.
 * - The `before_prompt_build` hook above originally used
 *   `appendSystemContext`, which -- traced through this build's own
 *   `composeSystemPromptWithHookContext` -- lands AFTER the per-turn
 *   variable base system prompt, not before it, defeating the whole
 *   "stable prefix" premise. Fixed to `prependSystemContext`, which this
 *   build's own code confirms puts it first, ahead of everything variable.
 * - With that fix live, ran 7 real `openclaw agent --local` calls against
 *   this deployed box (4 pre-fix, 3 post-fix, spanning a cold-cache
 *   container restart and immediate back-to-back repeats) -- every single
 *   one logged `cacheRead: 0` in the real Gemini `usageMetadata`
 *   (`cachedContentTokenCount`, read directly off the wire by this build's
 *   `updateUsage()` in the google transport, not something our code could
 *   fake even if it tried). Prefix was correctly positioned, well over the
 *   documented 1,024-token minimum, and byte-identical across calls --
 *   implicit caching still never engaged, empirically, in this
 *   environment.
 * - Conclusion: implicit caching is real but opaque and best-effort on
 *   Google's side -- it depends on backend cache state this low-volume
 *   BYOK single-tenant sandbox (occasional requests, minutes apart, no
 *   sustained QPS to keep a shard's cache warm) has no way to influence or
 *   guarantee, and OpenClaw exposes no plugin-level lever to force it
 *   (`cacheRetention` is dead for this transport, `cachedContents` has no
 *   plugin entry point). Given that, this is genuinely NOT achievable as a
 *   reliable, verifiable win from the plugin side right now -- reporting
 *   it as such rather than leaving it an unverified assumption. What *is*
 *   real and shipped: the request is now correctly shaped for caching
 *   (prefix position fixed) if Google's infra ever does warm up for this
 *   traffic pattern, and `usage.cacheRead` is logged on every call so a
 *   hit becomes visible the moment one happens, instead of being silently
 *   assumed either way. */
async function generateHtml(llm, description) {
  const completion = await llm.complete({
    messages: [{ role: "user", content: description }],
    systemPrompt: buildWebsiteCommandSystemPrompt(),
    purpose: "website.command.generate",
    maxTokens: 8192,
    temperature: 0.4,
  });
  const cacheRead = completion.usage?.cacheRead ?? 0;
  console.log(
    `[website] generateHtml usage: input=${completion.usage?.input ?? "?"} cacheRead=${cacheRead} output=${completion.usage?.output ?? "?"}`,
  );
  return stripCodeFence(completion.text ?? "");
}

/** Direct Telegram Bot API call -- the same pattern thinking-bubble/index.ts
 * already proved live, used here because the reply_dispatch handler below
 * delivers its reply directly rather than through the dispatcher's own
 * sendFinalReply (see header comment). */
async function tg(botToken, method, body) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TG_FETCH_TIMEOUT_MS),
  });
  const json = await res.json().catch(() => ({}));
  if (!json.ok) {
    throw new Error(`Telegram ${method} failed: ${json.description ?? res.status}`);
  }
  return json;
}

/** Cross-plugin coordination key thinking-bubble/index.ts publishes on
 * `globalThis` -- see that file's "Fix: reply_dispatch-delivered replies"
 * header section and its `getReplyDispatchSettler` doc comment for the full
 * reasoning (reply_dispatch's claim-is-terminal semantics rule out
 * thinking-bubble registering its own reply_dispatch handler for this, and
 * there's no import path between separate workspace-extension plugin
 * directories). Must stay byte-identical to that file's copy of the same
 * string (Symbol.for interns by exact string match) and to
 * plugins/quick-menu/index.ts's copy. */
const THINKING_BUBBLE_SETTLER_KEY = Symbol.for("openclaw-byok.thinking-bubble.getReplyDispatchSettler");

/** Looks up thinking-bubble's settle function by the well-known symbol above
 * and calls it for this session, if present. Safe no-op if thinking-bubble
 * isn't loaded/enabled (lookup misses) or has no placeholder pending for
 * this session (the inner call returns undefined) -- callers use this as
 * `getThinkingBubbleSettler(sessionKey)?.()`. */
function getThinkingBubbleSettler(sessionKey) {
  const getSettler = globalThis[THINKING_BUBBLE_SETTLER_KEY];
  return typeof getSettler === "function" ? getSettler(sessionKey) : undefined;
}

/** `reply_dispatch`'s event carries a `FinalizedMsgContext` (confirmed
 * against this deployed OpenClaw version's own `src/auto-reply/
 * templating.ts`) -- a different shape from `message_received`'s event/ctx
 * pair the old extraction helpers here targeted. Body-field priority
 * (BodyForCommands > CommandBody > RawBody > Body) matches the exact chain
 * ai-farm/plugins/wizbid-tools/index.cjs uses for command detection off this
 * same hook. */
function resolveReplyDispatchBody(finalizedCtx) {
  const body =
    finalizedCtx.BodyForCommands ?? finalizedCtx.CommandBody ?? finalizedCtx.RawBody ?? finalizedCtx.Body ?? "";
  return body.trim();
}

/** Chat-id chain: `ChatId` first (the field templating.ts documents as the
 * "provider-native chat/conversation id"), then the same SenderId/From/To
 * fallback chain ai-farm/plugins/shared/telegram-helpers.cjs's own
 * `resolveChatId` uses against this same hook -- for a Telegram DM (this
 * product's only supported chat type) the sender id and chat id are the
 * same value. */
function resolveReplyDispatchChatId(finalizedCtx) {
  const candidates = [finalizedCtx.ChatId, finalizedCtx.SenderId, finalizedCtx.From, finalizedCtx.To];
  for (const c of candidates) {
    if (typeof c === "string" && c.trim().length > 0) return c.trim();
  }
  return undefined;
}

export default definePluginEntry({
  id: "website",
  name: "Website",
  description: "Publish a self-contained HTML page as a live, token-gated website and close it when done.",
  register(api) {
    // Lazily checking the timeout inside reply_dispatch (below) only
    // evicts an awaiting-state entry when a follow-up message actually
    // arrives for that session -- a bare `/website` nobody ever answers
    // would otherwise sit in the Map forever. This sweep is what makes
    // WEBSITE_AWAIT_TIMEOUT_MS an actual timeout rather than a check that
    // only fires when it's already moot. unref() so it can't keep the
    // process alive on its own.
    setInterval(() => {
      const now = Date.now();
      for (const [sessionKey, awaiting] of awaitingDescriptionBySessionKey) {
        if (now - awaiting.since > WEBSITE_AWAIT_TIMEOUT_MS) {
          awaitingDescriptionBySessionKey.delete(sessionKey);
        }
      }
    }, 60_000).unref();

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

    // --- Killing the skill-read round-trip (08-19) ---
    //
    // Confirmed real via `PluginHookBeforePromptBuildResult` in this
    // deployed version's own shipped `.d.ts` (not guessed from the docs
    // alone): `before_prompt_build` fires before every agent turn's system
    // prompt is built and can return `prependSystemContext`/
    // `appendSystemContext`, whose doc comments both say the same thing --
    // "so providers can cache it (e.g. prompt caching). Use for static
    // plugin guidance instead of prependContext/appendContext to avoid
    // per-turn token cost."
    //
    // Started with `appendSystemContext`, then live-measured (08-19, 4
    // consecutive real `openclaw agent --local` calls against this
    // deployed box) that it produced `cacheRead: 0` every single time
    // despite a stable ~5KB guidance block on every turn. Traced the real
    // cause by reading this build's own shipped
    // `composeSystemPromptWithHookContext` (attempt.thread-helpers-*.js):
    // it joins the request as `[prependSystem, baseSystemPrompt,
    // appendSystem]` -- so `appendSystemContext` lands AFTER the base
    // system prompt (tool defs, AGENTS.md, current date/time, session
    // state), which varies turn to turn. Gemini's implicit caching keys
    // off a stable prefix at the very START of the request (see
    // generateHtml() below); putting the static block at the *end* means
    // the actual prefix the cache would need to match is the *variable*
    // part, so it can never hit. `prependSystemContext` puts it first,
    // ahead of all per-turn-variable content -- the shape caching actually
    // needs. This is a real fix for a real bug in the first version of
    // this hook, not a guess: same call sites, same guidance text, just
    // moved to the position that makes the cache-worthy prefix actually
    // stable.
    //
    // This reuses loadDesignGuidance() unchanged -- the exact same read
    // that already feeds generateHtml()'s systemPrompt for the /website
    // fast path and the reply_dispatch follow-up -- so all three call sites
    // share one source of truth. The agent no longer has any reason to
    // issue a `read` tool call for the skill body before calling
    // `publish_website`: the guidance is already in front of it when it
    // decides whether to build a page at all (confirmed live -- see
    // generateHtml() below for the full caching investigation and its
    // results).
    //
    // Registered for every turn of the agent this plugin is loaded into
    // (there's no cheaper per-turn way to know in advance whether *this*
    // turn will end up building a page -- that's the same reason the
    // model needed a skill-read before, just moved earlier), which is a
    // real, small, ongoing prompt-size cost (loadDesignGuidance()'s body,
    // ~5KB) traded for eliminating the round trip on every turn that does
    // end up calling `publish_website`.
    api.on("before_prompt_build", async () => {
      const guidance = loadDesignGuidance();
      if (!guidance) return;
      return { prependSystemContext: guidance };
    });

    // Claims the next plain-text message after a bare `/website` as the
    // description, generates+publishes it, and replies directly -- see the
    // big header comment's "Fix (round 2)" section for why reply_dispatch
    // (a structural short-circuit, confirmed against this deployed
    // version's own dispatch-from-config.ts) rather than message_received
    // (round 1, an observer hook that let a stray LLM reply through) or
    // inbound_claim (real but gated behind an owner-approval binding flow
    // that doesn't fit this UX).
    api.on(
      "reply_dispatch",
      async (event, ctx) => {
        const finalizedCtx = event.ctx ?? {};
        const sessionKey = event.sessionKey ?? finalizedCtx.SessionKey;
        if (!sessionKey) return;

        const awaiting = awaitingDescriptionBySessionKey.get(sessionKey);
        if (!awaiting) return;

        const text = resolveReplyDispatchBody(finalizedCtx);

        // Any slash command -- /website again, /close, anything -- cancels
        // the wait rather than being misread as a description, and falls
        // through (undefined return) so native/agent dispatch still
        // processes it normally.
        if (text.startsWith("/")) {
          awaitingDescriptionBySessionKey.delete(sessionKey);
          return;
        }

        if (Date.now() - awaiting.since > WEBSITE_AWAIT_TIMEOUT_MS) {
          awaitingDescriptionBySessionKey.delete(sessionKey);
          return;
        }

        if (!text) return;

        // Claim it now, before any await, so a duplicate/retried event for
        // the same message can't double-fire this.
        awaitingDescriptionBySessionKey.delete(sessionKey);

        const provider = finalizedCtx.Provider;
        const chatId = resolveReplyDispatchChatId(finalizedCtx);
        const botToken = process.env.WEBSITE_BOT_TOKEN;
        const llm = api.runtime?.llm;

        if (provider !== "telegram" || !chatId || !botToken || !llm) {
          console.error(
            "[website] can't handle claimed follow-up description: missing telegram identity, bot token, or llm runtime",
          );
          return;
        }

        // NOT captured here (that was the bug, fixed 08-19). The old
        // "capture getThinkingBubbleSettler() early, before the slow LLM
        // call" approach assumed thinking-bubble's own placeholder already
        // exists in pendingBySession by the time reply_dispatch fires for
        // the SAME inbound message. Real evidence (both hooks' DIAG logs
        // on one real Telegram exchange, 08-19) proved that's false:
        // reply_dispatch can reach this point ~40ms after the inbound
        // message, while thinking-bubble's own placeholder send is a real
        // Telegram API round-trip that took ~790ms to complete and land in
        // pendingBySession -- reply_dispatch was checking an empty map.
        // Fix: look the settler up FRESH at each point it's actually
        // invoked, after generateHtml()'s multi-second LLM call has had
        // plenty of time to let thinking-bubble's sub-second placeholder
        // send finish first. getReplyDispatchSettler's own superseded-check
        // (comparing object identity in pendingBySession) still protects
        // against a newer placeholder arriving in between regardless of
        // when the lookup happens, so there's no correctness cost to
        // deferring it -- only a race removed.
        if (ctx.onReplyStart) await ctx.onReplyStart();

        try {
          await withTimeout(
            (async () => {
              const html = await generateHtml(llm, text);
              const published = await publishForSession(sessionKey, html, text.slice(0, 80));
              await tg(botToken, "sendMessage", {
                chat_id: chatId,
                text: `${published.reused ? "Website updated" : "Website published"}: ${published.url}`,
              });
            })(),
            REPLY_DISPATCH_WORK_TIMEOUT_MS,
            "website follow-up",
          );
          // Delete the placeholder right after the real answer is actually
          // sent -- NOT before (that was the 08-19 bug: settling here
          // first, then hanging on the send, left thinking-bubble's own
          // safety net believing there was nothing left to sweep). Same
          // timing thinking-bubble's own reply_payload_sending path uses
          // for the normal agent-turn case.
          getThinkingBubbleSettler(sessionKey)?.();
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          try {
            await tg(botToken, "sendMessage", {
              chat_id: chatId,
              text: `Couldn't build that page: ${message}`,
            });
            // A real reply (the error text) made it out, so settle here too
            // -- otherwise the 3-minute safety net would eventually replace
            // it with a misleading "didn't come through" next to this
            // error. If this send ALSO fails/hangs (bounded now by
            // TG_FETCH_TIMEOUT_MS either way), deliberately leave the
            // placeholder tracked -- the safety net is the true last resort
            // when we couldn't tell the user anything at all.
            getThinkingBubbleSettler(sessionKey)?.();
          } catch (sendErr) {
            console.error(
              "[website] failed to report generation error to chat:",
              sendErr instanceof Error ? sendErr.message : String(sendErr),
            );
          }
        }

        // Delivered directly via the Telegram API above (not through
        // dispatcher.sendFinalReply), so queuedFinal is false and the lane
        // is released explicitly via markIdle -- same shape reseller-tools
        // uses for its own tgFetch-delivered commands (the fix for the
        // "lane stuck in `processing` for 11-30s after a handled command"
        // bug, commit 8146b2e per the memory file).
        ctx.dispatcher.markComplete();
        ctx.recordProcessed("completed");
        ctx.markIdle("website_followup_handled");
        return { handled: true, queuedFinal: false, counts: ctx.dispatcher.getQueuedCounts() };
      },
      { priority: 10 },
    );

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

        // Reserving the pendingCreations slot happens inside
        // publishForSession, synchronously before its first await, so a
        // second publish_website call for this same session (racing in the
        // same turn, or a retry) joins this creation instead of spawning
        // its own tunnel/server -- see pendingCreations comment.
        //
        // Unlike the other two callers of publishForSession (the /website
        // command handler and the claimed-follow-up message_received
        // handler), this one previously had no try/catch: an uncaught
        // rejection here becomes an unhandled promise rejection, which is
        // also fatal to the whole process by default (not the EventEmitter
        // 'error' path this file otherwise guards against, but the same
        // failure mode from this tool's point of view). Report it as a
        // normal failed tool call instead.
        try {
          const { url, reused } = await withTimeout(
            publishForSession(sessionKey, html, title),
            REPLY_DISPATCH_WORK_TIMEOUT_MS,
            "publishForSession",
          );
          return {
            content: [{ type: "text", text: `${reused ? "Website updated" : "Website published"}: ${url}` }],
            details: { url, reused },
          };
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          return {
            content: [{ type: "text", text: `Couldn't publish that page: ${message}` }],
            details: { url: null, reused: false, error: message },
          };
        }
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

    // --- /website slash command ---
    //
    // Two designs were viable per the SDK's own types: (1) light preprocessing
    // + `continueAgent: true`, letting the normal agent turn generate the HTML
    // and call publish_website itself, or (2) the handler generates the HTML
    // itself via the runtime's LLM-completion helper and publishes directly,
    // fully bypassing the agent loop. Went with (2): `continueAgent`'s prompt-
    // passing mechanics (does the continued turn see the raw `/website ...`
    // text, or something rewritten by this handler?) are undocumented -- not
    // one line about it beyond a single feature-matrix table cell in
    // sdk-overview.md -- and it appears in ZERO of the bundled extensions that
    // register commands (memory-core, device-pair, workboard, phone-control,
    // talk-voice, active-memory all grepped clean for it). Design (2), by
    // contrast, is a real documented path: `PluginCommandContext.runtimeContext.llm`
    // is typed as `PluginRuntimeCore["llm"]`, the exact same `.complete({messages,
    // purpose, maxTokens, temperature}) -> {text, ...}` helper sdk-runtime.md
    // documents and gives a working example of. Simpler, deterministic, and
    // actually confirmed to exist -- not chosen by default, chosen because the
    // alternative couldn't be confirmed real without guessing at unstated
    // continuation semantics on a product-facing command.
    api.registerCommand({
      name: "website",
      description: "Build a page from your description and publish it as a live website.",
      acceptsArgs: true,
      handler: async (ctx) => {
        const description = (ctx.args ?? "").trim();
        const sessionKey = ctx.sessionKey ?? "global";

        if (!description) {
          // Explain, then wait for the next message as input -- see header
          // comment and WEBSITE_AWAIT_TIMEOUT_MS for the claiming mechanism
          // and its timeout.
          awaitingDescriptionBySessionKey.set(sessionKey, { since: Date.now() });
          return {
            text: WEBSITE_INTRO,
            continueAgent: false,
          };
        }

        // A real description arrived inline (the fast path) -- any stale
        // awaiting-state from an earlier bare /website in this session no
        // longer applies.
        awaitingDescriptionBySessionKey.delete(sessionKey);

        const llm = ctx.runtimeContext?.llm;
        if (!llm) {
          return {
            text: "Website generation isn't available in this session (no LLM runtime context).",
            continueAgent: false,
          };
        }

        let html;
        try {
          html = await withTimeout(generateHtml(llm, description), REPLY_DISPATCH_WORK_TIMEOUT_MS, "generateHtml");
        } catch (err) {
          return {
            text: `Couldn't generate that page: ${err instanceof Error ? err.message : String(err)}`,
            continueAgent: false,
          };
        }

        let published;
        try {
          published = await withTimeout(
            publishForSession(sessionKey, html, description.slice(0, 80)),
            REPLY_DISPATCH_WORK_TIMEOUT_MS,
            "publishForSession",
          );
        } catch (err) {
          return {
            text: `Generated the page but couldn't publish it: ${err instanceof Error ? err.message : String(err)}`,
            continueAgent: false,
          };
        }

        return {
          text: `${published.reused ? "Website updated" : "Website published"}: ${published.url}`,
          continueAgent: false,
        };
      },
    });
  },
});
WEBSITEPLUGINTS
mkdir -p "$PLUGIN_DIR/skills/website-design"
cat > "$PLUGIN_DIR/skills/website-design/SKILL.md" <<'WEBSITEDESIGNSKILLMD'
---
name: website-design
description: Use whenever generating a self-contained HTML page to publish via publish_website or /website — makes it look like a real, professional product instead of plain unstyled HTML.
metadata: { "openclaw": { "always": true } }
---

# Website design

`publish_website` and `/website` ship whatever HTML you hand them, byte for
byte. There is no template, no CSS pipeline, no reviewer in between — a plain
`<h1>` and unstyled `<div>`s go out exactly as plain and unstyled as they were
written. Treat every page as a real product surface, not a scratch note.

## Decide the look, in this order

1. **The user specified a look, brand, or reference.** Follow it. Their
   explicit ask always outranks anything below.
2. **Otherwise, use the system in this file.** Never fall back to bare
   unstyled HTML — a page with no design system is the failure mode this
   skill exists to prevent.

## The stack: Tailwind v4 + DaisyUI v5, zero build step

This is a single self-contained HTML file with no bundler, so pull both in
as CDN `<link>`/`<script>` tags in `<head>`. Paste this exactly:

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/themes.css">
<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
```

Tailwind's browser build compiles utility classes live in the page, and
DaisyUI layers real component classes (`btn`, `card`, `navbar`, ...) on top —
together they turn raw markup into something that looks designed, with no
separate build step this plugin doesn't have anyway.

## Pick a theme, then use semantic classes

Set `<html data-theme="...">`. Default to **`luxury`** unless the request
points somewhere else. A few other good fits by vibe:

- `corporate` — clean SaaS/dashboard, safe default for internal tools
- `business` — dark, dense, data-heavy admin panels
- `forest` / `night` — dark developer-tool aesthetic
- `cupcake` / `pastel` — friendly, consumer-facing, lighter tone
- `winter` — crisp light theme when `luxury` reads too heavy

Then reach for DaisyUI's **semantic** color classes (`bg-base-100`,
`bg-base-200`, `text-base-content`, `btn-primary`, `badge-secondary`,
`alert-success`, ...) instead of hardcoded Tailwind colors (`bg-slate-800`,
`text-gray-300`). Semantic classes repaint correctly if the theme changes;
hardcoded colors don't and usually clash with whichever theme you picked.

## Layout-safety CSS — paste this every time

The single most common way a generated page "looks broken" is horizontal
overflow on a phone: a nested flex/grid child refusing to shrink below its
content width. Put this in `<head>` on every page, no exceptions:

```html
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :where(.grid, .flex) > * { min-width: 0; }
  :where(p, h1, h2, h3, h4, li, td, th) { overflow-wrap: anywhere; }
  :where(img, svg, video, canvas, iframe) { max-width: 100%; height: auto; }
</style>
```

## Reach for real components, not bare tags

A plain `<button>` and `<div>` is exactly the "plain and not professional"
failure this skill exists to fix. Use DaisyUI's actual components instead —
these are the ones that carry the most visual weight per line of markup:

- **Buttons** — `btn btn-primary` / `btn-outline` / `btn-ghost`, sized with
  `btn-sm`/`btn-lg`
- **Cards** — `card bg-base-100 shadow-xl` with `card-body`, `card-title`,
  `card-actions` for any grouped content block, not just literal products
- **Stats** — `stats` + `stat`/`stat-title`/`stat-value`/`stat-desc` for any
  dashboard number instead of a bare styled `<div>`
- **Tables** — `table` (+ `table-zebra` for readability) for any tabular data
- **Forms** — `input input-bordered`, `select select-bordered`,
  `label`/`fieldset`, `textarea textarea-bordered`
- **Navbar** — `navbar bg-base-100` as the page header on anything with more
  than one section
- **Hero** — `hero` + `hero-content` for a landing page's top section
- **Alerts** — `alert alert-info`/`alert-success`/... for status/feedback
  messages instead of plain colored text

## Visual quality checklist

- **Hierarchy** — one clear "most important thing" per screen, made obvious
  by size/weight/color, not five equally-loud headings.
- **Whitespace** — generous padding/gaps (`p-6`, `gap-4`, `space-y-6`
  territory). Content crammed edge-to-edge reads as unfinished, not dense.
- **One color story** — pick the theme, then 1–2 accent colors used via
  `-primary`/`-secondary`/`-accent` classes. Don't hand-mix extra hues on top.
- **Mobile-first, always** — this is a link opened from Telegram, primarily
  on a phone. Design and mentally check the layout at **~390px wide** as the
  primary target, not desktop. Stack columns (`flex-col md:flex-row`,
  `grid-cols-1 md:grid-cols-3`) rather than assuming room for a wide layout.
WEBSITEDESIGNSKILLMD
docker exec openclaw mkdir -p /data/workspace/.openclaw/extensions/website
docker cp "$PLUGIN_DIR/openclaw.plugin.json" openclaw:/data/workspace/.openclaw/extensions/website/openclaw.plugin.json
docker cp "$PLUGIN_DIR/index.ts" openclaw:/data/workspace/.openclaw/extensions/website/index.ts
docker cp "$PLUGIN_DIR/skills" openclaw:/data/workspace/.openclaw/extensions/website/skills
rm -rf "$PLUGIN_DIR"

# ---------------------------------------------------------------------------
# 7a4. Install the "quick-menu" plugin — defines the persistent Telegram
#      custom keyboard (the grid revealed by the toggle button next to the
#      text input) so a customer can discover /website plus a curated set
#      of useful built-in OpenClaw commands without hunting through docs.
#      Every button's text IS the literal command it sends — see the
#      plugin's own header comment for why a friendlier emoji-label +
#      translation layer (the FarmOps pattern) isn't safely reproducible
#      here. The keyboard is attached via a standalone message this plugin
#      sends directly on /start and /new — matching FarmOps' own proven
#      pattern (ai-farm/scripts/bridge_common.py's 2026-07-25 clear_chat
#      post-mortem) of never attaching reply_markup to a message that gets
#      deleted or edited. See quick-menu/index.ts's header for the full
#      history of why the two prior designs (a standalone announcement,
#      then piggybacking on thinking-bubble's placeholder) didn't work.
#      Also registers the real, deterministic /clearchat command (matching
#      FarmOps' clear_chat) and no longer includes the TTS buttons the
#      product owner asked removed (08-18) -- see quick-menu/index.ts's
#      header for both.
# ---------------------------------------------------------------------------
log "Installing the quick-menu plugin"
PLUGIN_DIR=/tmp/openclaw-quick-menu
mkdir -p "$PLUGIN_DIR"
cat > "$PLUGIN_DIR/openclaw.plugin.json" <<'QUICKMENUPLUGINJSON'
{
  "id": "quick-menu",
  "name": "Quick Menu",
  "description": "Sends the curated Telegram quick-menu keyboard as a standalone, permanent message on /start and /new -- matching FarmOps' proven pattern of never attaching reply_markup to a message that gets deleted or edited. Also provides /clearchat.",
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
QUICKMENUPLUGINJSON
cat > "$PLUGIN_DIR/index.ts" <<'QUICKMENUPLUGINTS'
// Quick Menu plugin
//
// Defines the persistent Telegram custom keyboard (Bot API
// `ReplyKeyboardMarkup` -- the grid revealed by the toggle button next to
// the text input, distinct from the native "/" autocomplete list
// `setMyCommands` already populates) of this product's most useful
// commands, and attaches it via a standalone message this plugin sends
// directly -- never via a message something else deletes or edits.
//
// --- History: two prior designs, both wrong, both real device failures ---
//
// v1 sent a dedicated "Quick menu ready" message on the first
// message_received of a session, tracked in-memory "once per session".
// Rob (product owner), 08-18, with a screenshot: that message re-appeared
// right after a real command reply (e.g. a quick-menu button sending
// `/usage cost`) because the "new session" tracking didn't exclude
// slash-command messages. The ask was "remove it entirely, permanently",
// not "de-duplicate it" -- after a couple of uses the button grid is
// self-explanatory.
//
// v2 attached the keyboard to thinking-bubble's placeholder message (first
// as a plain send-then-delete placeholder, then as a "permanent carrier"
// placeholder that got edited-in-place instead of deleted). Both sub-attempts
// coupled the keyboard's lifecycle to the placeholder's lifecycle, and Rob's
// live testing (08-18) showed the keyboard still wasn't persisting even with
// the edit-in-place version. That's when this got checked against FarmOps
// (`ai-farm/scripts/bridge_common.py` clear_chat, ~376-413), which hit this
// EXACT bug on 2026-07-25 and documented the real, confirmed mechanism in
// its own code comments: "Deleting older messages that originally carried
// the keyboard was found to drop it from the client entirely (Rob,
// 07-25), so it has to be re-asserted here every time." FarmOps' own fix
// is not "pick a message that's deleted less often" -- it's "never let the
// keyboard-carrying message be deletable or editable AT ALL". Every FarmOps
// attach site (/start, /help, /new, clear_chat's confirmation) is a plain
// `send(..., reply_markup=KEYBOARD)` on a message that is sent once and
// never touched again. Its placeholder/"thinking" sends (`TG.send_dim`)
// never carry reply_markup at all -- clean separation between the
// keyboard's lifecycle and the placeholder's lifecycle, not just "a more
// durable placeholder".
//
// --- This design (v3): a real, permanent, standalone message ---
//
// OpenClaw's own reply-delivery path has no passthrough for a custom
// ReplyKeyboardMarkup (dist/types-*.d.ts's ReplyPayload has no
// reply_markup field; its only escape hatch, channelData?.telegram, only
// ever produces an inline_keyboard via buildInlineKeyboard -- a different,
// incompatible keyboard type -- confirmed by tracing the compiled send
// path, see thinking-bubble/index.ts's header for the full trace). So this
// plugin sends its OWN small message directly via the Telegram Bot API
// (the tg() helper below, same direct-API approach FarmOps' own bridge
// uses) riding alongside OpenClaw's natural reply, not replacing it.
//
// Trigger points, matching FarmOps' scope exactly: /start and /new. Both
// are confirmed (live testing + reading OpenClaw's own compiled command
// registry, dist/commands-registry.data-*.js) to be real, distinct request
// events this plugin's message_received hook actually observes:
//   - /start has NO entry in the native command registry at all (no
//     key: "start"/nativeName: "start" anywhere in commands-registry.data),
//     so it falls through to the normal agent-turn dispatch path -- a real,
//     personalized, LLM-generated welcome, not a template.
//   - /new DOES have a native registry entry (key: "new", nativeName:
//     "new", textAlias: "/new", tier: "essential") -- it's a fast built-in
//     that resolves instantly, same category as /help and /status, and
//     never reaches reply_payload_sending.
// Both differ in how OpenClaw itself replies, but message_received fires
// for both regardless (it's the raw-inbound hook, upstream of native-vs-
// agent-turn dispatch) -- so hooking message_received here, matching
// content against /start or /new, and sending our own message immediately
// works uniformly for both without needing to correlate against
// reply_payload_sending (which /new never fires) or depend on any other
// message's delivery timing at all. That's the whole point: this plugin's
// send has zero dependency on any other message's lifecycle.
//
// No "already sent to this chat" durable tracking, matching FarmOps
// exactly -- grepping FarmOps' bridge for any such gate turned up nothing;
// it just unconditionally re-sends reply_markup on every /start, /help,
// /new, relying on Telegram's own client-side keyboard caching (only
// refreshed when a message carrying reply_markup arrives). Rob has not
// objected to /start or /new themselves carrying the keyboard message --
// only to it appearing unprompted after ordinary chat, which this design
// no longer does since only /start/-/new trigger it.
//
// KEYBOARD_ROWS/QUICK_MENU_KEYBOARD are the canonical, curated definition
// of the button grid -- not duplicated elsewhere anymore now that
// thinking-bubble's placeholder has gone back to carrying zero keyboard
// logic (see that file's header for its own, much shorter, note about this).
//
// TTS row removed (product owner, 08-18, live screenshot with the three TTS
// buttons crossed out): that feature isn't ready for a button yet. /clearchat
// and the location-share button take its place -- see their own sections
// below for how each works.
//
// --- /clearchat: real root cause, found live (08-18) ---
//
// /clearchat originally used `api.registerCommand`, same as /website. Live
// testing kept reproducing "Command not found." even after redeploys that
// should have fixed it. Traced into OpenClaw's own compiled source
// (dist/telegram-ingress-spool-*.js ~1357-1377, dist/commands-CjgJ-luM.js
// matchPluginCommand, dist/command-registration-tKF3dsKu.js registerPluginCommand)
// to find the real mechanism: grammy's bot.command() routing table is built
// ONCE at Telegram startup from a snapshot of the live plugin-command
// registry (getPluginCommandSpecs -> the same process-wide `pluginCommands`
// Map singleton, confirmed via Symbol.for("openclaw.pluginCommandsState") --
// not a per-module copy). But the handler that snapshot wires up does a
// SECOND, independent lookup against that same live Map at message time
// (matchPluginCommand). Between those two reads, anything that mutates that
// same singleton can make grammy's wired-up route point at a registry that
// no longer has the command. Confirmed at least two distinct ways this can
// happen in the compiled source, not narrowed down to one: (a) if plugin
// activation is ever re-entered and quick-menu's `register()` fails on that
// later call, the catch path's `rollbackPluginGlobalSideEffects` (dist/
// loader-D8d2EvVh.js ~2274) calls `clearPluginCommandsForPlugin` (dist/
// registry-B8eQDFB4.js ~4790), wiping the entry a prior successful run
// installed; (b) a plugin-registry CACHE hit on a later `loadOpenClawPlugins`
// call runs `restorePluginCommands` (dist/command-registration-tKF3dsKu.js
// ~69-76), which unconditionally clears the live Map and rebuilds it from
// an older snapshot, no exception required at all. Either way, `api.
// registerCommand`'s void return (confirmed in dist/types-*.d.ts) gives the
// plugin no way to see any of this happen. `/website`'s own command hasn't
// shown this symptom, but it's the exact same registration path and the
// exact same shared registry -- there is nothing website-specific
// protecting it, just luck of timing so far.
//
// Fix (round 1): stop depending on that registry entirely for this command.
// Detect the literal "/clearchat" text via `message_received` instead -- the
// same hook /start and /new already use below -- and run the clear-chat
// logic directly, bypassing native command dispatch (and its "Command not
// found." fallback) completely. No more `api.registerCommand` call for
// clearchat, so grammy never wires up a route for it that could point at an
// emptied registry.
//
// --- Fix (round 2), live confirmed with a screenshot, 08-18 ---
//
// Round 1's own documented tradeoff bit for real: `message_received` is a
// pure OBSERVER hook -- it can run its own side effects (the confirmation
// send + bulk delete below) but has no way to stop OpenClaw's normal
// agent-turn dispatch from ALSO seeing the raw "/clearchat" text and having
// the model reply to it conversationally. Rob confirmed live, twice, that
// this produces a stray (sometimes duplicate) LLM reply after the clear
// confirmation -- unacceptable, since the product owner's bar is "behaves
// exactly like wizbid/reseller's own /clearchat", where slash commands never
// reach the LLM at all.
//
// The actual fix: `reply_dispatch`, not `message_received`. Confirmed by
// reading this exact deployed OpenClaw version's own source
// (2026.7.1-2, /opt/openclaw/app/src/auto-reply/reply/dispatch-from-config.ts
// ~2973-3020): the gateway runs `hookRunner.runReplyDispatch(...)` and, if
// any handler returns `{ handled: true, ... }`, returns immediately --
// BEFORE the code path a few lines below that acquires the dispatch
// operation and hands the turn to the agent ever runs. That's a structural
// short-circuit upstream of the LLM call, not a race against it. Also
// confirmed present in this version's `hook-types.ts` (PluginHookReplyDispatchEvent/
// Context/Result, matching field-for-field) and exercised by this version's
// own `wired-hooks-reply-dispatch.test.ts` ("stops at the first handler that
// claims reply dispatch"). This is exactly the mechanism wizbid's and
// reseller's own working `/clearchat` commands use in this same operator's
// ai-farm environment (ai-farm/plugins/wizbid-tools/index.cjs
// `fastPath.kind === 'clearchat'`, ai-farm/plugins/reseller-tools/index.cjs),
// and the exact call sequence below (onReplyStart -> run the command ->
// dispatcher.markComplete() -> recordProcessed('completed') ->
// markIdle(reason)) matches that proven pattern, documented in
// `~/.claude/projects/-home-lenov-projects-ai-farm/memory/
// feedback_openclaw_plugin_for_fast_dispatch.md`.
//
// /start and /new deliberately stay on `message_received` below -- /new is a
// real native command that already suppresses the agent turn on its own,
// and /start intentionally piggybacks the LLM's own personalized welcome
// (see this file's top section). Only /clearchat had no native counterpart
// to rely on, so it's the only command moved to `reply_dispatch`.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

/** 2-per-row grid, matching FarmOps' own keyboard shape. `/website` and
 * `/new` lead (this product's headline feature, then the most common
 * reset action); `/clearchat` and `/usage cost` next, `/status`/`/help`
 * close out discovery. The location-share button trails alone (odd count)
 * since it's not a slash command, just a `request_location` tap target.
 * Deliberately `/usage cost`, not bare `/usage` -- per
 * docs/concepts/usage-tracking.md, bare `/usage` CYCLES the per-response
 * footer mode (off -> tokens -> full -> off) on every invocation, so a
 * button sending it would do something different each tap depending on
 * hidden prior state. `/usage cost` is a stable, idempotent local cost
 * summary -- the actual "check my spend" behavior a BYOK customer wants
 * from a button, not a footer-verbosity toggle. */
export const KEYBOARD_ROWS: ({ text: string; request_location?: boolean })[][] = [
  [{ text: "/website" }, { text: "/new" }],
  [{ text: "/clearchat" }, { text: "/usage cost" }],
  [{ text: "/status" }, { text: "/help" }],
  [{ text: "📍 Share Location", request_location: true }],
];

/** `resize_keyboard` shrinks the keyboard to fit its buttons instead of
 * full-size default rows. `is_persistent` and `one_time_keyboard` are
 * deliberately omitted -- confirmed in FarmOps' own bridges that setting
 * `is_persistent` forces the keyboard permanently visible and removes
 * Telegram's own show/hide toggle icon, which is exactly the "toggle
 * button in the text input area" behavior the product ask wants
 * preserved. Sent as a plain nested object (not a JSON.stringify'd
 * string) since this goes out over an `application/json` POST body, where
 * Telegram's Bot API accepts `reply_markup` as a native nested object;
 * stringifying is only required for multipart/form-encoded requests. */
export const QUICK_MENU_KEYBOARD = { keyboard: KEYBOARD_ROWS, resize_keyboard: true };

/** Matches bare "/start", a deep-link payload ("/start payload"), and the
 * "/start@BotName" form Telegram uses in group chats. */
function isStartCommand(content: string): boolean {
  return /^\/start(@\w+)?(\s|$)/.test(content);
}

/** Matches bare "/new" and the "/new@BotName" group-chat form. */
function isNewCommand(content: string): boolean {
  return /^\/new(@\w+)?(\s|$)/.test(content);
}

/** Matches bare "/clearchat" and the "/clearchat@BotName" group-chat form.
 * No args accepted (matching the old registerCommand's acceptsArgs: false) --
 * anything after the command word just fails this match and falls through
 * to normal handling, same as before. */
function isClearChatCommand(content: string): boolean {
  return /^\/clearchat(@\w+)?\s*$/.test(content);
}

const START_KEYBOARD_TEXT = "👋 Quick menu ready -- tap the icon beside the message box anytime.";
const NEW_KEYBOARD_TEXT = "🆕 Fresh session -- quick menu ready.";

/** See plugins/website/index.ts's 08-19 "hang incident: root cause and fix"
 * header comment for the full story -- this file's `tg()` had the exact
 * same unbounded-`fetch()` shape, and /clearchat's performClearChat below
 * had the same settle-before-send ordering bug. Must stay in sync with the
 * copies of this same constant in plugins/website/index.ts and
 * plugins/thinking-bubble/index.ts (independent copies -- no shared import
 * path between workspace-extension plugins). */
const TG_FETCH_TIMEOUT_MS = 15_000;

async function tg(botToken: string, method: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TG_FETCH_TIMEOUT_MS),
  });
  const json = (await res.json().catch(() => ({}))) as { ok?: boolean; description?: string };
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

/** Cross-plugin coordination key thinking-bubble/index.ts publishes on
 * `globalThis` -- see that file's "Fix: reply_dispatch-delivered replies"
 * header section and its `getReplyDispatchSettler` doc comment for the full
 * reasoning (reply_dispatch's claim-is-terminal semantics rule out
 * thinking-bubble registering its own reply_dispatch handler for this, and
 * there's no import path between separate workspace-extension plugin
 * directories). Must stay byte-identical to that file's copy of the same
 * string (Symbol.for interns by exact string match) and to
 * plugins/website/index.ts's copy. */
const THINKING_BUBBLE_SETTLER_KEY = Symbol.for("openclaw-byok.thinking-bubble.getReplyDispatchSettler");

/** Looks up thinking-bubble's settle function by the well-known symbol above
 * and calls it for this session, if present. Safe no-op if thinking-bubble
 * isn't loaded/enabled (lookup misses) or has no placeholder pending for
 * this session (the inner call returns undefined) -- callers use this as
 * `getThinkingBubbleSettler(sessionKey)?.()`. */
function getThinkingBubbleSettler(sessionKey: string): (() => void) | undefined {
  const getSettler = (globalThis as Record<PropertyKey, unknown>)[THINKING_BUBBLE_SETTLER_KEY] as
    | ((sessionKey: string) => (() => void) | undefined)
    | undefined;
  return typeof getSettler === "function" ? getSettler(sessionKey) : undefined;
}

/** `reply_dispatch`'s event carries a `FinalizedMsgContext` (confirmed against
 * this deployed OpenClaw version's own `src/auto-reply/templating.ts`), a
 * completely different shape from `message_received`'s event/ctx pair above
 * -- these two resolvers are NOT interchangeable with extractChatId/
 * extractProvider. Body-field priority (BodyForCommands > CommandBody >
 * RawBody > Body) matches the exact chain wizbid-tools/index.cjs uses for
 * command detection off this same hook. */
function resolveReplyDispatchBody(finalizedCtx: Record<string, unknown>): string {
  const body =
    (finalizedCtx as { BodyForCommands?: string }).BodyForCommands ??
    (finalizedCtx as { CommandBody?: string }).CommandBody ??
    (finalizedCtx as { RawBody?: string }).RawBody ??
    (finalizedCtx as { Body?: string }).Body ??
    "";
  return body.trim();
}

/** Chat-id chain: `ChatId` first (the field templating.ts documents as the
 * "provider-native chat/conversation id"), then the same SenderId/From/To
 * fallback chain ai-farm/plugins/shared/telegram-helpers.cjs's own
 * `resolveChatId` uses against this same hook in wizbid/reseller's proven,
 * live-working `/clearchat` -- for a Telegram DM (this product's only
 * supported chat type) the sender id and chat id are the same value. */
function resolveReplyDispatchChatId(finalizedCtx: Record<string, unknown>): string | undefined {
  const candidates = [
    (finalizedCtx as { ChatId?: string }).ChatId,
    (finalizedCtx as { SenderId?: string }).SenderId,
    (finalizedCtx as { From?: string }).From,
    (finalizedCtx as { To?: string }).To,
  ];
  for (const c of candidates) {
    if (typeof c === "string" && c.trim().length > 0) return c.trim();
  }
  return undefined;
}

// --- /clearchat ---
//
// Matches FarmOps' clear_chat exactly (ai-farm/scripts/bridge_common.py:
// 376-421, read-only reference, not touched). Telegram has no "list chat
// history" API, so there's no way to know which message ids exist. The
// trick: send the confirmation FIRST, with its FINAL text (not a
// "clearing..." placeholder edited after -- FarmOps' own 07-25 post-mortem
// found a stuck "clearing..." reads as a dead message) -- the id Telegram
// hands back for that send IS the newest id in the chat, since ids are
// sequential per chat. Then walk backward CLEARCHAT_DEPTH ids and bulk-
// delete via deleteMessages (Telegram's 100-id-per-call max), falling back
// to individual deleteMessage calls -- run concurrently, not sequentially,
// so a sparse/short chat (mostly-nonexistent ids) doesn't stall on 100
// serial round-trips -- if a batch is rejected. Ids that don't exist,
// already deleted, or are >48h old are silently skipped by Telegram itself;
// no local id tracking needed.
//
// The confirmation is deliberately NEVER deleted (excluded from the walked
// range) -- FarmOps found live that a fully empty chat drops Telegram back
// to its "never started" view, forcing a fresh Start tap before the
// keyboard reappears. It carries QUICK_MENU_KEYBOARD directly (the same
// direct-Telegram-API send /start and /new use above) since
// editMessageText's reply_markup can't attach a custom ReplyKeyboardMarkup
// -- only the original sendMessage can, and deleting an earlier
// keyboard-carrying message was found (FarmOps, 07-25) to drop the keyboard
// from the client entirely, so it has to be re-asserted here every time.
//
// Purely visual chat cleanup -- does NOT reset the agent's own
// conversation/session state, which is what /new (already a separate real
// OpenClaw command) is for.
//
// Triggered from reply_dispatch (see header's "Fix (round 2)" section for
// why this isn't message_received or api.registerCommand), so this is a
// plain function called directly from that hook, not a PluginCommandContext
// handler -- takes botToken/chatId straight, no ctx to unpack.
const CLEARCHAT_DEPTH = 300;
const CLEARCHAT_TEXT = "✅ chat cleared. /clearchat to clear again.";

function clearChatIds(newestId: number, depth: number): number[] {
  const stop = Math.max(newestId - depth, 0);
  const ids: number[] = [];
  for (let id = newestId - 1; id > stop; id--) ids.push(id);
  return ids;
}

async function bulkDeleteMessages(botToken: string, chatId: string, ids: number[]): Promise<void> {
  for (let i = 0; i < ids.length; i += 100) {
    const batch = ids.slice(i, i + 100);
    try {
      await tg(botToken, "deleteMessages", { chat_id: chatId, message_ids: batch });
    } catch (err) {
      console.error(
        "[quick-menu] clearchat: deleteMessages batch rejected, falling back to individual deletes:",
        err instanceof Error ? err.message : String(err),
      );
      await Promise.all(
        batch.map((id) => tg(botToken, "deleteMessage", { chat_id: chatId, message_id: id }).catch(() => {})),
      );
    }
  }
}

async function performClearChat(
  botToken: string,
  chatId: string,
  sessionKey?: string,
): Promise<void> {
  let newest: number | undefined;
  try {
    const sent = await tg(botToken, "sendMessage", {
      chat_id: chatId,
      text: CLEARCHAT_TEXT,
      reply_markup: QUICK_MENU_KEYBOARD,
    });
    newest = (sent as { result?: { message_id?: number } }).result?.message_id;
    // Delete the thinking-bubble placeholder right AFTER the real
    // confirmation is actually sent, not before -- see website/index.ts's
    // 08-19 "hang incident" header comment for the real bug this ordering
    // fixes (settling first, then hanging/failing on the send, leaves
    // thinking-bubble's own 3-minute safety net believing there's nothing
    // left to sweep even though the user got nothing). Looked up FRESH
    // here, not captured before this function was called -- see that same
    // header's "Fix (round 3)" note for the separate race that avoids (this
    // hook can reach this point before thinking-bubble's own async
    // placeholder send has landed in its map). See getThinkingBubbleSettler
    // above for why this is a globalThis lookup.
    if (sessionKey) getThinkingBubbleSettler(sessionKey)?.();
  } catch (err) {
    console.error("[quick-menu] clearchat: failed to send confirmation:", err instanceof Error ? err.message : String(err));
    // Deliberately leave the placeholder tracked if sessionKey is set --
    // the 3-minute safety net is the true last resort when we couldn't
    // tell the user anything at all.
    return;
  }

  if (typeof newest === "number") {
    await bulkDeleteMessages(botToken, chatId, clearChatIds(newest, CLEARCHAT_DEPTH));
  }
}

export default definePluginEntry({
  id: "quick-menu",
  name: "Quick Menu",
  description: "Sends the curated Telegram quick-menu keyboard as a standalone, permanent message on /start and /new -- matching FarmOps' proven pattern of never attaching reply_markup to a message that gets deleted or edited.",
  register(api) {
    api.on(
      "message_received",
      async (event) => {
        const ctx = (event.context ?? {}) as Record<string, unknown>;
        const botToken = process.env.QUICK_MENU_BOT_TOKEN;
        if (!botToken) return;

        const provider = extractProvider(event as Record<string, unknown>, ctx);
        const chatId = extractChatId(event as Record<string, unknown>, ctx);
        if (provider !== "telegram" || !chatId) return;

        const content = typeof (event as { content?: unknown }).content === "string"
          ? (event as { content: string }).content.trim()
          : "";

        // /clearchat is handled from the reply_dispatch registration below,
        // not here -- see this file's "Fix (round 2)" header section for why.

        let text: string | undefined;
        if (isStartCommand(content)) text = START_KEYBOARD_TEXT;
        else if (isNewCommand(content)) text = NEW_KEYBOARD_TEXT;
        if (!text) return;

        try {
          await tg(botToken, "sendMessage", {
            chat_id: chatId,
            text,
            reply_markup: QUICK_MENU_KEYBOARD,
          });
        } catch (err) {
          console.error("[quick-menu] failed to send keyboard-carrier message:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );

    // /clearchat: reply_dispatch, not message_received -- see this file's
    // "Fix (round 2)" header section. This hook fires BEFORE OpenClaw builds
    // the agent turn (confirmed against this deployed version's own
    // dispatch-from-config.ts), so returning `{ handled: true, ... }` here
    // structurally prevents any LLM call for this message, not just races
    // one. Call sequence (onReplyStart -> run the command ->
    // dispatcher.markComplete() -> recordProcessed('completed') ->
    // markIdle(reason)) matches wizbid/reseller's own proven /clearchat
    // exactly, per feedback_openclaw_plugin_for_fast_dispatch.md.
    api.on(
      "reply_dispatch",
      async (event, ctx) => {
        const botToken = process.env.QUICK_MENU_BOT_TOKEN;
        if (!botToken) return;

        const finalizedCtx = (event.ctx ?? {}) as Record<string, unknown>;
        const provider = (finalizedCtx as { Provider?: string }).Provider;
        if (provider !== "telegram") return;

        const content = resolveReplyDispatchBody(finalizedCtx);
        if (!isClearChatCommand(content)) return;

        const chatId = resolveReplyDispatchChatId(finalizedCtx);
        if (!chatId) return;

        const sessionKey = event.sessionKey ?? (finalizedCtx as { SessionKey?: string }).SessionKey;

        if (ctx.onReplyStart) await ctx.onReplyStart();

        try {
          await performClearChat(botToken, chatId, sessionKey);
        } catch (err) {
          console.error("[quick-menu] clearchat: unexpected failure:", err instanceof Error ? err.message : String(err));
        }

        // Delivered directly via the Telegram API above (not through
        // dispatcher.sendFinalReply), so queuedFinal is false and the lane
        // is released explicitly via markIdle -- same shape reseller-tools
        // uses for its own tgFetch-delivered commands, and the same fix
        // (commit 8146b2e, per the memory file) for the "lane stuck in
        // `processing` for 11-30s after a handled command" bug that
        // omitting markIdle causes.
        ctx.dispatcher.markComplete();
        ctx.recordProcessed("completed");
        ctx.markIdle("quick_menu_clearchat_handled");
        return { handled: true, queuedFinal: false, counts: ctx.dispatcher.getQueuedCounts() };
      },
      { priority: 10 },
    );

    // Permanent, low-noise proof this plugin's hooks are actually wired up
    // at startup -- cheap insurance after a debugging session that spent
    // hours unable to trust api.registerCommand's silent-void registration
    // path for exactly this kind of confirmation. If this line is missing
    // from `docker logs openclaw` after a boot, quick-menu's register()
    // itself didn't run to completion.
    console.log(
      "[quick-menu] message_received triggers registered: /start, /new (keyboard sender); reply_dispatch registered: /clearchat",
    );
  },
});
QUICKMENUPLUGINTS
docker exec openclaw mkdir -p /data/workspace/.openclaw/extensions/quick-menu
docker cp "$PLUGIN_DIR/openclaw.plugin.json" openclaw:/data/workspace/.openclaw/extensions/quick-menu/openclaw.plugin.json
docker cp "$PLUGIN_DIR/index.ts" openclaw:/data/workspace/.openclaw/extensions/quick-menu/index.ts
rm -rf "$PLUGIN_DIR"

# ---------------------------------------------------------------------------
# 7a5. Install the "location" plugin — lets the user share their Telegram
#      location via the quick-menu's "Share Location" button and injects it
#      as short-lived context into subsequent turns, matching Nelita's
#      location-sharing behavior (nelita_bridge.py, read-only reference).
#      See location/index.ts's header for the full mechanism, including the
#      real OpenClaw platform limitations this ran into (no structured
#      location field in the message_received hook payload -- only the
#      flattened "📍 lat, lon" text; Live Location repeat ticks never reach
#      plugin hooks at all) and how it was verified against those limits.
# ---------------------------------------------------------------------------
log "Installing the location plugin"
PLUGIN_DIR=/tmp/openclaw-location
mkdir -p "$PLUGIN_DIR"
cat > "$PLUGIN_DIR/openclaw.plugin.json" <<'LOCATIONPLUGINJSON'
{
  "id": "location",
  "name": "Location",
  "description": "Lets the user share their Telegram location via the quick-menu button and injects it as short-lived context into subsequent turns, matching Nelita's location-sharing behavior.",
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
LOCATIONPLUGINJSON
cat > "$PLUGIN_DIR/index.ts" <<'LOCATIONPLUGINTS'
// Location plugin
//
// Matches Nelita's location-sharing behavior (nelita_bridge.py, read-only
// reference, not touched): a "📍 Share Location" keyboard button (defined
// in plugins/quick-menu/index.ts's KEYBOARD_ROWS -- this plugin doesn't own
// the keyboard) lets the user hand over their coordinates once, this plugin
// remembers them for a few hours, and any turn asked something location-
// dependent (weather, nearby places, travel time) within that window gets
// a short context line about where the user is. Not a weather feature by
// itself -- a "does the model know where the user is" primitive.
//
// --- What plugins can actually see here: verified against the compiled
//     bundle, not assumed from docs (same discipline as everything else
//     touched in this repo today) ---
//
// message_received's shipped event type (PluginHookMessageReceivedEvent,
// dist/hook-types-*.d.ts) has no lat/lon/location field, and tracing the
// exact function that builds that event (toPluginMessageReceivedEvent,
// dist/message-hook-mappers-*.js) confirms its `metadata` object is a fixed,
// enumerated list of fields that doesn't include one either. Telegram's own
// channel plugin DOES parse message.location/message.venue into a
// structured object (extractTelegramLocation, dist/sent-message-cache-*.js)
// -- but that structured data only ever feeds the model-facing PROMPT
// context (docs/channels/location.md's LocationLat/LocationLon/... fields),
// never the plugin hook payload. The only trace of a location share a
// plugin can see at all is the flattened text OpenClaw's Telegram channel
// renders into `content` (formatLocationText, dist/channel-inbound-*.js):
//   "📍 <lat>, <lon>" (+" ±<n>m" if accuracy is known) for a pin/venue share
//   "🛰 Live location: <lat>, <lon>" (+accuracy) for a live share
// So this plugin regex-parses that text. This is a real, structural
// limitation of this OpenClaw version, not a design choice -- there is no
// structured location surface for plugin hooks to read.
//
// Telegram's Live Location repeat ticks (position updates while a live
// share is active) arrive as `edited_message` Telegram updates, not
// `message` updates. Confirmed by reading the compiled Telegram ingress
// (dist/telegram-ingress-spool-*.js): `bot.on("edited_message", ...)`
// routes only through recordEditedMessageForReplyChain (a reply-chain
// cache), which never calls into the inbound-hook pipeline that produces
// message_received -- unlike `bot.on("message", ...)`, which does. So
// message_received never fires again for a live-location refresh tick:
// every location match this plugin ever sees is a first share, never a
// repeat. That's convenient (no is_edit disambiguation needed, unlike
// Nelita's Python bridge, which polls raw Telegram updates directly and has
// to filter edited_message ticks itself) but it's also a real, honest gap:
// unlike Nelita, an active Live Location share's position here goes stale
// after LOCATION_FRESH_MS like an ordinary one-shot pin -- it does NOT keep
// refreshing silently in the background, because OpenClaw's plugin surface
// has nothing to refresh it from.
//
// message_received is observation-only (handler returns void -- confirmed
// from its exact type, dist/hook-types-*.d.ts) -- it cannot stop the normal
// agent turn from also seeing and replying to the same "📍 <lat>, <lon>"
// text. Same real, visible degradation plugins/website/index.ts already
// flags for its own claimed-follow-up path: sharing a location may produce
// TWO replies (this plugin's short ack, and whatever the model naturally
// says back to a raw coordinate string) until/unless OpenClaw adds a way to
// claim an inbound message outright.
//
// Storage: in-memory Map, matching this repo's current, deliberate
// convention (as of commit 300ff41 -- see quick-menu/thinking-bubble's own
// history in their headers) of NOT persisting plugin state under
// /data/plugin-state/... anymore; that durable-file approach was tried
// earlier today for an unrelated problem (the keyboard-carrier message) and
// abandoned in favor of a simpler design. A 6h freshness window is short
// enough that losing it on a container restart/redeploy is a minor,
// acceptable degradation -- consistent with plugins/website/index.ts's own
// sitesBySessionKey/awaitingDescriptionBySessionKey being in-memory-only
// despite representing "real" state too.
//
// Context injection: before_prompt_build (dist/hook-runner-global-*.js's
// runBeforePromptBuild -- genuinely dispatched, not just documented,
// confirmed by reading the hook runner itself, not just hooks.md) is the
// hook PROMPT_INJECTION_HOOK_NAMES lists for exactly this. Its ctx argument
// (PluginHookAgentContext) carries `sessionKey`, the same correlation key
// message_received's event carries, used here to look up the right chat's
// stored location. Whether this hook actually fires and actually reaches
// the model was verified live against the test box -- see the repo's
// verification notes for what was actually observed, not assumed.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const LOCATION_FRESH_MS = 6 * 60 * 60 * 1000; // 6h, matching Nelita's LOCATION_FRESH_SECS default

/** Matches formatLocationText's exact output (dist/channel-inbound-*.js) --
 * the only location data visible to a plugin hook in this OpenClaw version.
 * See header comment. */
// The bare 📍 alternative can, in principle, match a user manually typing/
// pasting two decimal numbers next to a pin emoji -- there's no structured
// signal to disambiguate that from a real share (see header comment for
// why). Accepted false-positive risk given the platform's real constraints;
// worst case is a stale/wrong location context for one turn.
const LOCATION_TEXT_RE = /(🛰 Live location:|📍)\s*(-?\d+\.\d+),\s*(-?\d+\.\d+)/;

type StoredLocation = { lat: number; lon: number; ts: number; isLive: boolean };

/** sessionKey -> last known location. In-memory only -- see header comment. */
const locationBySessionKey = new Map<string, StoredLocation>();

function parseLocationText(content: string): { lat: number; lon: number; isLive: boolean } | undefined {
  const m = content.match(LOCATION_TEXT_RE);
  if (!m) return undefined;
  const lat = Number(m[2]);
  const lon = Number(m[3]);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return undefined;
  return { lat, lon, isLive: m[1].startsWith("🛰") };
}

async function tg(botToken: string, method: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json().catch(() => ({}))) as { ok?: boolean; description?: string };
  if (!json.ok) {
    throw new Error(`Telegram ${method} failed: ${json.description ?? res.status}`);
  }
  return json;
}

/** Same defensive fan-out pattern as plugins/quick-menu/index.ts and
 * plugins/website/index.ts's own extractChatId -- the real runtime event
 * carries more candidate fields than its shipped .d.ts type does. */
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

/** Fresh copy for this product -- not Nelita's wording. Doesn't promise a
 * live-tracking duration (unlike Nelita) since this plugin never sees
 * Live Location's repeat ticks -- see header comment. */
const LOCATION_ACK_TEXT =
  "📍 Got your location. I'll use it for anything nearby -- weather, places, travel time -- for the next few hours.";

export default definePluginEntry({
  id: "location",
  name: "Location",
  description:
    "Lets the user share their Telegram location via the quick-menu button and injects it as short-lived context into subsequent turns, matching Nelita's location-sharing behavior.",
  register(api) {
    // Lazy eviction inside before_prompt_build only evicts a session's entry
    // when that session actually gets another turn -- a chat that shares a
    // location once and never turns again would otherwise leak forever.
    // Same sweep pattern as plugins/website/index.ts's
    // awaitingDescriptionBySessionKey for the identical reason. unref() so
    // it can't keep the process alive on its own.
    setInterval(() => {
      const now = Date.now();
      for (const [sessionKey, loc] of locationBySessionKey) {
        if (now - loc.ts > LOCATION_FRESH_MS) locationBySessionKey.delete(sessionKey);
      }
    }, 60_000).unref();

    api.on(
      "message_received",
      async (event, ctx) => {
        const e = (event ?? {}) as Record<string, unknown>;
        const c = (ctx ?? {}) as Record<string, unknown>;

        const provider = extractProvider(e, c);
        if (provider !== "telegram") return;

        const content = typeof e.content === "string" ? e.content : "";
        const loc = parseLocationText(content);
        if (!loc) return;

        const sessionKey = (typeof e.sessionKey === "string" && e.sessionKey) || (c as { sessionKey?: string }).sessionKey || "global";
        locationBySessionKey.set(sessionKey, { lat: loc.lat, lon: loc.lon, ts: Date.now(), isLive: loc.isLive });

        const botToken = process.env.LOCATION_BOT_TOKEN;
        const chatId = extractChatId(e, c);
        if (!botToken || !chatId) return;

        try {
          await tg(botToken, "sendMessage", { chat_id: chatId, text: LOCATION_ACK_TEXT });
        } catch (err) {
          console.error("[location] failed to send location ack:", err instanceof Error ? err.message : String(err));
        }
      },
      { priority: 10 },
    );

    api.on("before_prompt_build", async (_event, ctx) => {
      const sessionKey = (ctx as { sessionKey?: string } | undefined)?.sessionKey ?? "global";
      const loc = locationBySessionKey.get(sessionKey);
      if (!loc) return;

      const age = Date.now() - loc.ts;
      if (age > LOCATION_FRESH_MS) {
        locationBySessionKey.delete(sessionKey);
        return;
      }

      const minutes = Math.max(0, Math.round(age / 60000));
      const when = minutes < 1 ? "just now" : `${minutes} min ago`;
      return {
        prependContext:
          `[location: the user's last shared position is latitude ${loc.lat.toFixed(4)}, longitude ` +
          `${loc.lon.toFixed(4)} (shared ${when}). Use it only if the request is location-dependent ` +
          `(weather, nearby places, travel time); ignore it otherwise. Never read raw coordinates back to ` +
          `the user -- name the place if you can determine one, otherwise just use it silently.]\n\n`,
      };
    });
  },
});
LOCATIONPLUGINTS
docker exec openclaw mkdir -p /data/workspace/.openclaw/extensions/location
docker cp "$PLUGIN_DIR/openclaw.plugin.json" openclaw:/data/workspace/.openclaw/extensions/location/openclaw.plugin.json
docker cp "$PLUGIN_DIR/index.ts" openclaw:/data/workspace/.openclaw/extensions/location/index.ts
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
// Quick-menu plugin (installed above as a workspace extension), same
// allow/load-paths trust dance as thinking-bubble/website above.
cfg.plugins.entries['quick-menu'] = { enabled: true };
cfg.plugins.allow = Array.from(new Set([...(cfg.plugins.allow || []), 'quick-menu']));
cfg.plugins.load.paths = Array.from(new Set([...(cfg.plugins.load.paths || []), '/data/workspace/.openclaw/extensions/quick-menu']));
// Location plugin (installed above as a workspace extension), same
// allow/load-paths trust dance as the others above.
cfg.plugins.entries['location'] = { enabled: true };
cfg.plugins.allow = Array.from(new Set([...(cfg.plugins.allow || []), 'location']));
cfg.plugins.load.paths = Array.from(new Set([...(cfg.plugins.load.paths || []), '/data/workspace/.openclaw/extensions/location']));
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
