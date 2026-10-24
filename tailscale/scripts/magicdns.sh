#!/system/bin/sh
# magicdns.sh — toggle MagicDNS iptables DNAT rules
# Usage: magicdns.sh on|off
DIR=$(dirname "$(realpath "$0")")
S="$DIR/../settings.sh"
[ -f "$S" ] || S="/data/adb/tailscale/settings.sh"
. "$S"

case "$1" in
    on)
        touch "${TS_RUN_DIR}/magicdns.enabled" 2>/dev/null
        # Add DNAT rules (idempotent)
        iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || \
            iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null
        iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || \
            iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null
        # Also PREROUTING for forwarded traffic
        iptables -t nat -C PREROUTING -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || \
            iptables -t nat -A PREROUTING -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null
        iptables -t nat -C PREROUTING -p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || \
            iptables -t nat -A PREROUTING -p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null
        echo "MagicDNS: ON"
        ;;
    off)
        rm -f "${TS_RUN_DIR}/magicdns.enabled" 2>/dev/null
        iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || true
        iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || true
        iptables -t nat -D PREROUTING -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || true
        iptables -t nat -D PREROUTING -p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || true
        echo "MagicDNS: OFF"
        ;;
    status)
        if [ ! -f "${TS_RUN_DIR}/magicdns.enabled" ]; then
            echo "OFF"
            return 0
        fi
        if iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null; then
            echo "ON"
        else
            echo "OFF"
        fi
        ;;
    *)
        echo "Usage: $0 on|off|status"
        exit 1
        ;;
esac