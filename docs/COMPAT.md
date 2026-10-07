# Guest <-> Android contract (must not break)

Everything the Podroid APK expects from the guest. Ported scripts preserve these
behaviors exactly; the systemd units only replace *how* they are started.

## 1. Boot pipeline

```
QemuEngine/AvfEngine  -kernel vmlinuz-virt -initrd initrd.img  (Podroid assets)
  -> initramfs /init = init-podroid (upstream, unchanged)
       mounts /dev/vda -> /mnt/persist (ext4 rw, commit=1)
       mounts /dev/vdb -> /mnt/lower   (squashfs ro)
       overlay lower=/mnt/lower upper=/mnt/persist/upper work=... -> /
       switch_root /sbin/init
  -> /sbin/init = systemd (Debian systemd-sysv; upstream: busybox init + openrc)
  -> units in /etc/systemd/system/podroid-*.service
```

Storage layout unchanged: `docker` / `containers` / `lxc` binds to `/mnt/persist/*`
(still done in `podroid-bootstrap`, guards are idempotent under systemd).

## 2. Console markers (BootStageDetector)

Written **verbatim** to `/dev/console` (kernel console = `ttyAMA0` on QEMU,
`hvc0` on AVF):

| Marker | Emitted by | Contract |
|--------|-----------|----------|
| `Loading kernel modules...` | `podroid-bootstrap` | build-all.sh smoke check |
| `Configuring containers...` | `podroid-network` | informational |
| `DNS: <servers>` | `podroid-network` (QEMU) | informational |
| `Network found` | `podroid-network` | build-all.sh smoke check |
| `Starting SSH...` | `podroid-ready` | BootStageDetector stage |
| `Almost ready...` | `podroid-ready` | BootStageDetector stage |
| `Ready!` | `podroid-ready` | **sets VmState.Running** |

Ordering: `podroid-ready.service` runs `After=` network, dropbear, hostd, x11,
resize, vsock, downloads, docker, lxc-net, dnsmasq (mirrors upstream openrc `after *`).

## 3. ttys / terminal path

| tty | Role | Consumer |
|-----|------|----------|
| `hvc0` | login shell (getty + `podroid-login` restores winsize) | `terminal.sock` <- `libpodroid-bridge` (Android) |
| `hvc1` | `RESIZE rows cols` lines | `podroid-resize` daemon -> stty hvc0 + `/run/term_size` |
| `hvc2` | host bridge protocol (QEMU) | `podroid-hostd` <-> `host.sock` |
| `ttyAMA0` | kernel console (boot log) | `-serial unix:serial.sock` <- QemuBootMonitor |
| `ttyS0` | parked (AVF legacy) | none |

Getty selection: `podroid-getty` reads `podroid.tty=` from `/proc/cmdline`
(default `hvc0`), runs getty on the wanted tty and sleeps forever on the other.
The units `podroid-getty@hvc0.service` / `podroid-getty@ttyS0.service` mirror the
upstream inittab respawn lines.

systemd's auto-generated `serial-getty@ttyAMA0` / `serial-getty@hvc0` are **masked**
(finalize step) so nothing competes for the ttys and the boot log stays clean.

## 4. Host bridge / port forwarding / vsock

| Channel | QEMU | AVF |
|---------|------|-----|
| host bridge | `/dev/hvc2` (raw, no echo) | AF_VSOCK **9101** |
| vsock control | - | AF_VSOCK **9100** (`forwards.conf` seed) |
| downloads 9p | virtio-9p tag `downloads` -> `/mnt/downloads` | 9p over vsock **200000** |
| port forwards | QMP `hostfwd` from Android side | `podroid-vsock-agent` listeners |

Unchanged binaries: `podroid-hostd`, `podroid-vsock-agent` (built from the sibling
Podroid checkout, see `native/README.md`). Protocol: one line request / one line
response, base64 payload (`FWD-ADD`, `NOTIFY`, `STATS containers=N`, ...).

## 5. Services the Android side assumes exist

- **dropbear on guest :22**, root password `podroid` (implicit host forward 9922->22)
- **Xvnc :0 on 5900** (no auth, `-AcceptSetDesktopSize`) + **pulseaudio TCP 4713**
  (raw S16LE, null sink `podroid_sink`) — loopback-only forwards from Android
- container daemons: docker, podman (rootful), lxc + `lxcbr0` NAT
- `podroid-hostd` running (STATS push feeds the Home screen container count)

## 6. Kernel assumptions

Podroid's custom kernel 7.1.5, **all required features builtin** (`forced_builtin.config`:
virtio, 9p, vsock, netfilter/nftables, cgroup2, zram, binder, overlay...). Rootfs ships
**no `/lib/modules`** — same as upstream Alpine (`depmod`/`modprobe` calls no-op).

## 7. Persistence rules (unchanged)

- squashfs lower is physically read-only; every guest write copy-ups into
  `/mnt/persist/upper` -> survives VM reboot **and** APK update.
- `apk upgrade` equivalent (apt upgrade) therefore persists, at the cost of a second
  copy of base packages in `storage.img`.
- Nothing auto-wipes upper; only Settings -> Reset VM (or a future rootfs-id guard).
