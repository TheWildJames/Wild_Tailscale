#!/system/bin/sh
# diag-bundle.sh — one-tap diagnostics bundle for bug reports.
# Collects daemon state, network config, DNS state and recent logs into a
# timestamped tar.gz under /sdcard/Download. Read-only: changes nothing.
# Usage: diag-bundle.sh  (prints the bundle path on success)
DIR=$(dirname "$(realpath "$0")")
S="$DIR/../settings.sh"
[ -f "$S" ] || S="/data/adb/tailscale/settings.sh"
[ -f "$S" ] && . "$S" 2>/dev/null || true
TSBIN="${TS_DIR:-/data/adb/tailscale}/bin/tailscale"
[ -x "$TSBIN" ] || TSBIN="tailscale"

OUTDIR="${TS_RUN_DIR:-/data/adb/tailscale/run}/diag.$$"
BUNDLE="/sdcard/Download/ts-diag-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p "$OUTDIR" || exit 1

{
  echo "=== version ==="
  "$TSBIN" version 2>&1
  echo; echo "=== status ==="
  "$TSBIN" status 2>&1
  echo; echo "=== prefs ==="
  "$TSBIN" debug prefs 2>&1
} >"$OUTDIR/tailscale.txt" 2>&1

{
  echo "=== netcheck (20s) ==="
  timeout 20 "$TSBIN" netcheck 2>&1
} >"$OUTDIR/netcheck.txt" 2>&1

{
  echo "=== ip rules (tailnet-relevant) ==="
  ip rule 2>/dev/null | grep -E "9002|9003|5240|5210|5230|5250|5270" || echo "(none)"
  echo; echo "=== table 253 ==="
  ip route show table 253 2>/dev/null || echo "(empty)"
  echo; echo "=== tailscale0 routes ==="
  ip route show table all 2>/dev/null | grep -E "tailscale0|100\.100\.100\.100" | head -20
  echo; echo "=== DNAT rules ==="
  iptables -t nat -L OUTPUT -n 2>/dev/null | grep -E "DNAT|Chain" || echo "(none)"
  echo; echo "=== active network ==="
  dumpsys connectivity 2>/dev/null | grep -m1 "Active default network" || echo "(unknown)"
  echo; echo "=== /etc/resolv.conf ==="
  cat /etc/resolv.conf 2>/dev/null || echo "(unreadable)"
  echo; echo "=== /etc/hosts (tailnet lines) ==="
  grep -E "^100\.|^fd7a" /etc/hosts 2>/dev/null || echo "(none)"
  echo; echo "=== netenv sig ==="
  cat "${TS_RUN_DIR:-/data/adb/tailscale/run}/netenv.sig" 2>/dev/null || echo "(none)"
} >"$OUTDIR/network.txt" 2>&1

{
  echo "=== tailscaled.log (tail 150) ==="
  tail -150 "${TS_RUN_DIR:-/data/adb/tailscale/run}/tailscaled.log" 2>/dev/null || echo "(no log)"
  echo; echo "=== runs.log (tail 30) ==="
  tail -30 "${TS_RUN_DIR:-/data/adb/tailscale/run}/runs.log" 2>/dev/null || echo "(no log)"
  echo; echo "=== netenv.log (tail 30) ==="
  tail -30 "${TS_RUN_DIR:-/data/adb/tailscale/run}/netenv.log" 2>/dev/null || echo "(no log)"
} >"$OUTDIR/logs.txt" 2>&1

if tar -czf "$BUNDLE" -C "$OUTDIR" . 2>/dev/null; then
  rm -rf "$OUTDIR"
  echo "$BUNDLE"
  exit 0
else
  rm -rf "$OUTDIR"
  echo "FAILED to write bundle" >&2
  exit 1
fi
