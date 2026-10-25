## v2.9.0.0

- 185d1ad docs: Tailscale app vs root module comparison, update plan

## v2.8.7.0

- **Android networking fix (netenv.sh)** — The real root cause of "network unreachable" on Android: netd keeps all default routes in per-network tables and never puts one in the stock tables. tailscaled's fwmark-escape rules (5210→main, 5230→default/table 253, 5250→unreachable) therefore find nothing and every daemon dial fails. `netenv.sh` mirrors Android's active-network DNS resolvers into /etc/resolv.conf (Go can't call netd's DnsResolver Binder API) and copies the physical default route into table 253, then installs a belt-and-braces rule. Runs at service start and every 15s to follow WiFi↔cellular switches. No more hardcoded 8.8.8.8.
- **settings.sh sourced from /data/adb/tailscale fallback** — scripts now find settings.sh whether run from the module dir or the installed data dir.
- **Official Tailscale app conflict warning** — logs a clear warning if com.tailscale.ipn holds the VPN, since two TUNs can't coexist.
- **zip -y flag** — preserves symlinks in the module zip (KernelSU overlay correctness).

## v2.8.6.0

- **DNS resolution fix** — Android has no `/etc/resolv.conf`, so Go's DNS resolver falls back to `[::1]:53` where nothing listens. tailscaled couldn't resolve `controlplane.tailscale.com` and every connection failed. Now: module overlay ships `system/etc/resolv.conf` (KernelSU/Magisk overlays it onto `/etc/`), `start.sh` bind-mounts it at runtime as a fallback, and `customize.sh` creates it during install.
- **getent mock** — added `tailscale/bin/getent` so the daemon can resolve user info for Tailscale SSH (was throwing `exec: "getent": executable file not found`).

## v2.8.5.0

- **Wait for network before daemon start** — service.sh and boot-completed.sh now wait up to 120s for a default route (WiFi/cellular) before starting tailscaled. Previously the daemon started before the interface was up and cached "network unreachable", so every connection to controlplane.tailscale.com failed until manually restarted.
- **System-wide VPN: real TUN mode** — the module now ships GOOS=linux static tailscaled binaries and runs `--tun=tailscale0`. The previous GOOS=android builds hard-exclude the Linux router (`creating router: unsupported OS android`), so the daemon could only run userspace networking — it connected, but apps on the phone had no route into the tailnet and the official Tailscale app was needed instead. Now apps reach tailnet IPs directly through `tailscale0`. The service also installs Android policy-routing rules (priority 9000, `100.64.0.0/10` + `fd7a:115c:a1e0::/48` → main table) because Android's per-network rules otherwise shadow the main-table route for app sockets; rules are removed on stop. If TUN mode fails to start, the service automatically falls back to userspace-networking (force it any time with `TS_TUN=userspace-networking` in `tailscale/settings.sh`).
- **WebUI toggles stay put** — the Material switches are natively interactive: tapping one only flipped the local UI (the row handler deliberately ignored it), so no `tailscale set` ran and the next poll snapped the switch back. `change` handlers now apply the pref for real — Accept DNS / Accept routes / Advertise exit node / LAN access / Start on boot all stick.
- **KernelSU boot-script structure** (per the KernelSU module guide) — daemon start moved to `boot-completed.sh` on KernelSU; `service.sh` keeps the Magisk-compatible wait-for-boot path and defers to `boot-completed.sh` when `$KSU` is set. No `post-fs-data.sh` — nothing in this module needs early-boot mounting (scripts and binaries live in `/data/adb/tailscale`, not a system overlay).
- **Build pipeline** — `build-tailscale-android.sh` now produces static `GOOS=linux CGO_ENABLED=0` binaries (arm + arm64); the Android NDK step is removed from the release workflow and the android-only Taildrop nil-guard patch is no longer applied (bug is android-GOOS-specific).
- **Version sync** — module.prop, update.json, update-arm.json, update-arm64.json all at v2.8.5.0.

## v2.8.4.0

- **Settings persist across reboots** — `doConnect` now reads stored prefs and passes them as explicit flags to `tailscale up` instead of running bare `tailscale up` (which resets to defaults). Your Accept DNS / Accept routes / Advertise exit node / LAN access settings survive a reboot.

## v2.8.3.0

- **Repo renamed to Wild_Tailscale** — all references updated (module.prop, update.json, app.js, README, build.sh, workflow, customize.sh). The GitHub repo rename is done separately in repo settings.
- **Header cleaned** — title is "Tailscale", version display removed from top bar, moved to the device info card.
- **Copy-IP buttons** — each device in the tailnet list gets a ⧉ button to copy its Tailscale IP.
- **Status card not clickable** — only the Connect/Disconnect/Log in button below is tappable.
- **Clock emoji status** — module.prop description uses `[ ⏲ HH:MM | ⚡ VPN connected ]` format.
- **Author cleaned** — module.prop author is just TheWildJames.
- **README updated** — matches current features (WebUI, doctor, status, rename, Wild_Tailscale).
- **Code review** — checked for errors, leaks, XSS (esc() used in all innerHTML), null guards (20 && patterns), dead refs (none), unused CSS (cleaned .header-version).

## v2.8.2.0

- **Module description = status only** — no more marketing text. The manager's module list shows just the live VPN status: ⚡ VPN connected / ⚠ Login required / ⛔ VPN stopped. Updates in real time via the WebUI poll.
- **Doctor button** — Settings → About → Doctor. Runs `tailscale status`, `tailscale netcheck`, `tailscale version`, and a daemon liveness check, all in one output. Shows results in the log viewer with copy/share.

## v2.8.1.0

- **Module renamed to "Tailscale"** — display name no longer says "Magisk Tailscaled"; tagline removed. Description: "Full Tailscale VPN client for rooted Android."
- **Log viewer: Copy & Share buttons** — copy daemon logs to clipboard or share via Android share intent.
- **Update check fixed** — shows current version, compares against latest release, only opens browser when a newer version exists or when the network fetch fails.
- **Settings switch sizing** — md-switch components given explicit track/handle dimensions for consistent appearance.
- **No "Magisk" text in the UI** — only filesystem paths (`/data/adb/magisk`) and the GitHub repo URL retain it, which are backend-only.

## v2.8.0.0 — Clean rebuild

- **Complete WebUI rewrite** — rebuilt from scratch modeled on the official Tailscale Android app. Two pages (Home / Settings), single state object, no more monolithic 941-line JS with 25 globals.
- **Home**: status dot (green/red/orange), status text, one big action button (Connect / Disconnect / Log in), connection info card (IPv4, IPv6, exit node, hostname), device list with online/offline dots.
- **Settings**: boot toggle, Accept DNS, Accept routes, Advertise exit node, Allow LAN access, restart/logout, logs, update check, GitHub link — all in clean cards with proper switches.
- **Cleaner visuals**: minimal Material 3 tokens, card-based layout, no more 839-line CSS with 12 unused classes.
- **Faster**: single poll reads everything in one exec (status + prefs + boot flag + version), adaptive 4s/15s polling.
- **Simpler update check**: uses `fetch()`, falls back to opening GitHub releases in browser.

## v2.7.5.0

- **Settings switches fixed** — `--advertise-exit-node` flag now uses proper `=true`/`=false` format (was missing the value). `setPref` now calls `poll()` after completing so the UI refreshes, and shows the RC code in error messages for debugging.

## v2.7.4.0

- **Faster update check** — shell fallback now tries curl/wget once each with a 4s timeout instead of 8 commands × 15s. The "Checking…" state resolves in seconds, not minutes, then shows the browser "Open" button if the WebView can't reach the network.
- **Update panel** — when a newer release exists, shows the new version with Download/Dismiss buttons and an inline spinner while downloading.

## v2.7.3.0

- **Settings switches fixed** — switches now use `setAttribute`/`removeAttribute` instead of the `selected` property, and `render()` skips switch updates while a `setPref` exec is in flight, so the md-switch's native toggle isn't overridden by stale prefs. Taps register correctly.
- **Hostname set to Android device name** — on connect, reads `ro.product.model` and runs `tailscale set --hostname=<name>` so your device shows up as (e.g.) "Pixel 8" instead of "localhost" in your tailnet.

## v2.7.2.0

- **User-friendly network errors** — instead of raw "fetch error: TypeError: Failed to fetch", the WebUI now says "WebUI can't reach the network — open GitHub releases in your browser?" with an "Open" button.
- **Download fallback to browser** — if curl/wget both fail during download, offers to open the zip URL in your browser.
- Browser fallback is now the primary path when the WebView blocks network access.

## v2.7.1.0

- **TLS certificate error handling** — if `fetch()` or shell curl/wget fails with a TLS/cert error ("tlsnscert"), the prompt now shows the actual error instead of a generic message.
- **`-k` / `--no-check-certificate` shell fallbacks** — curl and wget try with certificate verification disabled first, which works on devices whose CA store doesn't trust GitHub's TLS cert (common on rooted/custom Android).
- **Surfaces the actual fetch error** — instead of "no fetch tool found", shows the real error (e.g., TLS handshake failure, DNS, timeout).

## v2.7.0.0

- **Update check uses the WebView's built-in `fetch()`** — same pattern bindhosts uses. No longer needs curl/wget installed on the device to check for updates.
- **Falls back to shell curl/wget** if `fetch()` is blocked by the WebView.
- **If nothing works**, offers to open the GitHub releases page in your browser so you can download the zip manually.
- **Download also falls back** — curl first, then wget.

## v2.6.9.0

- **Update check works without curl** — tries curl, then wget, then busybox wget, then toybox wget. If none are available, offers to open the GitHub releases page in your browser so you can download the zip manually.
- **Download also falls back** — curl first, then wget, with a clear error if both are missing.

## v2.6.8.0

- **Update check now shows what went wrong** — if `curl` returns empty or non-JSON output, the prompt shows the actual response instead of a generic "Failed to parse update info". Removed `2>/dev/null` so errors aren't hidden.
- **Note:** `raw.githubusercontent.com` CDN may take a few minutes to reflect newly pushed versions. If you just updated, the update.json URL may still show the old version until the CDN cache clears.

## v2.6.7.0

- **Redesigned main screen around a single button** — removed the switch from the home page entirely. One primary button shows "Log in" when not logged in, "Connect" when stopped, "Disconnect" when running. Tapping the status card does the same thing.
- **No more dual loading circles** — one small spinner spins next to the main button during any action. No full-screen overlay, no second spinner.
- **Login button shows right away** — when not logged in, the main button says "Log in" and the login URL appears directly below it with Open/Copy buttons. No separate login box.
- **Status badge** — "Connected" / "Log in required" / "Not connected" chip next to the title.

## v2.6.6.0

- **Manual update button** — "Check for update" in the More page fetches update.json from GitHub and compares against your installed versionCode. If a newer release exists, it shows the version + changelog and a "Download" button that pulls the zip to /sdcard/Download/ via curl. The panel auto-checks on boot and stays silent when you're already current.
- **Update panel** — dismissible, shows the new version number, with Download/Dismiss buttons and an inline spinner while downloading.

## v2.6.5.0

- **Redesigned main UI around the switch** — the main toggle is now the primary action on the home page, not a big tap button. The switch sits prominently at the top of the status card with the status text below it.
- **No full-screen loading circle** — removed the busy overlay entirely. Loading state shows only inline: a small spinner next to the switch + the action text ("Starting…", "Stopping…", etc.) right under it.
- **Switch shows busy state** — when any root action is in flight, the switch gets a `busy` class (dimmed, pointer-events disabled) and the inline spinner spins next to it. The UI never looks frozen because `setTimeout(..., 0)` yields to the browser before `ksu.exec` runs.
- **Clean status card** — rounded surface container, larger "Tailscale" title, subtitle that shows connected/stopped state, inline busy row below.

## v2.6.4.0

- **No more frozen UI on start/stop** — the root cause was `ksu.exec(cmd)` being SYNCHRONOUS per the KernelSU-Next API docs: it blocks the WebView UI thread until the command finishes, so the busy overlay never had a chance to paint. Fixed two ways:
  1. Removed the sync fallback in `exec()` — if the callback bridge form fails, it reports an error instead of blocking on `ksu.exec(cmd)`.
  2. Every long exec (start, stop, restart, logout, exit node, settings, boot toggle) is now wrapped in `setTimeout(..., 0)` so the browser paints the busy overlay **before** `ksu.exec` runs. You see the spinner + "Starting…" immediately on tap, not after the command finishes.
- **All 7 action functions yield to the browser** before their root exec: toggleVPN, startLogin, setPref, setExitNode, restartService, confirmLogout, toggleBoot.

## v2.6.3.0

- **Start button actually works** — the `main-switch` toggle (Material switch in shadow DOM) never bubbled its click to `status-box`, so tapping the top toggle looked like it did nothing. It now has its own click handler wired to start/stop, so tapping the switch actually toggles the VPN.
- **No more "frozen" feel** — a full-screen dimming overlay with a large spinning circle + exact action text ("Starting…", "Stopping…", "Logging out…", "Applying settings…") covers the screen the instant you tap any action, before the root command runs. The old subtle linear progress bar alone was too easy to miss.
- **Header cleaned up** — smaller top bar, proper title weight, bottom divider, cleaner version text.

## v2.6.1.0

- **Login no longer looks frozen** — `startLogin()` shows the progress bar + "Generating login URL…" text immediately on tap, instead of a 20s snackbar that could expire before `tailscale login` finished. The menu stays responsive (buttons disabled with clear "working" feedback) until the auth URL is ready.
- Note: the browser login page itself loads at the speed of your network / the Tailscale control plane — that part isn't in the module's control.

## v2.6.0.0

- **WebUI: follows the manager's exact theme** — imports `colors.css`/`insets.css` from the manager's MUI host (KSU-Next/Magisk-on-KSU/MMRL), so the UI picks up your manager's Monet palette and real status/nav-bar insets instead of static guesses; falls back to its own M3 palette when served without one.
- **Adaptive polling** — 4s while an action is in flight or state just changed, 15s when idle, never while the page is hidden or a dialog is open; instant re-sync when you come back to the page (pageshow/focus/visibility).
- **Android back button works** (MMRL WebUI X): back closes the log terminal first, then returns to Home, then exits — via `webroot/config.json` (`backInterceptor: javascript`) which now ships in the zip (the `*.json` exclude was previously eating it).
- **Dialog lockout** — with a dialog open, touches/scroll behind it are blocked (Tricky-Addon pattern), so a stray tap can't flip a switch underneath.
- **Settings & service**: Start-tailscaled-on-boot toggle (`NOBOOT` marker checked by `service.sh`), daemon health warnings surfaced on Home, in-flight progress bar, action button `pgrep` now matches the daemon binary's cmdline (not the service script's).
- Synced with a survey of the ecosystem's best WebUIs (Tricky-Addon, zygisk-detach, bindhosts, zygisk-next): canonical bridge exec wrapper, batched shell work, guarded DOM updates, no per-render event rebinding.

## v2.5.1.0

- 501dead Fix daemon panic on login: taildrop newFileOps nil on headless Android + honest WebUI crash state
- **Fixed: daemon crashed the moment login completed.** v1.104.1's taildrop extension calls a nil `newFileOps` on headless Android builds (upstream bug — the file-ops provider only exists behind `!android` build tags or the official app's cgo). We now carry a patch in the build that disables Taildrop (non-functional headless anyway) instead of SIGSEGV-ing after successful login.
- **Fixed: UI limbo after a daemon crash** — the poll's `pgrep` matched the `tailscaled.service` script's own cmdline, so a dead daemon still showed "Not logged in" with every field "—". Liveness now comes from `status --json` itself: a crashed daemon shows "Service stopped — tap to start", and tapping restarts it.

## v2.5.0.0

- ce59c72 WebUI v3: bindhosts-style rewrite — Material components, one-exec poll, tap-safe rendering
- **WebUI v3** — rebuilt after bindhosts' proven layout (WTFPL, github.com/bindhosts/bindhosts): header + bottom bar (Home / Devices / More), Material web components (real `md-switch` etc., vendored prebuilt bundle — no build tooling in CI), slide-up logs terminal, M3 dialogs + snackbar, follows the manager's theme.
- **Fixes the slowness and dead touches:** one combined root-shell exec per poll instead of 4+; DOM/peer list only rebuilt when values actually change; events delegated on stable parents so a re-render can't swallow a tap. Polling pauses while dialogs are open.
- Login flow as in v2.4.0.1: auth URL auto-appears with Open in browser / Copy; manual Log in button; no auto-login execs. `tailscale set` flags verified against v1.104.1.
- Tested headless (mock connected / mock logged-out / no-bridge): all states render with zero console errors.

## v2.4.0.1

- **WebUI: login flow fixed.** The auth URL the daemon generates while you're logged out now appears automatically as a clickable link (with Open in browser / Copy) — previously it was generated but thrown away, so the switch sat off with no path forward.
- **WebUI: distinct "logged out" switch state.** When tailscaled is running but you're not logged in, the switch thumb glows amber and reads "tailscaled service is running — log in to connect" — no longer identical to the service-stopped look that contradicted the action button's "service running" report.

## v2.4.0.0

- **Fixed: `tailscaled` failed to start** (`--statedir (or at least --state) is required`). Our binaries are built from official tailscale source, which has no Android default paths (upstream's fork baked them in). The daemon now gets everything explicitly: `--tun=userspace-networking --statedir=/data/adb/tailscale --socket=/data/adb/tailscale/run/tailscaled.sock --port=41641`.
- **Ships the `tailscale` CLI** — previously no release contained the CLI binary at all (upstream used a multicall daemon). Each release tgz now contains `tailscaled` (daemon), `tailscale.bin` (CLI) and `tailscale` (small wrapper pointing the CLI at the module socket).
- State file lives at `/data/adb/tailscale/tailscaled.state` — preserved across module updates.
- Verified end-to-end on official v1.104.1 source: daemon stays up, userspace mode active, CLI `status --json` and `login` URL flow both work.

## v2.3.0.1

- d87d257 WebUI: harden boot against blank screen on KernelSU Next WebView

## v2.3.0.0

- **WebUI v2** — complete rewrite of `webroot/index.html` as a 3-page app: **Devices** (VPN toggle, login button, device info, peer list with tap-to-ping, health warnings), **Settings** (accept DNS, accept routes, advertise as exit node, LAN access, exit-node picker, logout), **Logs** (daemon + service logs).
- Always-render design (bindhosts-style): the page renders even when the KernelSU JS bridge is missing or late, with a retry banner — no more "open from KernelSU Manager" dead screen.
- Manual login button — no more auto-spawning `tailscale login` execs on every poll.
- Module description in KernelSU Manager now tracks VPN state (`⚡ VPN connected` / `⛔ VPN disconnected`), same format as the service writer.
- `action.sh`: removed `jq` dependency (not present on Android) — backend state parsed with grep/sed.

## v2.2.0.0

- Added KernelSU **WebUI** (`webroot/index.html`): status dashboard, connect/disconnect toggle, tailnet device list, login URL flow, logout, daemon log viewer. Opens via the WebUI button in KernelSU Manager / MMRL.
- Added **Action button** (`action.sh`): tap in KernelSU Manager to toggle Tailscale fully on/off (daemon start/stop + `tailscale up`/`down`); on first use it prints and opens a login URL.
- Tested against KernelSU's `ksu.exec` JS bridge (async callback + legacy sync fallback).

## v2.1.0.0

- Updated bundled tailscale binaries: 1.98.8 → 1.104.1 (built for Android from official tailscale v1.104.1 source: NDK cgo, feature-omitted slim build)
- `tailscale_1.104.1_<arch>.tgz` binaries are attached to releases, the lightweight zip now downloads them from this repo at install time
- CI (`.github/workflows/release.yml`) now builds the Android binaries itself (Go + NDK) instead of depending on `anasfanani/tailscale-android-cli` releases
- All updater JSONs, `module.prop` and download links point to TheWildJames/Magisk-Tailscaled
- Fork of [anasfanani/Magisk-Tailscaled](https://github.com/anasfanani/Magisk-Tailscaled) v2.0.0.1

## v2.0.0.1

- 429e1b0 build: fix version bump and add pre-release for build version
- 75834b4 fix: path order

## v2.0.0.0

### ⚠️ Important Notice
This build may be unstable. Please test thoroughly and report any issues you encounter.

**Exit Node Warning**: Using exit nodes may cause battery drain. Not recommended for 24/7 use.

**Testing Your Connection**:
- Check IP: https://browserleaks.com/ip
- Check DNS leaks: https://browserleaks.com/dns

### Major Rewrite
This is a complete rewrite of the module with significant improvements.

### What's New
- **Better DNS handling** - Improved DNS configuration and compatibility
- **SSH support** - Enhanced SSH functionality
- **Exit node support** - Better exit node handling
- **Hotspot client support** - Works with Android hotspot clients
- **VPN compatibility** - Can now run alongside other VPN apps
- **Root & Non-root mode** - Works in both root and non-root environments

### Technical Changes
- Removed all wrapper scripts for better performance
- Now uses tailscaled binaries from [tailscale-android-cli](https://github.com/anasfanani/tailscale-android-cli)
- Simplified module structure
- Improved stability and reliability

### Breaking Changes
This is a major version update. Please backup your configuration before upgrading.
