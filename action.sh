#!/system/bin/sh
# Action button: toggle Tailscale ON/OFF.
#
# OFF  = `tailscale down` + stop the tailscaled daemon
# ON   = start the daemon + `tailscale up` (reuses stored prefs)
#        If the device is not logged in, grabs a login URL, prints it and
#        tries to open the browser.
#
# Works from KernelSU Action, MMRL and Magisk managers (root shell).

MODDIR="${0%/*}"
TS_DIR="/data/adb/tailscale"

export HOME="${TS_DIR}"
export PATH="${TS_DIR}/bin:${TS_DIR}/scripts:/data/adb/magisk:/data/adb/ksu/bin:${PATH}"

SERVICE="${TS_DIR}/scripts/tailscaled.service"

# Timestamped status lines (manager shows action output after the run;
# without times you can't tell what happened when).
say() { echo "[$(date +%H:%M:%S)] $*"; }

[ -f "$SERVICE" ] || {
	say "! tailscaled.service not found at $SERVICE"
	say "! Module data missing — reinstall the module."
	exit 1
}

daemon_running() {
	# match the daemon binary's own cmdline ("tailscaled --tun=..."), NOT the
	# tailscaled.service script — a bare "tailscaled" pattern matches the
	# script's cmdline too, so the action button can toggle the wrong way
	# when the daemon is dead but the script is alive.
	busybox pgrep -f "tailscaled --tun" >/dev/null 2>&1
}

backend_state() {
	# no jq on Android — parse with grep/sed only
	tailscale status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

login_url_from_daemon() {
	# `tailscale login` prints the auth URL and blocks until the flow
	# completes; run it briefly with timeout — the login flow keeps going
	# inside the daemon after the CLI exits.
	timeout 12 tailscale login 2>&1 | grep -o 'https://login\.tailscale\.com/[a-zA-Z/0-9]*' | tail -1
}

open_url() {
	am start -a android.intent.action.VIEW -d "$1" >/dev/null 2>&1 || true
}

if daemon_running; then
say "- Tailscale is ON — turning OFF..."
timeout 8 tailscale down >/dev/null 2>&1 || true
if tailscaled.service stop; then
	say "- Tailscale OFF (daemon stopped)."
	"${TS_DIR}/scripts/moddesc.sh" stopped 2>/dev/null || true
else
		say "! Failed to stop the tailscaled daemon."
		exit 1
	fi
else
say "- Tailscale is OFF — turning ON..."
if ! tailscaled.service start; then
	say "! Failed to start the tailscaled daemon."
	exit 1
fi
# The daemon can need several seconds before its socket answers; retry `up`
# until the backend reports Running/NeedsLogin (same race the WebUI had).
EXIT="$(cat "${TS_DIR}/exitnode" 2>/dev/null)"
say "- Daemon starting..."
# Wait for the socket (daemon still booting after service start) instead of
# burning the first loop iterations on blind sleeps. Typically instant.
for i in $(seq 1 12); do
  [ -S "${TS_DIR}/run/tailscaled.sock" ] && break
  sleep 0.5
done
say "- Control channel ready, joining tailnet..."
OK=1; STATE=""
for i in $(seq 1 8); do
  [ "$i" -gt 1 ] && echo "- Join attempt $i/8..."
  sleep 1
  PREFS="$(tailscale debug prefs 2>/dev/null)"
	case "$PREFS" in *'"CorpDNS": true'*) DNS=true;; *) DNS=false;; esac
	case "$PREFS" in *'"RouteAll": true'*) RA=true;; *) RA=false;; esac
	case "$PREFS" in *0.0.0.0/0*) ADV=true;; *) ADV=false;; esac
	case "$PREFS" in *'"ExitNodeAllowLANAccess": true'*) LAN=true;; *) LAN=false;; esac
	case "$PREFS" in *'"ShieldsUp": true'*) SH=true;; *) SH=false;; esac
	case "$PREFS" in *'"RunSSH": true'*) SSH=true;; *) SSH=false;; esac
	timeout 8 tailscale up --accept-dns=$DNS --accept-routes=$RA \
		--advertise-exit-node=$ADV --exit-node-allow-lan-access=$LAN \
		--shields-up=$SH --ssh=$SSH ${EXIT:+--exit-node=$EXIT} >/dev/null 2>&1 || true
	STATE="$(backend_state)"
	case "$STATE" in
	Running) OK=0; break;;
	NeedsLogin) OK=2; break;;
	esac
done
if [ "$OK" = 1 ]; then
	say "! Daemon started but backend never came up (state: ${STATE:-unknown})."
	say "! Try: su -c 'tailscaled.service restart'"
	"${TS_DIR}/scripts/moddesc.sh" stopped 2>/dev/null || true
	exit 1
fi
"${TS_DIR}/scripts/moddesc.sh" 2>/dev/null || true
	case "$STATE" in
	Running)
		say "- Tailscale ON — connected."
		;;
	NeedsLogin | "")
		say "- Daemon ON, but not logged in. Generating login URL..."
		URL="$(login_url_from_daemon)"
		if [ -n "$URL" ]; then
			say "- Login URL (open in browser to log in):"
			say "$URL"
			open_url "$URL"
			say "- Login flow started. Check status after authorizing."
		else
			say "! Could not get a login URL. Try: su -c 'tailscale login'"
		fi
		;;
	*)
		say "- Daemon ON (backend state: $STATE)."
		;;
	esac
fi

exit 0
