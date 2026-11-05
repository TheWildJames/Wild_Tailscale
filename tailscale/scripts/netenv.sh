#!/system/bin/sh
# netenv.sh — give the GOOS=linux tailscaled binary what Android refuses to.
#
# Android's networking model
# --------------------------
# DNS: there is no /etc/resolv.conf and no net.dns* properties. netd owns the
#      resolvers per network and exposes them only through the DnsResolver
#      Binder API (since Android 8). A GOOS=linux Go binary cannot call that
#      API, so without a resolv.conf Go falls back to 127.0.0.1:53 / [::1]:53,
#      where nothing listens -> "connection refused", then "no DNS fallback
#      candidates remain". We mirror the *active* network's resolvers from
#      `dumpsys connectivity` into /system/etc/resolv.conf (/etc is a symlink
#      to /system/etc). netd's own servers are used first because carrier and
#      captive-portal resolvers often only answer themselves; public servers
#      are a last resort only.
#
# Routing: netd keeps every default route in per-network tables (wlan0,
#      rmnet1, ...) and selects one per socket with fwmark. It never puts a
#      default in the stock tables. tailscaled marks its own sockets
#      fwmark 0x80000/0xff0000 and escapes its own tunnel with rules
#      5210 -> main, 5230 -> default (table 253), 5250 -> unreachable.
#      Android's main table only holds the LAN prefix, so the daemon's dials
#      die at rule 5250 with ENETUNREACH. We copy the physical default into
#      table 253 (only fwmark 0x80000 traffic ever reads it, so no app is
#      affected) and make sure a rule points there even if tailscaled's rule
#      set changes.
#
# Runs once at service start, then watch_loop(): a cheap 3 s route-table
# poll triggers the full (dumpsys-based) sync only on change, so a
# WiFi <-> cellular handover is picked up within seconds instead of waiting
# out a fixed 15 s poll. Every step is idempotent.

DIR=$(dirname "$(realpath "$0")")
S="$DIR/../settings.sh"
[ -f "$S" ] || S="/data/adb/tailscale/settings.sh"
# shellcheck source=../settings.sh
. "$S"

RESOLV_STAGE="${TS_DIR}/resolv.conf"
RESOLV_TARGET="/etc/resolv.conf"
HOSTS_STAGE="${TS_DIR}/hosts"
HOSTS_TARGET="/etc/hosts"
SIG_FILE="${TS_RUN_DIR}/netenv.sig"
DUMP="${TS_RUN_DIR}/connectivity.dump"
NETENV_INTERVAL="${NETENV_INTERVAL:-15}"
SHADOW_TABLE=253       # numeric on purpose: Android's rt_tables has no "default" alias
MARK_RULE_PREF=5240    # belt-and-braces rule for fwmark 0x80000
TAILNET_RULE_PREF=9002 # ahead of netd's per-network rules (11000/15040/31000)
DNAT_SPEC_UDP="-p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53"
DNAT_SPEC_TCP="-p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53"

log_msg() {
    printf '%s %s\n' $(date +%H:%M:%S) "$*" >&2
    command -v log >/dev/null 2>&1 && log Info "netenv: $*" || true
}

active_netid() {
    dumpsys connectivity 2>/dev/null |
        sed -n 's/^Active default network: \([0-9][0-9]*\).*/\1/p' |
        head -1
}

net_block() { # $1 = netid -> only that network's NetworkAgentInfo block
    [ -n "$1" ] || return 0
    # dumpsys prints `NetworkAgentInfo{network{102} ...}` and then the
    # LinkProperties (InterfaceName / DnsAddresses) on the following lines,
    # so the fields are never on the header line itself. Walk the dump and
    # keep lines from the matching header until the next header.
    awk -v id="$1" '
        /NetworkAgentInfo\{network\{/ {
            f = 0
            if (match($0, /network\{[0-9]+\}/)) {
                cur = substr($0, RSTART + 8, RLENGTH - 9)
                if (cur == id) f = 1
            }
        }
        f
    ' "$DUMP" 2>/dev/null
}

net_field() { # $1 = netid, $2 = sed expression over that network's block
    net_block "$1" | sed -n "$2" | head -1
}

add_server() { # $1 = address; append once, max 3
    case " $SERVERS " in *" $1 "*) return 0 ;; esac
    [ "$(printf '%s\n' "$SERVERS" | grep -c .)" -ge 3 ] && return 0
    SERVERS="${SERVERS:+$SERVERS }$1"
}

# --- DNS -------------------------------------------------------------------
write_resolv() { # stdin = desired content
    # Keep our own copy current first: it is the fallback source for the bind
    # mount and the file the daemon's private /etc mirror is built from.
    cat >"$RESOLV_STAGE" 2>/dev/null || return 1
    chcon u:object_r:system_file:s0 "$RESOLV_STAGE" 2>/dev/null || true

    # /etc is /system/etc and read-only. Writing it directly only works on
    # ROMs that ship the file already bind-mounted (module overlay). Try that,
    # then a bind mount, then give up quietly — the daemon does not need it.
    if (cat "$RESOLV_STAGE" >"$RESOLV_TARGET") 2>/dev/null; then
        return 0
    fi
    (touch "$RESOLV_TARGET") 2>/dev/null || true
    if mount --bind "$RESOLV_STAGE" "$RESOLV_TARGET" 2>/dev/null; then
        return 0
    fi
    return 1
}

write_hosts() { # stdin = desired content
    cat >"$HOSTS_STAGE" 2>/dev/null || return 1
    chcon u:object_r:system_file:s0 "$HOSTS_STAGE" 2>/dev/null || true
    if (cat "$HOSTS_STAGE" >"$HOSTS_TARGET") 2>/dev/null; then
        return 0
    fi
    (touch "$HOSTS_TARGET") 2>/dev/null || true
    mount --bind "$HOSTS_STAGE" "$HOSTS_TARGET" 2>/dev/null && return 0
    return 1
}

sync_hosts() {
    local body cur
    # tailscale status text table: "<ip> <hostname> ..." — self + peers.
    # Absolute path: PATH is minimal in boot/service/root-shell contexts.
    TSCLI="${TS_DIR}/bin/tailscale"
    [ -x "$TSCLI" ] || TSCLI="tailscale"
    body=$("$TSCLI" status 2>/dev/null |
        awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $2 != "" && $2 != "-" {print $1" "$2}' |
        sort -u)
    [ -n "$body" ] || return 0
    body="# generated by netenv.sh — tailnet hostnames (bindhosts-style)
$body"
    cur=$(cat "$HOSTS_TARGET" 2>/dev/null)
    # Android ships only a stub hosts file; rewrite when content differs.
    if [ "$cur" = "$body" ]; then
        return 0
    fi
    if printf '%s\n' "$body" | write_hosts; then
        log_msg "hosts <- $(printf '%s\n' "$body" | sed -n '$=') tailnet names"
    else
        log_msg "note: no global ${HOSTS_TARGET}; names resolve via MagicDNS only"
    fi
    return 0
}

sync_dns() { # $1 = netid, $2 = servers
    local body changed=1 priv
    body="# generated by netenv.sh — Android netd resolvers for net ${1:-?}
$(for ip in $2; do printf 'nameserver %s\n' "$ip"; done)"

    if [ "$(cat "$RESOLV_TARGET" 2>/dev/null)" = "$body" ]; then
        changed=0
    fi

    if [ "$changed" = 1 ]; then
        if printf '%s\n' "$body" | write_resolv; then
            log_msg "DNS <- ${2} (net ${1:-?})"
        else
            # Expected on setups without a writable/overlaid /etc/resolv.conf
            # (e.g. KernelSU without a metamodule): the daemon resolves from
            # its private /etc copy, which is updated just below.
            log_msg "note: no global ${RESOLV_TARGET}; using private etc copy"
        fi
    fi

    # The daemon lives in a private mount namespace with its own /system/etc
    # copy (private_etc in tailscaled.service), snapshotted at daemon start.
    # Without this mirror it keeps the PREVIOUS network's resolvers forever:
    # fresh daemon on data + stale WiFi DNS = control never resolves and
    # `tailscale up` fails until WiFi returns. Write through to the live
    # private copy (the bind makes it visible to the daemon instantly, no
    # restart needed).
    priv="${TS_DIR}/etc/resolv.conf"
    if [ -d "${TS_DIR}/etc" ] && [ "$(cat "$priv" 2>/dev/null)" != "$body" ]; then
        mkdir -p "${TS_DIR}/etc" 2>/dev/null
        printf '%s\n' "$body" >"$priv" 2>/dev/null && \
            log_msg "DNS -> private etc copy" || \
            log_msg "WARNING: could not write ${priv}"
    fi
    return 0
}

# --- routing ---------------------------------------------------------------
sync_route() { # $1 = iface, $2 = gw4, $3 = gw6
    local iface="$1" gw="$2" gw6="$3"

    # Subnet-router / exit-node duties need forwarding; harmless otherwise.
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true

    if [ -n "$iface" ]; then
        if [ -n "$gw" ]; then
            ip route replace default via "$gw" dev "$iface" table "$SHADOW_TABLE" 2>/dev/null ||
                ip route replace default via "$gw" dev "$iface" onlink table "$SHADOW_TABLE" 2>/dev/null
        else
            # Cellular point-to-point links (rmnet) have no gateway: `ip route
            # get` returns no "via". A dev-only default is valid there — without
            # it the stale WiFi default stays in table 253 and the daemon's
            # fwmark traffic dies the moment WiFi drops.
            ip route replace default dev "$iface" table "$SHADOW_TABLE" 2>/dev/null || true
        fi
        if [ -n "$gw6" ]; then
            ip -6 route replace default via "$gw6" dev "$iface" table "$SHADOW_TABLE" 2>/dev/null
        else
            ip -6 route replace default dev "$iface" table "$SHADOW_TABLE" 2>/dev/null || true
        fi
    fi

    # Keep an escape rule of our own: harmless duplicate when tailscaled's
    # 5230 exists, the only thing keeping control alive if it does not.
    ip rule add pref "$MARK_RULE_PREF" fwmark 0x80000/0xff0000 lookup "$SHADOW_TABLE" 2>/dev/null || true
    ip -6 rule add pref "$MARK_RULE_PREF" fwmark 0x80000/0xff0000 lookup "$SHADOW_TABLE" 2>/dev/null || true
}

# tailscaled parks its tailnet routes in its own table (52 by default) and
# reaches them through `5270: from all lookup 52`. netd's per-network rules
# (15040/31000, keyed on the app fwmark) are consulted for anything that falls
# through, so a DNS packet DNAT'd to 100.100.100.100 ends up in the wlan0 table
# and dies with ENETUNREACH. Pin tailnet destinations to tailscaled's table
# ahead of netd's rules instead of relying on rule order.
tailnet_table() {
    local t
    t=$(ip route show table all 2>/dev/null |
        sed -n 's/^100\.100\.100\.100 dev [^ ]* table \([0-9][0-9]*\).*/\1/p' |
        head -1)
    printf '%s' "${t:-52}"
}

install_tailnet_rules() {
    local t
    t=$(tailnet_table)
    ip rule add pref "$TAILNET_RULE_PREF" to 100.100.100.100 lookup "$t" 2>/dev/null || true
    ip rule add pref "$((TAILNET_RULE_PREF + 1))" to 100.64.0.0/10 lookup "$t" 2>/dev/null || true
    ip -6 rule add pref "$TAILNET_RULE_PREF" to fd7a:115c:a1e0::/48 lookup "$t" 2>/dev/null || true
    # Older builds steered these at `main`, where the routes never exist.
    ip rule del pref 9000 2>/dev/null || true
    ip rule del pref 9001 2>/dev/null || true
}

# Event-driven-ish watch without `ip monitor`: monitor's stdout is
# block-buffered when piped (no stdbuf on Android), so piped events never
# arrive in real time. Instead poll a CHEAP signal every 3 s — the full
# route+addr tables (~100 ms, no dumpsys, no daemon calls) — and run the
# full (expensive, dumpsys-based) sync only when it changes, plus a 60 s
# backstop for DNS-only changes that alter no route.
watch_loop() {
    local cur last slow
    last=""
    slow=0
    while :; do
        cur=$(ip route show table all 2>/dev/null; ip -o addr show 2>/dev/null)
        if [ "$cur" != "$last" ]; then
            last="$cur"
            sleep 3 # let the handover burst settle before reading state
            sync_netenv
            slow=0
        else
            slow=$((slow + 1))
            if [ "$slow" -ge 20 ]; then
                slow=0
                sync_netenv # backstop: DNS-only changes alter no route
            else
                sleep 3
            fi
        fi
    done
}

sync_magicdns() {
    # MagicDNS redirect is core behavior (matches the app: tailnet DNS always
    # on while connected). No toggle — the flag file mechanism is gone.
    # Check if tailscaled is running (has a Tailscale IP)
    local ts_ip
    ts_ip=$( (/data/adb/tailscale/bin/tailscale ip -4 2>/dev/null || tailscale ip -4 2>/dev/null) | head -1)
    if [ -z "$ts_ip" ]; then
        # tailscaled not running — remove redirect rules
        iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || true
        iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination 100.100.100.100:53 2>/dev/null || true
        return 0
    fi

    # tailscaled running — add redirect rules (idempotent: check first)
    if ! iptables -t nat -C OUTPUT $DNAT_SPEC_UDP 2>/dev/null; then
        iptables -t nat -A OUTPUT $DNAT_SPEC_UDP 2>/dev/null && \
            log_msg "MagicDNS: redirecting UDP/53 -> 100.100.100.100"
    fi
    if ! iptables -t nat -C OUTPUT $DNAT_SPEC_TCP 2>/dev/null; then
        iptables -t nat -A OUTPUT $DNAT_SPEC_TCP 2>/dev/null && \
            log_msg "MagicDNS: redirecting TCP/53 -> 100.100.100.100"
    fi

}

sync_netenv() {
    local netid iface dns_raw gw gw6 r4 r6 ip sig v4 v6
    v4=""
    v6=""

    dumpsys connectivity >"$DUMP" 2>/dev/null || : >"$DUMP"
    netid=$(active_netid)
    [ -n "$netid" ] || netid=$(sed -n 's/.*NetworkAgentInfo{network{\([0-9][0-9]*\)}.*/\1/p' "$DUMP" | head -1)

    iface=$(net_field "$netid" 's/.*InterfaceName: \([^ ]*\).*/\1/p')
    dns_raw=$(net_field "$netid" 's/.*DnsAddresses: \[ \([^]]*\) \].*/\1/p')

    # Physical default route (also the gateway fallback).
    r4=$(ip route get 1.1.1.1 2>/dev/null | head -1)
    gw=$(printf '%s\n' "$r4" | sed -n 's/.* via \([0-9.]*\).*/\1/p')
    [ -n "$iface" ] || iface=$(printf '%s\n' "$r4" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    r6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -1)
    gw6=$(printf '%s\n' "$r6" | sed -n 's/.* via \([0-9a-fA-F:]*\).*/\1/p')

    # IPv4 first: a stale IPv6 resolver at the head of the list is the classic
    # multi-second stall before control connects. Skip link-local (fe80::) —
    # an address without a scope id is unusable as a resolver.
    SERVERS=""
    for ip in $(printf '%s' "$dns_raw" | tr ',' ' '); do
        ip=${ip#/}
        case "$ip" in
            ""|::1|fe80:*|f[de]80:*) continue ;;
            *:*) v6="${v6:+$v6 }$ip" ;;
            *.*) v4="${v4:+$v4 }$ip" ;;
        esac
    done
    for ip in $v4 $v6; do add_server "$ip"; done
    if [ -z "$SERVERS" ] && [ -n "$gw" ]; then add_server "$gw"; fi
    if [ -z "$SERVERS" ]; then
        add_server 1.1.1.1
        add_server 8.8.8.8
    fi

    # MagicDNS: tailscaled runs an internal DNS proxy on 100.100.100.100 that
    # resolves tailnet hostnames (e.g. stinkdesk.tailnet-name.ts.net). Put it
    # LAST so physical resolvers are tried first (fast, no timeout when the
    # daemon is down) and MagicDNS only kicks in for *.ts.net / tailnet names.
    if [ -S "${TS_SOCKET}" ] 2>/dev/null || pgrep -f tailscaled >/dev/null 2>&1; then
        add_server 100.100.100.100
    fi

    sig="net=${netid:-?} if=${iface:-?} gw=${gw:-?} gw6=${gw6:-?} dns=${SERVERS}"

    sync_route "$iface" "$gw" "$gw6"
    install_tailnet_rules

    if [ "$(cat "$SIG_FILE" 2>/dev/null)" != "$sig" ]; then
        printf '%s\n' "$sig" >"$SIG_FILE"
        log_msg "net=${netid:-?} if=${iface:-?} gw=${gw:-none} gw6=${gw6:-none}"
    fi

    # Always compare content: tailscaled's Linux DNS manager (accept-dns=on)
    # rewrites resolv.conf to point at 100.100.100.100, which the daemon's own
    # marked queries cannot reach on Android. Self-heal on every pass.
    sync_dns "$netid" "$SERVERS"

    # MagicDNS: redirect all DNS queries to tailscaled's proxy at 100.100.100.100
    # so Android apps can resolve *.ts.net names. Uses iptables DNAT in OUTPUT
    # (locally-generated traffic) and PREROUTING (forwarded traffic). Only active
    # when tailscaled is running; removed when it stops.
    sync_magicdns

    # bindhosts-style /etc/hosts: bionic reads it before netd DNS, so plain
    # hostnames resolve for ping/ssh/curl even on the IPv6-DNS path.
    sync_hosts
}

case "$1" in
    route)
        r4=$(ip route get 1.1.1.1 2>/dev/null | head -1)
        gw=$(printf '%s\n' "$r4" | sed -n 's/.* via \([0-9.]*\).*/\1/p')
        iface=$(printf '%s\n' "$r4" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
        r6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -1)
        gw6=$(printf '%s\n' "$r6" | sed -n 's/.* via \([0-9a-fA-F:]*\).*/\1/p')
        sync_route "$iface" "$gw" "$gw6"
        install_tailnet_rules
        ;;
    watch)
        watch_loop
        ;;
    *)
        sync_netenv
        ;;
esac
