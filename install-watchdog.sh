#!/usr/bin/env bash
#
# Installs the OpenClaw self-healing watchdog: a systemd timer that checks
# the openclaw container is actually running and restarts the compose stack
# if not. `restart: unless-stopped` (already set in docker-compose.yml)
# handles a crashed container in the normal case; this watchdog exists for
# the cases that doesn't cover — e.g. the Docker daemon itself wedged, or
# the container is stuck "Restarting" in a crash loop that compose can't
# detect from inside.
#
# Auto-update (docker compose pull) is OFF by default — silently changing
# a customer's running agent version is a real behavior-change risk. To
# turn it on, set OPENCLAW_AUTO_UPDATE=true in /opt/openclaw/watchdog.env
# and the next scheduled run will pull + redeploy the latest image tag.
#
# Safe to re-run.

set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
WATCHDOG_SCRIPT=/usr/local/sbin/openclaw-watchdog.sh
ENV_FILE="$OPENCLAW_DIR/watchdog.env"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<'EOF'
# Watchdog config. Edit and it takes effect on the next scheduled run
# (every 5 minutes) — no restart needed.

# Set to "true" to let the watchdog `docker compose pull && up -d` on a
# schedule (once per day) and pick up new OpenClaw image releases
# automatically. Default is off: you control when you upgrade.
OPENCLAW_AUTO_UPDATE=false
EOF
fi

cat > "$WATCHDOG_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
ENV_FILE="$OPENCLAW_DIR/watchdog.env"
STATE_FILE="/var/lib/openclaw-watchdog/last-update"
LOG_TAG="openclaw-watchdog"

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
OPENCLAW_AUTO_UPDATE="${OPENCLAW_AUTO_UPDATE:-false}"

cd "$OPENCLAW_DIR"

# 1. Container health check — catches Docker-daemon-level weirdness that
#    `restart: unless-stopped` alone doesn't (e.g. daemon wedged and the
#    container is stuck, not actually restarting).
STATUS=$(docker inspect --format '{{.State.Status}}' openclaw 2>/dev/null || echo "missing")
if [ "$STATUS" != "running" ]; then
    logger -t "$LOG_TAG" "openclaw container status='$STATUS', forcing compose up -d"
    docker compose up -d || logger -t "$LOG_TAG" "compose up -d failed"
fi

# 2. Optional daily auto-update, off by default.
if [ "$OPENCLAW_AUTO_UPDATE" = "true" ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    TODAY=$(date -u +%Y-%m-%d)
    LAST=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    if [ "$TODAY" != "$LAST" ]; then
        logger -t "$LOG_TAG" "auto-update enabled, pulling latest images"
        if docker compose pull -q && docker compose up -d; then
            echo "$TODAY" > "$STATE_FILE"
            logger -t "$LOG_TAG" "auto-update complete"
        else
            logger -t "$LOG_TAG" "auto-update pull/up failed, leaving current version running"
        fi
    fi
fi
SCRIPT
chmod 755 "$WATCHDOG_SCRIPT"

cat > /etc/systemd/system/openclaw-watchdog.service <<EOF
[Unit]
Description=OpenClaw self-healing watchdog (restart check + optional auto-update)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=OPENCLAW_DIR=$OPENCLAW_DIR
ExecStart=$WATCHDOG_SCRIPT
EOF

cat > /etc/systemd/system/openclaw-watchdog.timer <<'EOF'
[Unit]
Description=Run the OpenClaw self-healing watchdog every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now openclaw-watchdog.timer

echo "Watchdog installed: checks every 5 min, auto-update is OFF by default."
echo "To enable auto-update: edit $ENV_FILE, set OPENCLAW_AUTO_UPDATE=true."
