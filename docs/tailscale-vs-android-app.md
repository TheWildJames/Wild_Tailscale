# How Tailscale Android App Works vs Root Module

## Tailscale Android App Architecture

The official Tailscale Android app (`com.tailscale.ipn`) uses Android's `VpnService` API:

### DNS Management
- Sets DNS to `100.100.100.100` via `VpnService.Builder.setDnsServers()`
- Android's netd handles DNS routing to all apps
- `DnsConfig` class tracks upstream resolvers from DHCP
- `OnDNSConfigChanged` callback notifies Go backend of DNS changes
- Go backend handles split DNS: tailnet names → 100.100.100.100, everything else → upstream
- No `/etc/resolv.conf` needed — netd is the DNS authority

### Routing
- Uses `VpnService.Builder.addRoute()` for tailnet routes (100.64.0.0/10, fd7a:115c:a1e0::/48)
- Android's VPN routing handles policy routing automatically
- Exclude mode (API 33+): adds all routes, excludes local routes
- Include mode (older): computes minimal CIDR set

### TUN Interface
- `VpnService.Builder.establish()` creates TUN
- File descriptor passed to Go backend
- `multiTUN` allows seamless transitions

### Key Advantage
- Android's VPN framework handles ALL routing/DNS at the OS level
- Every app automatically uses tailnet DNS and routing
- No iptables hacks needed

## Root Module (magisk-tailscaled) Architecture

Our module runs tailscaled as a native Linux binary:

### DNS Management
- No VpnService → no netd DNS integration
- Go binary reads `/etc/resolv.conf` (Linux convention)
- Android has no `/etc/resolv.conf` by default
- We mirror Android's resolvers into resolv.conf (netenv.sh)
- MagicDNS via iptables DNAT to 100.100.100.100
- `--accept-dns=false` to prevent tailscaled writing ro /system/etc

### Routing
- tailscaled creates `tailscale0` TUN interface
- Policy routing rules (5210→main, 5230→table 253, 5250→unreachable)
- Android keeps defaults in per-network tables → we copy to table 253
- iptables rules for 100.64.0.0/10 → main table (priority 9000)

### TUN Interface
- tailscaled creates TUN directly via `/dev/net/tun`
- Works in TUN mode (not userspace networking)

## Gap Analysis: What's Missing for App Parity

### 1. DNS for Android Apps
- **App**: netd handles DNS for all apps via VpnService
- **Module**: Only Linux binaries read resolv.conf; Android apps use netd
- **Our fix**: iptables DNAT redirects port 53 → 100.100.100.100
- **Status**: Working for most cases, but IPv6 DNS may bypass
- **Better approach**: Use `ndc resolver setnetdns` to set DNS via netd

### 2. Routing for Android Apps
- **App**: Android VPN routing handles all traffic
- **Module**: Policy routing rules + iptables
- **Our fix**: TAILNET_RULE_PREF=9002 for 100.64.0.0/10, shadow default in table 253
- **Status**: Partially working; exit nodes may not route all traffic
- **Better approach**: Use `ip rule` with higher priority, or Android's `cmd connectivity`

### 3. Exit Nodes
- **App**: Sets default route through VPN TUN
- **Module**: Needs to override per-network default routes
- **Status**: Not fully tested
- **Challenge**: Android's netd may override our rules on network change

### 4. Subnet Routing
- **App**: Routes subnet traffic through VPN
- **Module**: Needs IP forwarding + FORWARD rules
- **Status**: Not implemented
- **Challenge**: Android may block IP forwarding

### 5. MagicDNS
- **App**: netd resolves *.ts.net via 100.100.100.100
- **Module**: iptables DNAT redirects all DNS to 100.100.100.100
- **Status**: Working for IPv4, IPv6 may bypass
- **Better approach**: Use netd DNS configuration

## Recommended Improvements for Full App Parity

### A. Use `ndc` / `cmd connectivity` for DNS (like the app)
**STATUS: NOT FEASIBLE on Android 14+** — `ndc resolver` commands are crippled/removed in Android 14+. The DNS resolver module uses a new internal API that isn't accessible via shell commands. Our iptables DNAT approach is the best available alternative.

### B. Use Android's VPN routing instead of manual ip rules
**STATUS: NOT FEASIBLE without app** — VPN routing requires VpnService which needs an app with system privileges. Our manual policy routing is the correct approach for root modules.

### C. Handle network changes via NetworkCallback
**STATUS: PARTIALLY FEASIBLE** — Could use `dumpsys connectivity` polling (current) or `logcat -b events` monitoring. Instant detection not available without an app.

### D. IP forwarding for subnet routing
**STATUS: FEASIBLE** — `sysctl -w net.ipv4.ip_forward=1` works on most ROMs. Need to add FORWARD rules.

## Current Working Features
- ✅ Daemon starts and connects
- ✅ TUN interface created
- ✅ Tailnet IP assigned
- ✅ Peer connectivity (ping, etc.)
- ✅ MagicDNS for apps (via DNAT)
- ✅ Exit nodes (partially)
- ✅ Boot auto-start
- ✅ Health monitoring
- ✅ WebUI management

## Not Yet Working / Needs Improvement
- ❌ DNS for Android apps via netd (using DNAT workaround)
- ❌ Exit node full tunnel (may not route all traffic)
- ❌ Subnet routing (not tested)
- ❌ IPv6 MagicDNS (no ip6tables nat)
- ❌ Network change responsiveness (15s polling vs instant callback)

## Sources
1. Tailscale Android network config: https://deepwiki.com/tailscale/tailscale-android/4.2-network-configuration
2. Tailscale DNS docs: https://tailscale.com/docs/reference/dns-in-tailscale
3. Android VpnService: https://developer.android.com/reference/android/net/VpnService
4. Android netd: https://source.android.com/docs/core/connectivity
5. ndc command: https://android.googlesource.com/platform/system/netd/
