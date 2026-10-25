# Plan: Full Tailscale on Android via Root — Systemless DNS, MagicDNS, and All Features

## Goal

Make every Tailscale feature (MagicDNS, exit nodes, subnet routing, Tailscale SSH, Taildrop) work on a rooted Android device by replacing the current fragile `/system` remount approach with a systemless overlay, and researching whether Zygisk or other kernel-level hooks can provide true OS-level DNS integration.

## Current context / assumptions

- Repo: `Wild_Tailscale` (fork of anasfanani/Magisk-Tailscaled), branch `main`, HEAD `571da9d` (v2.8.12.0).
- Module runs `tailscaled` as GOOS=linux static binary in TUN mode (real `tailscale0` interface, not userspace).
- Current DNS fix: `netenv.sh` remounts `/system` rw to write `/system/etc/resolv.conf` and uses iptables DNAT to redirect port 53 to 100.100.100.100 (MagicDNS).
- Problem: `/system` remount is fragile (may fail on some ROMs), iptables DNAT redirects ALL DNS (breaks if daemon is down), and `set -e` killed service startup.
- The original anasfanani module explicitly documents "MagicDNS currently not working" and runs in userspace mode.
- Device: Pixel 8 (ZUMA/SHIBA), Android 14/17, KernelSU or Magisk root, Tailscale 1.104.2.
- WebUI v2.8.12.0 shipped with clean 2-page design; not relevant to this plan.

## Architecture / proposed approach

Replace the fragile `/system` remount with a systemless overlay (Magisk/KernelSU `system/` directory) so `/etc/resolv.conf` is provided without touching `/system` at runtime. Add a DNS proxy daemon (dnsmasq or a minimal Go binary) that listens on localhost:53 and forwards `*.ts.net` to 100.100.100.100 while forwarding everything else to the physical resolver, eliminating the iptables DNAT risk. Research Zygisk-based DNS hooking as a deeper integration path for Android 14+ where netd is the sole DNS authority.

## Step-by-step tasks

### Task 1: Create systemless overlay for resolv.conf (no /system remount)

**Files:** `system/etc/resolv.conf` (already exists), `tailscale/scripts/netenv.sh`

1. Verify `system/etc/resolv.conf` exists in repo (created in v2.8.6.0). It should contain:
   ```
   nameserver 8.8.8.8
   nameserver 8.8.4.4
   ```
   This is overlaid by KernelSU/Magisk onto `/system/etc/resolv.conf` at boot — no remount needed.

2. In `netenv.sh`, remove the `mount -o remount,rw /system` call from `write_resolv()`. Instead, write to the overlaid path directly (it will be writable because the overlay is a bind-mount from module storage).

3. In `write_resolv()`, change the target from `/system/etc/resolv.conf` to `/etc/resolv.conf` (which is a symlink to `/system/etc/resolv.conf` on most Android). If the overlay makes it writable, the `cat >` will succeed without remount.

4. Keep the bind-mount fallback for devices where the overlay isn't active.

**Verification:**
```sh
# On device after flashing:
su -c "cat /system/etc/resolv.conf"
# Expected: nameserver lines (not empty, not [::1] fallback)
```

### Task 2: Replace iptables DNAT with a local DNS proxy

**Files:** new `tailscale/scripts/dnsproxy.sh` or Go binary, `tailscale/scripts/netenv.sh`

The iptables DNAT approach has a critical flaw: if tailscaled is down, 100.100.100.100 is unreachable and ALL DNS fails. Replace with a local DNS proxy.

Option A (shell-based, using `socat` or `nc`):
- Listen on `127.0.0.1:53` (UDP+TCP)
- Parse DNS query, check if domain ends in `.ts.net`
- If yes: forward to 100.100.100.100:53
- If no: forward to the physical resolver (from netenv.sh)
- Return response to client

Option B (Go binary, compiled alongside tailscaled):
- A minimal DNS forwarder in Go using `github.com/miekg/dns`
- Compiled as part of the existing CI build pipeline
- Runs as a daemon alongside tailscaled

**Recommended: Option A first (shell), then Option B if performance is an issue.**

For Option A, create `tailscale/scripts/dnsproxy.sh`:
```sh
#!/system/bin/sh
# Minimal DNS proxy: forwards *.ts.net to 100.100.100.100,
# everything else to the physical resolver.
# Uses socat if available, else nc.
```

In `netenv.sh`:
- Start the DNS proxy when tailscaled is running
- Stop it when tailscaled stops
- Remove iptables DNAT rules (no longer needed)
- Keep `/etc/resolv.conf` pointing to 127.0.0.1

**Verification:**
```sh
# On device:
su -c "nslookup stinkdesk.your-tailnet.ts.net 127.0.0.1"
# Expected: returns 100.x.x.x Tailscale IP
su -c "nslookup google.com 127.0.0.1"
# Expected: returns public IP
```

### Task 3: Research Zygisk-based DNS hooking

**Files:** new research document `docs/zygisk-dns-research.md`

Research whether a Zygisk module can hook Android's `DnsResolver` or `netd` to inject 100.100.100.100 as a resolver at the OS level. This would be the "proper" Android integration.

Key research areas:
1. How Android 14+ netd handles DNS (DnsResolver AIDL interface)
2. Whether Zygisk can hook `libnetd_client.so` or `libbinder.so` to intercept DNS queries
3. Existing projects that do DNS redirection via Zygisk (e.g., `bindhosts`, `ZN DNS Changer`)
4. Whether KernelSU's `ksu` module system supports Zygisk-style hooks

**Deliverable:** A markdown document with findings, feasibility assessment, and recommended approach.

### Task 4: Research systemless partition replacement (KernelSU `system` overlay)

**Files:** new research document `docs/systemless-overlay-research.md`

The current approach writes to `/system/etc/resolv.conf` (requires rw remount). KernelSU and Magisk both support systemless overlays via the `system/` directory in the module. Research:

1. How KernelSU's `system` overlay works (mount namespace, bind mounts)
2. Whether `/etc/resolv.conf` (symlink to `/system/etc/resolv.conf`) is properly overlaid
3. Whether the overlay survives reboots and ROM updates
4. Whether there are any SELinux contexts that need to be set

**Deliverable:** A markdown document with findings and implementation notes.

### Task 5: Research exit node and subnet routing on Android

**Files:** new research document `docs/routing-research.md`

Exit nodes and subnet routing require iptables rules that redirect traffic through the TUN interface. Research:

1. How tailscaled sets up iptables rules on Linux (check `wgengine/router_linux.go`)
2. Whether Android's iptables/nftables supports the required rules
3. Whether the `ts_rules_up()` function in tailscaled.service is sufficient
4. Known issues with Android's policy routing and multiple routing tables

**Deliverable:** A markdown document with findings and recommended iptables rules.

### Task 6: Update WebUI to show DNS/routing status

**Files:** `webroot/assets/app.js`, `webroot/index.html`

Add a "Network" card to the WebUI showing:
- DNS resolver status (physical + MagicDNS)
- Routing table status (shadow route in table 253)
- iptables DNAT rules (active/inactive)
- Tailscale IP and peer count

This gives the user visibility into whether the networking fixes are working.

## Tests / validation

### For Task 1 (systemless overlay):
```sh
# Flash module, reboot, then:
su -c "cat /system/etc/resolv.conf"
# Expected: nameserver lines present
su -c "mount | grep resolv.conf"
# Expected: bind mount or overlay entry
```

### For Task 2 (DNS proxy):
```sh
# Start proxy, then:
su -c "nslookup stinkdesk.your-tailnet.ts.net 127.0.0.1"
# Expected: 100.x.x.x
su -c "nslookup google.com 127.0.0.1"
# Expected: public IP
# Kill tailscaled, verify DNS still works (proxy should fall back to physical resolver)
```

### For Task 3-5 (research):
- Documents must include: findings, feasibility, recommended approach, code snippets if applicable
- Each document must reference at least 3 external sources

### For Task 6 (WebUI):
```sh
node --check webroot/assets/app.js
# Expected: no syntax errors
# Manual: open WebUI, verify Network card renders with status
```

## Task 7: ADB-based integration testing harness

**Files:** new `tests/adb-test.sh`, `.github/tools/adb-test.sh`

Create a reusable ADB test script that runs on the host and exercises the module on a connected device. Uses wireless ADB (192.168.1.53:5555).

### Test cases:

1. **Module installed check:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'cat /data/adb/modules/magisk-tailscaled/module.prop | grep version'"
# Expected: version=v2.8.x.x
```

2. **Binary presence:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'ls /data/adb/tailscale/bin/tailscaled /data/adb/tailscale/bin/tailscale /data/adb/tailscale/bin/tailscale.bin /data/adb/tailscale/bin/jq /data/adb/tailscale/scripts/getent /data/adb/tailscale/scripts/netenv.sh'"
# Expected: all files exist
```

3. **Service start:**
```sh
adb -s 192.168.1.53:5555 shell "su -c '/data/adb/tailscale/scripts/tailscaled.service start'"
sleep 5
adb -s 192.168.1.53:5555 shell "su -c 'cat /data/adb/tailscale/run/tailscaled.log | tail -5'"
# Expected: "Engine created" or "got LocalBackend"
```

4. **DNS resolution:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'cat /system/etc/resolv.conf'"
# Expected: nameserver lines present
adb -s 192.168.1.53:5555 shell "su -c 'nslookup google.com 2>&1 | head -5'"
# Expected: IP address returned
```

5. **Routing table:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'ip rule show | grep 9000'"
# Expected: 9000: from all to 100.64.0.0/10 lookup main
adb -s 192.168.1.53:5555 shell "su -c 'ip route show table 253'"
# Expected: default via <gw> dev <iface>
```

6. **Tailscale status:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'tailscale status 2>&1 | head -10'"
# Expected: shows node info or "Logged out" (not "connection refused")
```

7. **iptables DNAT rules:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'iptables -t nat -L OUTPUT -n 2>&1 | grep 100.100.100.100'"
# Expected: DNAT rule present (only when tailscaled running)
```

8. **WebUI files present:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'ls /data/adb/modules/magisk-tailscaled/webroot/index.html /data/adb/modules/magisk-tailscaled/webroot/assets/app.js /data/adb/modules/magisk-tailscaled/webroot/config.json'"
# Expected: all files present
```

## Task 8: Comprehensive code scan — features, toggles, and settings audit

**Files:** all shell scripts, settings.sh, WebUI JS

Scan every feature flag, toggle, setting, and code path to ensure they are consistent and working. This is a read-only audit producing a checklist.

### 8.1: settings.sh audit

Check these variables are defined and used consistently:
- `TS_TUN` — default "tailscale0", used in TS_DAEMON_CMD and ts_rules_up
- `TS_DAEMON_CMD` — includes --tun, --statedir, --socket, --port, --accept-dns=false, -no-logs-no-support
- `TS_SOCKET` — used by CLI wrapper and daemon
- `TS_MOD_DIR` — hardcoded path, used for module.prop and system/bin
- `TS_DIR` — /data/adb/tailscale, used everywhere
- `TS_RUN_DIR` — ${TS_DIR}/run, created at source time
- `TS_LOG_FILE` — ${TS_RUN_DIR}/tailscaled.log
- `TS_RUN_LOG_FILE` — ${TS_RUN_DIR}/runs.log

Verify: every variable referenced in any script is defined in settings.sh. No undefined variable usage.

### 8.2: Feature toggle audit

| Toggle | Location | Default | Used In | Verified |
|--------|----------|---------|---------|----------|
| TS_TUN | settings.sh | tailscale0 | TS_DAEMON_CMD, ts_rules_up | ⬜ |
| --accept-dns | TS_DAEMON_CMD | false | daemon startup | ⬜ |
| Exit node allow LAN | WebUI switch | false | tailscale set | ⬜ |
| Advertise exit node | WebUI switch | false | tailscale set --advertise-exit-node | ⬜ |
| Accept routes | WebUI switch | false | tailscale set --accept-routes | ⬜ |
| MagicDNS iptables | netenv.sh | auto | sync_magicdns() | ⬜ |
| Adaptive polling | app.js | 4s/15s | poll() | ⬜ |
| Auto-update check | app.js | manual | checkUpdate() | ⬜ |

### 8.3: Shell script scan

For each .sh file, verify:
- `set -e` doesn't cause silent exits (all fallible commands have `|| true`)
- All sourced files exist at runtime
- No hardcoded paths that differ from settings.sh
- All `log` calls use valid log levels (Info, Success, Error, Warning, Debug)
- No unquoted variables that could break on spaces

Files to scan:
- `settings.sh`
- `service.sh`
- `start.sh`
- `boot-completed.sh`
- `customize.sh`
- `uninstall.sh`
- `action.sh`
- `tailscale/scripts/tailscaled.service`
- `tailscale/scripts/tailscaled.inotify`
- `tailscale/scripts/netenv.sh`
- `tailscale/scripts/getent`

### 8.4: WebUI scan

For `webroot/assets/app.js` (442 lines):
- All state properties initialized in `state` object
- All DOM references match `index.html` element IDs
- All `ksu.exec` calls have `setTimeout(..., 0)` yield
- No synchronous `ksu.exec` calls (UI thread blocking)
- All fetch calls have error handling
- All switch toggles call `poll()` after setting
- No `display:none` on `#page` (blank screen prevention)

For `webroot/index.html`:
- All element IDs referenced in app.js exist
- No duplicate IDs
- Material components loaded correctly
- CSP headers in config.json match script requirements

### 8.5: CI/CD scan

For `.github/tools/build.sh` and `.github/tools/build-tailscale-android.sh`:
- All required files included in zip (scripts/, system/, webroot/, config.json)
- Binary extraction and renaming correct (tailscaled-arm, tailscale.bin-arm, tailscale-arm)
- `zip -y` flag present (symlink preservation)
- `tailscale/bin/*` excluded from no-binaries zip but included in full zip
- Version bump consistency (module.prop, update.json, update-arm.json, update-arm64.json)

### 8.6: ADB smoke test script

Create `tests/adb-smoke.sh` that runs all checks from Task 7 and exits 0 on success, 1 on failure. Run it after every flash to verify the module works end-to-end.


## Task 9: Daemon auto-recovery and health monitoring

**Files:** `tailscale/scripts/tailscaled.inotify`, `tailscale/scripts/start.sh`, new `tailscale/scripts/healthcheck.sh`

The daemon can crash or get killed by Android's OOM killer. Add auto-recovery.

1. Create `tailscale/scripts/healthcheck.sh`:
```sh
#!/system/bin/sh
# Runs every 60s via inotifyd or cron. Checks if tailscaled is alive.
# If dead, restarts it and re-runs netenv.sh.
. /data/adb/tailscale/settings.sh
if ! busybox pgrep -f "tailscaled" >/dev/null 2>&1; then
    log Warning "tailscaled died — restarting"
    /data/adb/tailscale/scripts/netenv.sh
    /data/adb/tailscale/scripts/tailscaled.service start
fi
```

2. Register in `start.sh` alongside `start_inotifyd` and `start_netenv_watch`.

3. Add a WebUI health indicator (green/red dot) showing daemon status.

**Verification:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'kill -9 \$(pgrep tailscaled); sleep 5; pgrep tailscaled'"
# Expected: new PID (daemon restarted)
```

## Task 10: Log rotation and storage management

**Files:** `tailscale/scripts/tailscaled.service`, new `tailscale/scripts/logrotate.sh`

Daemon logs can grow unbounded on Android's limited storage. Add rotation.

1. In `tailscaled.service`, before starting, rotate logs:
```sh
# Keep last 5 logs, max 10MB each
[ -f "${TS_LOG_FILE}" ] && [ "$(stat -c%s ${TS_LOG_FILE} 2>/dev/null || echo 0)" -gt 10485760 ] &&     mv "${TS_LOG_FILE}" "${TS_LOG_FILE}.$(date +%s).bak"
```

2. Clean up old .bak files older than 7 days:
```sh
find "${TS_RUN_DIR}" -name "*.bak" -mtime +7 -delete 2>/dev/null
```

3. Add to `customize.sh` and `uninstall.sh` cleanup.

**Verification:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'ls -la /data/adb/tailscale/run/*.bak 2>&1'"
# Expected: old logs cleaned up
```

## Task 11: State backup and restore

**Files:** new `tailscale/scripts/backup.sh`, `tailscale/scripts/restore.sh`

Tailscale state (node key, auth) lives in `${TS_DIR}`. Back up before updates/uninstalls.

1. `backup.sh`: tar up `${TS_DIR}` excluding binaries and logs, save to `/sdcard/tailscale-backup-$(date +%s).tar.gz`
2. `restore.sh`: extract backup back to `${TS_DIR}`
3. Call `backup.sh` from `customize.sh` before overwriting state
4. Add WebUI "Backup" and "Restore" buttons on Settings page

**Verification:**
```sh
adb -s 192.168.1.53:5555 shell "su -c '/data/adb/tailscale/scripts/backup.sh && ls /sdcard/tailscale-backup-*.tar.gz'"
# Expected: backup file created
```

## Task 12: Security audit

**Files:** all scripts, settings.sh, WebUI

Audit for security issues:
1. Socket permissions: `${TS_SOCKET}` should be 0600 (only root)
2. State dir permissions: `${TS_DIR}` should be 0700
3. No credentials in logs (check for auth tokens, node keys in log output)
4. WebUI CSP: verify `config.json` CSP doesn't allow unsafe-eval
5. iptables rules: verify only port 53 is redirected, not all traffic
6. `getent` mock: verify it doesn't leak user info beyond uid 0

**Verification:**
```sh
adb -s 192.168.1.53:5555 shell "su -c 'stat -c %a /data/adb/tailscale/run/tailscaled.sock /data/adb/tailscale'"
# Expected: 600 and 700
adb -s 192.168.1.53:5555 shell "su -c 'grep -i "auth\|token\|nodekey" /data/adb/tailscale/run/tailscaled.log | head -5'"
# Expected: no sensitive data in logs
```

## Task 13: Multi-device / multi-ROM testing matrix

**Files:** new `docs/testing-matrix.md`

Document testing across:
- Android versions: 12, 13, 14, 15, 16, 17
- Root methods: Magisk, KernelSU, KernelSU Next, APatch
- Architectures: arm, arm64
- Network types: WiFi, cellular, VPN active
- Scenarios: boot, network switch, sleep/wake, daemon restart

Each cell: pass/fail/unknown with notes.

## Task 14: Documentation update

**Files:** `README.md`, `CHANGELOG.md`

Update README with:
- Full feature list with status (working / partial / not working)
- MagicDNS setup instructions (iptables + resolv.conf)
- Exit node and subnet routing instructions
- Troubleshooting section (common errors + fixes)
- WebUI usage guide
- ADB testing commands


## Task 15: Android netd DNS integration (app parity)

**STATUS: NOT FEASIBLE on Android 14+** — `ndc resolver` commands are crippled/removed. The DNS resolver module uses a new internal API not accessible via shell. Our iptables DNAT approach is the best available alternative for root modules.

**Alternative approaches to research:**
1. `cmd connectivity` — newer command, may have DNS subcommands
2. `settings put global` — can set private DNS mode
3. Kernel-level DNS interception via eBPF (Android 14+ supports eBPF)
4. Keep iptables DNAT (current, working approach)

**Current approach is sufficient:** iptables DNAT redirects all port 53 traffic to 100.100.100.100, which handles both MagicDNS (*.ts.net) and upstream resolution (tailscaled forwards non-tailnet queries). This works for all Android apps.

## Task 16: Exit node full tunnel support

**Files:** `tailscale/scripts/netenv.sh`, `tailscale/scripts/start.sh`

Ensure exit nodes route ALL traffic (not just tailnet) through tailscale0.

1. When exit node is active, add default route via tailscale0 (higher priority than physical).
2. Use Android's policy routing to steer all traffic to tailscale0.
3. Handle network changes (WiFi↔cellular) without breaking exit node.
4. Test with `tailscale set --exit-node=<node>`.

**Verification:**
```sh
# On device with exit node active:
su -c "curl -s https://ipinfo.io/ip"
# Expected: exit node's public IP
```

## Task 17: Subnet routing support

**Files:** `tailscale/scripts/netenv.sh`, `tailscale/scripts/start.sh`

Enable subnet routing (advertise local subnets via Tailscale).

1. Enable IP forwarding: `sysctl -w net.ipv4.ip_forward=1`
2. Add iptables FORWARD rules for tailscale0 ↔ LAN interface.
3. Handle SELinux blocking on some ROMs.
4. Test with `tailscale set --advertise-routes=192.168.1.0/24`.

**Verification:**
```sh
# From another tailnet device:
ping 192.168.1.1  # should reach the Android device's LAN gateway
```

## Task 18: IPv6 MagicDNS

**Files:** `tailscale/scripts/magicdns.sh`

Add IPv6 DNAT for MagicDNS (currently only IPv4).

1. Check if ip6tables nat table is available.
2. If yes, add IPv6 DNAT rules for port 53 → fd7a:115c:a1e0::53 (MagicDNS IPv6).
3. If no, document limitation.

## Task 19: Instant network change detection

**Files:** `tailscale/scripts/netenv.sh`

Replace 15s polling with instant network change detection.

1. Use `dumpsys connectivity` with inotify on `/data/system/netstats/` or similar.
2. Or use `logcat -b events` to watch for connectivity changes.
3. Fall back to 15s polling if instant detection isn't available.

**Verification:**
```sh
# Switch WiFi→cellular, verify DNS/routing updates within 2s
```

1. **iptables availability** — Android 14+ may use nftables instead of iptables. Need to detect and handle both. The `iptables` command might be a wrapper around nftables on newer Android.

2. **DNS proxy performance** — A shell-based DNS proxy using `socat`/`nc` may be too slow for high-volume DNS. A Go binary is better but adds build complexity.

3. **Zygisk research may reveal it's not feasible** — Zygisk hooks run in app processes, not system processes. Hooking netd (a system daemon) may require a different approach (e.g., Magisk's `resetprop` or a kernel module).

4. **Systemless overlay may not work on all ROMs** — Some ROMs don't support Magisk/KernelSU overlays for `/system/etc/`. The bind-mount fallback should handle this.

5. **MagicDNS via iptables DNAT vs DNS proxy** — The DNAT approach is simpler but riskier (breaks all DNS if daemon is down). The DNS proxy is safer but more complex. Recommend implementing both (proxy primary, DNAT fallback).

## Task 20: App-parity WebUI (shipped in v2.9.0.0)

Matched the official Android app's settings surface in the module WebUI:

- **Exit node picker** (Home card): lists tailnet exit nodes from `status --json`, tap to `tailscale set --exit-node=<ip>` or None to clear. Choice persisted in `/data/adb/tailscale/exitnode` and re-applied on `tailscale up` at connect/boot (prefs only carry ExitNodeID, not usable by `up`).
- **Use Tailscale DNS** toggle: `tailscale set --accept-dns` (CorpDNS). Default ON at connect (app parity: the app always uses tailnet DNS). The read-only `/etc/resolv.conf` warning is cosmetic — daemon keeps running.
- **MagicDNS redirect** toggle: iptables DNAT via `magicdns.sh` + flag file (unchanged).
- **Subnet routes** card: view advertised routes, set/clear via dialog (`tailscale set --advertise-routes=`).
- **Shields up / SSH** toggles: `tailscale set --shields-up`, `--ssh`; persisted across reconnects in `doConnect`.
- **Taildrop** card: `tailscale file get /sdcard/Taildrop` with 110s wait.
- **netenv.sh**: enables `net.ipv4.ip_forward` + v6 forwarding (needed when advertising subnets / running as exit node).

Verified without device: `node --check`, `bash -n`, headless Chromium over HTTP with `?mock=1` + virtual-time budget — status Connected, 2 peer rows, 2 exit rows, no console errors.

## Task 21 (TODO): Per-app split tunneling via iptables owner match

The app's split-tunneling (include/exclude apps) maps to `iptables -m owner --uid-owner <uid>` rules on a root module. Needs: package→UID mapping (`pm list packages -U`), WebUI multi-select, rules that survive netenv sync. Not started.

## Task 22 (TODO): Tailnet Lock UI

`tailscale lock` CLI exists. Needs key setup/status WebUI. Not started.

## Task 23 (TODO): Serve/Funnel status

`tailscale serve status` output in Doctor or a dedicated card. Not started.

## Open questions (kept)

6. Should we explore using `bindhosts` (which already solves the `/etc/hosts` problem on Android) as a reference for systemless file replacement?
7. The user mentioned "systemless replacement" and "replace system partition" — module uses the safe Magisk/KernelSU overlay, never touches the real system partition.