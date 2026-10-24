#!/system/bin/sh
DIR=$(dirname "$(realpath "$0")")
# shellcheck source=../settings.sh
S="$DIR/../settings.sh"
[ -f "$S" ] || S="/data/adb/tailscale/settings.sh"
. "$S"
case "$1" in
    postinstall)
      rm -rf $TS_RUN_DIR && mkdir -p $TS_RUN_DIR
      tailscaled.service restart >> "/dev/null" 2>&1 &
      return 0
    ;;
esac
start_service() {
  if [ ! -f "${TS_MOD_DIR}/disable" ]; then
    tailscaled.service start >> "/dev/null" 2>&1
  fi
}
start_inotifyd() {
  for PID in $(busybox pidof inotifyd); do
    if grep -q "tailscaled.inotify" "/proc/$PID/cmdline"; then
      kill -9 "$PID"
    fi
  done
  echo "${CURRENT_TIME} [Info]: Starting tailscaled inotify service" > "${TS_RUN_LOG_FILE}"
  inotifyd "tailscaled.inotify" "${TS_MOD_DIR}" >> "/dev/null" 2>&1 &
}
start_netenv_watch() {
  local pidfile="${TS_RUN_DIR}/netenv.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0
  fi
  "${TS_DIR}/scripts/netenv.sh" watch >>"${TS_RUN_DIR}/netenv.log" 2>&1 &
  echo $! > "$pidfile"
}

start_healthcheck() {
  local pidfile="${TS_RUN_DIR}/healthcheck.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0
  fi
  (
    while :; do
      "${TS_DIR}/scripts/healthcheck.sh" 2>/dev/null
      sleep 60
    done
  ) >>"${TS_RUN_DIR}/healthcheck.log" 2>&1 &
  echo $! > "$pidfile"
}

module_version=$(busybox awk -F'=' '!/^ *#/ && /version=/ { print $2 }' "$TS_MOD_PROP" 2>/dev/null)
log Info "Tailscale module version : ${module_version}."

# Mirror Android's per-network DNS resolvers into resolv.conf and stock
# table main with a physical default route — see netenv.sh for the why.
if [ -x "${TS_DIR}/scripts/netenv.sh" ]; then
    "${TS_DIR}/scripts/netenv.sh" || log Warning "network environment sync failed"
fi

# Another Tailscale client holding the VPN wins the routing rules for every
# uid, including ours; two TUNs cannot coexist. Surface it instead of
# letting the daemon fail with messages that look like a module bug.
if dumpsys connectivity 2>/dev/null | grep -q "VPN:com.tailscale.ipn"; then
    log Warning "Official Tailscale app is connected and owns the VPN — stop it, or this module cannot tunnel."
fi

# Default MagicDNS to ON if not explicitly disabled
[ -f "${TS_RUN_DIR}/magicdns.enabled" ] || touch "${TS_RUN_DIR}/magicdns.enabled" 2>/dev/null || true

start_service
start_inotifyd
start_netenv_watch
start_healthcheck