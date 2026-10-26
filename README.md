[![TheWildJames - Wild_Tailscale](https://img.shields.io/static/v1?label=TheWildJames&message=Wild_Tailscale&color=blue&logo=github)](https://github.com/TheWildJames/Wild_Tailscale "Go to GitHub repo")
[![Github All Releases](https://img.shields.io/github/downloads/TheWildJames/Wild_Tailscale/total.svg)]()
[![GitHub release](https://img.shields.io/github/release/TheWildJames/Wild_Tailscale?include_prereleases=&sort=semver&color=blue)](https://github.com/TheWildJames/Wild_Tailscale/releases/)
[![issues - Wild_Tailscale](https://img.shields.io/github/issues/TheWildJames/Wild_Tailscale)](https://github.com/TheWildJames/Wild_Tailscale/issues)
[![Static Badge](https://img.shields.io/badge/Discussion-Telegram-blue?style=flat&logo=telegram&link=t.me%2Fsystembinsh%2F158)](https://t.me/systembinsh/158)

# Tailscale

Full Tailscale VPN client for rooted Android — WireGuard mesh networking via KernelSU, Magisk or APatch.

Fork of [anasfanani/Magisk-Tailscaled](https://github.com/anasfanani/Magisk-Tailscaled) with the bundled tailscale binaries kept up to date (built from official tailscale source for Android) and a full Material Design 3 WebUI.

## What is Tailscale?

Tailscale is a networking tool that allows you to connect each of your devices as if they were on the same VPN. For example, an Android phone connected to the Tailscale network can communicate with any other device connected to Tailscale. You can install it on your PC and Android device and then connect them using the Tailscale IP. For more information, check out [How Tailscale Works](https://tailscale.com/blog/how-tailscale-works).

## Difference between this module and the Tailscale app on Play Store

The [Tailscale app](https://play.google.com/store/apps/details?id=com.tailscale.ipn) on the Play Store runs with Android's VPN, which means you can't use Tailscale while another VPN is active. This module, on the other hand, allows you to use both an Android VPN and Tailscale at the same time.

## Requirements

- A basic networking knowledge.
- An Android device with KernelSU, Magisk or APatch root installed.

## Quick Start & Installation

1. Download the latest zip file from the [Releases](https://github.com/TheWildJames/Wild_Tailscale/releases/latest) page.
2. Install the downloaded zip file using your root manager & reboot your phone.
3. Open the **WebUI** in the manager to connect, log in, and manage settings — or use the CLI:

```bash
su -c tailscale login    # open the URL in a browser to authorize
su -c tailscale ip       # show your Tailscale IP
```

After installation, the Tailscale daemon (`tailscaled`) will run automatically on boot.

## WebUI

On KernelSU (and MMRL) the module ships a full **Material Design 3 WebUI** — open it with the **WebUI** button in the manager:

- **Home**: status dot (green/red), one big action button (Connect / Disconnect / Log in), connection info (IPv4, IPv6, exit node, hostname, tailscale version), device list with online/offline dots and copy-IP buttons
- **Settings**: Start on boot toggle, Accept DNS, Accept routes, Advertise exit node, Allow LAN access, Restart service, Log out, Daemon logs (with Copy/Share), Doctor diagnostics, Update check, GitHub link
- The module description in the manager tracks live state: `[ ⏲ HH:MM | ⚡ VPN connected ]`
- Doctor button runs `tailscale status` + `netcheck` + `version` in one shot

The **Action** button in the manager toggles Tailscale completely on/off:

- **ON**: starts the `tailscaled` daemon, runs `tailscale up` (reuses stored prefs); if the device isn't logged in it prints a login URL and tries to open the browser.
- **OFF**: runs `tailscale down`, then stops the daemon.

On plain Magisk (no WebUI support) use `su -c tailscaled.service start|stop` instead.

## Limitation

- This module only supports `arm` or `arm64` architecture; you can download manually for other architectures.
- The daemon runs as a root process (no VpnService), so it shows up in the Tailscale admin console as a Linux device.
- MagicDNS names don't resolve system-wide (Android manages DNS via netd and `/etc` is read-only) — use tailnet IPs, or the daemon's own resolution.
- Exit-node use and advertised subnet routes are reachable; full-tunnel policy routing for all phone traffic is not configured by this module.

## Usage of this module

This module runs `tailscaled` with the following command:

```bash
tailscaled --tun=tailscale0 --statedir=/data/adb/tailscale --socket=/data/adb/tailscale/run/tailscaled.sock --port=41641 -no-logs-no-support
```

The daemon drives a real kernel TUN device (`tailscale0`) and installs Android policy-routing rules (priority 9000 for `100.64.0.0/10` and `fd7a:115c:a1e0::/48` → main table), so **apps on the phone reach tailnet IPs directly** — no official Tailscale app, no SOCKS proxy needed. TUN mode is mandatory; there is no userspace fallback.

The state file for tailscaled is stored at `/data/adb/tailscale/tailscaled.state`, and the log output is written to `/data/adb/tailscale/run/tailscaled.log`. The `tailscale` command is a small wrapper that points the CLI at the module's socket (`tailscale.bin` is the real CLI binary).

## Available commands

- `tailscale`: Tailscale CLI operation.
- `tailscaled`: Tailscaled daemon operation.
- `tailscaled.service`: Manage the tailscaled service — start, stop, restart, view live logs.

## Example: SSH to Termux

### On your Android device:

1. Set up SSHD:

```bash
apt update && apt upgrade
apt install openssh
passwd
sshd
```

2. Get your IP with `tailscale ip` or check the [Tailscale Admin Dashboard](https://login.tailscale.com/admin/machines).

### On your Windows PC:

1. Download & install [Tailscale for Windows](https://tailscale.com/download/windows)
2. Open app & login to Tailscale.
3. Open the terminal & SSH to your Android IP:

```bash
ssh root@<tailscale_ip> -p 8022
```

### SSH access to your Android device

You can also enable SSH access using [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh). Advertise SSH on the host with `tailscale up --ssh`.

Tailscale's SSH feature requires `getent` (GNU libc). A mock `getent` is included in `tailscale/bin/` to work around this on Android.

After advertising SSH on the host, SSH into your Android device with `ssh root@<tailscale_ip>`.

### ADB over Tailscale

```bash
# On the Android device:
setprop service.adb.tcp.port 5555
stop adbd
start adbd

# From your PC:
adb connect <tailscale_ip>:5555
```

## FAQ & Troubleshooting

Tailscale has many issues. Check them out [here](https://github.com/tailscale/tailscale/issues).

### Cannot access other tailnet devices

The module runs `tailscaled` with a real kernel TUN (`--tun=tailscale0`), so apps reach tailnet IPs directly. If something doesn't connect:

1. Verify `tailscaled.service` is running: `tailscaled.service restart`
2. Verify the TUN device exists: `ip link show tailscale0`
3. Verify the policy rules exist: `ip rule | grep 9000`
4. Check connectivity: `tailscale ping <tailnet_ip>`, then `curl <tailnet_ip>:<port> -vI`

If the daemon won't start, check `/dev/net/tun` exists and rerun `tailscaled.service restart`.

### Subnet routes not working

Accepted subnet routes are installed by the daemon's Linux router into the main routing table; add policy rules for their ranges the same way the service does for the tailnet (see `ts_rules_up` in `tailscale/scripts/tailscaled.service`).

### Exit nodes

Exit-node routing for all phone traffic is not configured by this module's policy rules (only the tailnet ranges). Advertised exit nodes still appear in the WebUI and can be selected with `tailscale set --exit-node=<ip>`.

### Headscale

Check [this](https://github.com/anasfanani/Magisk-Tailscaled/issues/19#issuecomment-2091579177).

### Other errors & bugs

1. Restart tailscaled: `tailscaled.service restart`
2. Reproduce the issue
3. Get logs at `/data/adb/tailscale/run/tailscaled.log` — or use the **Doctor** button in the WebUI

## Notes

This module is confirmed to be supported for KernelSU. If you encounter any problems, please let me know.

## Links

- [Tailscale Userspace Networking](https://tailscale.com/kb/1112/userspace-networking/)
- [Termux Issue #10166](https://github.com/termux/termux-packages/issues/10166)
- [Tailscale Static Packages](https://pkgs.tailscale.com/stable/#static)
- [Tailscale Knowledge Base](https://tailscale.com/kb)

## Credits

- [Tailscale Inc & AUTHORS](https://github.com/tailscale/tailscale) — for the static binaries of tailscale & tailscaled
- [John Wu & Authors](https://github.com/topjohnwu/Magisk) — for The Magic Mask for Android
- [heiher & Authors](https://github.com/heiher/hev-socks5-tunnel) — for the hev-socks5-tunnel
- [anasfanani](https://github.com/anasfanani/Magisk-Tailscaled) — for the original module

## Disclaimer

This module is provided as-is. It is not affiliated with the official Tailscale. It is a third-party implementation and the author is not responsible for any damage to your device that may occur from its use. Use at your own risk.

PRs welcome.

## License

Released under [BSD 3-Clause License](/LICENSE).
