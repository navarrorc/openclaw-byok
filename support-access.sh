#!/usr/bin/env bash
#
# Toggle-based support re-invite. YOU control when we can SSH in — turn it
# on when you want help, turn it off when we've told you we're done. No
# fixed timer cutting us off mid-fix: real support work sometimes runs
# longer than expected, so the default is manual on/off, not a clock.
#
# Usage:
#   sudo ./support-access.sh on              # grant access now, stays on until you run 'off'
#   sudo ./support-access.sh on --hours 4    # optional: also auto-expire after N hours
#   sudo ./support-access.sh on --minutes 2  # optional: short window (testing only)
#   sudo ./support-access.sh off             # revoke access right now
#   sudo ./support-access.sh status          # show whether access is currently granted
#
# How it works: 'on' appends the support key with a comment tagged
# "rob-support-temp-<unix-timestamp>". By default that's it — access stays
# on until you run 'off'. If you pass --hours/--minutes, it ALSO schedules
# a `systemd-run --on-active=<window>` job as a backstop that removes the
# same tagged line automatically, in case you forget. No dependency on the
# `at` package. Nothing else on the box is touched.

set -euo pipefail

# SUPPORT_KEY_OVERRIDE exists only so this mechanism can be tested end-to-end
# with a disposable keypair instead of the real support key — leave unset in
# normal use.
SUPPORT_KEY="${SUPPORT_KEY_OVERRIDE:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGLht2zexUX15j/gwzQ1827INhA41DoEDTgST9bgIUz rnavarro70@gmail.com}"
AUTH_KEYS_FILE="/root/.ssh/authorized_keys"
WINDOW_HOURS=""
WINDOW_MINUTES=""

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[ $# -ge 1 ] || die "Usage: $0 {on|off|status} [--hours N | --minutes N]"
ACTION="$1"; shift

while [ $# -gt 0 ]; do
    case "$1" in
        --hours)   WINDOW_HOURS="$2"; shift 2 ;;
        --minutes) WINDOW_MINUTES="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run this as root (sudo ./support-access.sh)."

# Cancel any pending auto-expire backstop from a previous 'on --hours/--minutes'.
# Safe no-op if none is scheduled.
cancel_pending_timer() {
    systemctl stop openclaw-support-expire.timer openclaw-support-expire.service >/dev/null 2>&1 || true
}

case "$ACTION" in
    status)
        if [ -f "$AUTH_KEYS_FILE" ] && grep -q 'rob-support-temp-' "$AUTH_KEYS_FILE"; then
            log "Support access is currently ON."
            grep 'rob-support-temp-' "$AUTH_KEYS_FILE"
            if systemctl is-active openclaw-support-expire.timer >/dev/null 2>&1; then
                echo "Auto-expire backstop is scheduled: $(systemctl show -p TriggerTimeUSecRealtime --value openclaw-support-expire.timer 2>/dev/null || echo 'see systemctl list-timers')"
            fi
        else
            log "Support access is currently OFF."
        fi
        exit 0
        ;;

    off)
        cancel_pending_timer
        if [ -f "$AUTH_KEYS_FILE" ] && grep -q 'rob-support-temp-' "$AUTH_KEYS_FILE"; then
            REMOVED=$(grep -c 'rob-support-temp-' "$AUTH_KEYS_FILE")
            sed -i '/rob-support-temp-/d' "$AUTH_KEYS_FILE"
            log "Revoked $REMOVED active support grant(s). Support access is now OFF."
        else
            log "No active support grants found. Support access is already OFF."
        fi
        exit 0
        ;;

    on)
        if [ -f "$AUTH_KEYS_FILE" ] && grep -q 'rob-support-temp-' "$AUTH_KEYS_FILE"; then
            log "Support access is already ON — nothing to do. Run '$0 off' to revoke it."
            exit 0
        fi

        TAG="rob-support-temp-$(date +%s)"
        install -d -m 700 /root/.ssh
        touch "$AUTH_KEYS_FILE"
        chmod 600 "$AUTH_KEYS_FILE"

        echo "${SUPPORT_KEY} # ${TAG}" >> "$AUTH_KEYS_FILE"

        BACKSTOP_LINE="none — stays on until you run: sudo $0 off"
        if [ -n "$WINDOW_HOURS" ] || [ -n "$WINDOW_MINUTES" ]; then
            if [ -n "$WINDOW_MINUTES" ]; then
                WINDOW_ARG="${WINDOW_MINUTES}min"
                WINDOW_DESC="${WINDOW_MINUTES} minute(s)"
            else
                WINDOW_ARG="${WINDOW_HOURS}h"
                WINDOW_DESC="${WINDOW_HOURS} hour(s)"
            fi
            systemd-run --unit="openclaw-support-expire" \
                --on-active="$WINDOW_ARG" \
                --description="Backstop auto-expire for OpenClaw support SSH access (${TAG})" \
                /bin/sh -c "sed -i '/${TAG}/d' '${AUTH_KEYS_FILE}'; logger -t openclaw-support-access 'backstop expired grant ${TAG}'" \
                >/dev/null
            EXPIRY_LOCAL=$(date -d "+${WINDOW_ARG}" 2>/dev/null || true)
            BACKSTOP_LINE="in ${WINDOW_DESC}$( [ -n "$EXPIRY_LOCAL" ] && echo " (around ${EXPIRY_LOCAL})" ), in case you forget to turn it off"
        fi

        cat <<SUMMARY

=============================================================
 Support access is now ON.

 - Key tag:       ${TAG}
 - Turns off:     when YOU run: sudo $0 off
 - Auto-backstop: ${BACKSTOP_LINE}

 Support now has SSH access to this box (root@$(hostname -I | awk '{print $1}')).
 It stays on for as long as you need — there's no clock cutting it off
 mid-fix. When we tell you we're done and everything checks out, run:

     sudo $0 off
=============================================================
SUMMARY
        ;;

    *)
        die "Unknown action '$ACTION'. Usage: $0 {on|off|status} [--hours N | --minutes N]"
        ;;
esac
