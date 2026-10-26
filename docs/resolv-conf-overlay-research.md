# resolv.conf on Android: overlay vs runtime, reboot semantics, KernelSU specifics

## The install-time warning

`Could not create /etc/resolv.conf — DNS may not work` was printed by our own
`customize.sh`. It tried `printf ... > /etc/resolv.conf` during install. That
can never work: `/etc` is a symlink to `/system/etc`, which is read-only
(`/system` isn't even a separate mount on current ROMs — it's part of a
read-only dm-verity device). Fixed in v2.9.1.0: install now seeds
`$MODPATH/system/etc/resolv.conf` (module dir, always writable) instead.

## Three mechanisms, three lifetimes

| # | Mechanism | When it takes effect | Reboot needed? |
|---|-----------|---------------------|----------------|
| 1 | Module overlay `system/etc/resolv.conf` | Next boot (mounts are set up in post-fs-data) | **Yes**, for first appearance / new files |
| 2 | `netenv.sh` runtime bind-mount of `$TS_DIR/resolv.conf` onto `/etc/resolv.conf` | Immediately, every 15 s sync | **No** |
| 3 | `tailscaled.service` `private_etc()`: daemon launched in its own mount namespace with a private `/system/etc` copy in `/data` | Daemon (re)start | **No** (restarts with the daemon) |

So the user's guess is half-right: **changing the overlay file needs a reboot,
but toggling DNS on/off at runtime does not** — toggles go through mechanisms
2 and 3, which are instant. The daemon's own `/etc/resolv.conf` rewrites (the
"source" of the old `resolv.pre-tailscale-backup.conf: read-only` health
warning) land in the private namespace copy, never touch `/system`.

## Bind-mount target must exist

`mount --bind <file> /etc/resolv.conf` fails if the target path doesn't
exist, and it can't be created (read-only parent dir). That's why the module
ships `system/etc/resolv.conf` with fallback nameservers: on Magisk the magic
mount materializes the target at boot, so the later runtime bind-mount always
has something to attach to. On the user's device the file already exists
(`-rw-rw-rw- ... /system/etc/resolv.conf`, with a writable per-file mount
over it from a previous netenv run).

## KernelSU specifics (from kernelsu.org guide + difference-with-magisk)

- Module layout is `/data/adb/modules/$MODID` with `module.prop`, `system/`,
  `service.sh`, `post-fs-data.sh`, `boot-completed.sh`, `action.sh`,
  `webroot/`, etc. — same shape as Magisk.
- **`system/` is mounted only if a metamodule is installed** (e.g.
  meta-overlayfs). Quote: "Only if your module needs to modify `/system`
  files (via the `system` directory) do you need to install a metamodule."
  Without one, our `system/etc/resolv.conf` is silently ignored on KernelSU —
  mechanisms 2 and 3 still carry DNS, so nothing breaks, but the boot-time
  target-creation doesn't happen.
- KernelSU has no Zygisk built in (ZygiskNext fills the gap); no `.replace`
  support (uses `REMOVE`/`REPLACE` vars or `mknod` device-node trick instead).
- Script env: everything runs under BusyBox ash standalone mode;
  `/data/adb/ksu/bin/busybox` vs Magisk's `/data/adb/magisk/busybox`.
  Detect flavor with the `KSU=true` env var in `customize.sh`/boot scripts.
- Extra stages vs Magisk: `post-mount.sh` (after module mounting) and
  `boot-completed.sh`.
- WebUI: `webroot/index.html` entry, manager shows it in WebView, `ksu.exec`
  bridge. Our WebUI already targets the `ksu` global (not the `kernelsu` npm
  lib) — correct for the manager WebView, which injects the bridge itself.
- `localStorage` is lost if the manager app is uninstalled — we already keep
  persistent state (exitnode, magicdns.enabled, NOBOOT) in
  `/data/adb/tailscale/`, which is the right call.

## Practical consequences / TODO

1. On KernelSU without meta-overlayfs, consider creating the
   `/etc/resolv.conf` target another way if missing. Options: (a) document the
   metamodule requirement; (b) at `service.sh` time, if target is missing,
   bind-mount the stage file one level differently — there is no clean way to
   materialize a new file under ro `/system/etc` from the global namespace.
   Realistic answer: (a) + rely on private_etc for the daemon.
2. A future `post-mount.sh` (KernelSU) / `post-fs-data` step could verify the
   overlay landed (`[ -f /system/etc/resolv.conf ]`) and log which mechanism
   is active — makes DNS debugging much faster.
3. `KSU=true` detection could tailor install messages (metamodule hint) per
   flavor. Not started.

## Sources

- https://kernelsu.org/guide/module.html (module layout, metamodule note, WebUI, BusyBox)
- https://kernelsu.org/guide/difference-with-magisk.html (`KSU` env var, metamodule mounting, no `.replace`, extra stages)
- https://kernelsu.org/guide/module-webui.html (`webroot/`, `ksu.exec` JS API, localStorage caveat)
- `tailscale/scripts/tailscaled.service` `private_etc()` in this repo
- `tailscale/scripts/netenv.sh` `write_resolv()` in this repo
