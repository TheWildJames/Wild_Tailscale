#!/system/bin/sh
# healthcheck.sh — daemon auto-recovery.
# Checks if tailscaled is alive; restarts it (and re-runs netenv) if dead.
# Intended to run every 60s via the watch loop in netenv.sh or a cron job.

DIR=$(dirname "$(realpath "$0")")
S="$DIR/../settings.sh"
[ -f "$S" ] || S="/data/adb/tailscale/settings.sh"
. "$S"

# Self-heal the netenv watch loop first (it has died silently before, leaving
# a stale pidfile and no re-sync on network changes) — independent of daemon.
if [ -f "${TS_RUN_DIR}/netenv.pid" ] && ! kill -0 "$(cat "${TS_RUN_DIR}/netenv.pid")" 2>/dev/null; then
    rm -f "${TS_RUN_DIR}/netenv.pid" 2>/dev/null
    "${TS_DIR}/scripts/netenv.sh" watch >>"${TS_RUN_DIR}/netenv.log" 2>&1 &
    echo $! > "${TS_RUN_DIR}/netenv.pid"
    log Info "healthcheck: restarted dead netenv watch loop"
fi

if busybox pgrep -f "tailscaled" >/dev/null 2>&1; then
    "${TS_DIR}/scripts/moddesc.sh" 2>/dev/null || true
    exit 0
fi

log Warning "tailscaled is not running — restarting"
"${TS_DIR}/scripts/netenv.sh" 2>/dev/null || true
"${TS_DIR}/scripts/tailscaled.service" start 2>/dev/null || true
"${TS_DIR}/scripts/moddesc.sh" starting 2>/dev/null || true
log Info "healthcheck: restart attempted"
