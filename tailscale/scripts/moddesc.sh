#!/system/bin/sh
# moddesc.sh — single source of truth for the manager module-list status line.
# Usage: moddesc.sh [state]
#   state: stopped|connected|login|starting|disconnected|machineauth
#   no arg: derive from `tailscale status --json` (daemon down => stopped).
# Writes module.prop `description=` only when the state key changes
# (tracked in run/desc.key), so callers can invoke it freely — WebUI poll,
# action button, boot, healthcheck loop.
DIR=$(dirname "$(realpath "$0")")
S="$DIR/../settings.sh"
[ -f "$S" ] || S="/data/adb/tailscale/settings.sh"
[ -f "$S" ] && . "$S" 2>/dev/null || true

MODPROP="${TS_MOD_PROP:-/data/adb/modules/magisk-tailscaled/module.prop}"
KEYFILE="${TS_RUN_DIR:-/data/adb/tailscale/run}/desc.key"

key="$1"
if [ -z "$key" ]; then
    # Absolute path: root's default PATH has no module bin dir (the WebUI
    # and action.sh export their own PATH, boot/service contexts don't).
    TSCLI="${TS_DIR:-/data/adb/tailscale}/bin/tailscale"
    [ -x "$TSCLI" ] || TSCLI="tailscale"
    if ! ST="$("$TSCLI" status --json 2>/dev/null)"; then
        key="stopped"
    else
        BS="$(printf '%s' "$ST" | grep -o '"BackendState": *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')"
        case "$BS" in
            Running) key="connected";;
            NeedsLogin|NoState) key="login";;
            Starting) key="starting";;
            Stopped) key="disconnected";;
            NeedsMachineAuth) key="machineauth";;
            *) key="stopped";;
        esac
    fi
fi

# Always write: other writers (the service's own start/stop messages) stomp
# module.prop outside this script, so a keyfile-only gate can leave their
# text in place. A sed rewrite with identical content is harmless.
case "$key" in
    stopped)      MSG="⛔ Stopped";;
    connected)    MSG="⚡ VPN connected";;
    login)        MSG="⚠ Login required";;
    starting)     MSG="⏳ Starting";;
    disconnected) MSG="⛔ VPN disconnected";;
    machineauth)  MSG="⏳ Machine auth";;
    *) exit 0;;
esac

T=$(date +"%H:%M" 2>/dev/null)
if [ -f "$MODPROP" ]; then
    # shellcheck disable=SC2154
    sed -i "s/^description=.*/description=[ ⏲ $T | $MSG ]/" "$MODPROP" 2>/dev/null || true
    printf '%s' "$key" >"$KEYFILE" 2>/dev/null || true
fi
exit 0
