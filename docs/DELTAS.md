# Alpine -> Debian delta map

What changes (and what deliberately does not) when swapping the guest distro.

## Package / tooling

| Concern | Alpine (upstream) | Debian 13 (trixie) arm64 |
|---------|-------------------|--------------------------|
| pkg manager | `apk` (`/etc/apk/repositories` = dl-cdn) | `apt` (`/etc/apt/sources.list`) |
| init | busybox init + openrc (`rc_parallel=YES`) | **systemd** (`systemd-sysv`) |
| service scripts | `/etc/init.d/podroid-*` (openrc-run) | `/etc/systemd/system/podroid-*.service` + ported scripts |
| runlevel enable | symlinks in `/etc/runlevels/default/` | symlinks in `multi-user.target.wants/` (manual, offline-safe) |
| getty | inittab `hvc0::respawn:podroid-getty hvc0` | `podroid-getty@hvc0.service` (+ ttyS0), serial-getty masked |
| dropbear | `dropbear-openrc`, keys generated on 1st boot | `dropbear` (postinst pregenerates keys), `/etc/default/dropbear` |
| DHCP client (AVF) | busybox `udhcpc` | `isc-dhcp-client` `dhclient` (timeout-wrapped) |
| static IP / DNS (QEMU) | `podroid-network` writes 10.0.2.15 + `qemu_resolv_conf` | **same script, ported verbatim** (incl. cmdline-injection guard) |
| LXC bridge NAT | Alpine `dnsmasq.lxcbr0` openrc service (10.0.3.1) | Debian `lxc-net.service` (+ `dnsmasq` pkg), verify at Phase 5 |
| VNC server | `tigervnc` -> `/usr/bin/Xvnc` | `tigervnc-standalone-server` -> `/usr/bin/Xvnc` (verify path) |
| audio | `pulseaudio` (+ `pulseaudio-utils`) | `pulseaudio` + `pulseaudio-utils` (module-simple-protocol-tcp) |
| fonts | `font-misc-misc font-cursor-misc ttf-dejavu` | `xfonts-base fonts-dejavu-core` |
| containers | podman, docker+docker-openrc, lxc+openrc, crun, netavark, aardvark-dns, slirp4netns, fuse-overlayfs | same set from Debian repos: `podman docker.io docker-compose-v2 lxc lxc-utils crun netavark aardvark-dns slirp4netns fuse-overlayfs` |
| uid maps | `shadow shadow-uidmap` + filecaps on newuidmap | `uidmap` + filecaps (libcap2-bin), **note: `/etc/subuid` still absent (root-only system, same gap as upstream)** |
| root password | `openssl passwd -6` written into shadow at build | `chpasswd` inside the arm64 chroot |
| DO NOT ship | man/doc/locale (stripped) | dpkg `path-exclude` config **before** package install |

## Script ports (logic kept, only openrc idioms replaced)

| openrc | systemd | change |
|--------|---------|--------|
| `podroid-migrate` start() | `podroid-migrate.service` (oneshot) | `ebegin/eend` -> stdout; else verbatim |
| `podroid-bootstrap` start() | `podroid-bootstrap.service` (oneshot) | verbatim; mount guards no-op where systemd already mounted (devpts/shm/mqueue/cgroup2) |
| `podroid-network` start() | `podroid-network.service` (oneshot) | `ebegin/eend` -> exit codes; AVF branch `udhcpc` -> `dhclient`; console markers kept |
| `podroid-ready` start() | `podroid-ready.service` (oneshot) | verbatim (oom_score_adj + markers) |
| `podroid-x11` (start-stop-daemon + liveness poll) | `podroid-xvnc.service` + `podroid-pulse.service` (simple) | systemd tracks the main pid, poll code dropped; DPI/lock/rm moved into `podroid-xvnc` wrapper; pulse env into `podroid-pulse` wrapper |
| `podroid-resize` (command_background) | `podroid-resize.service` (simple) | binary is already foreground |
| `podroid-hostd` (start-stop-daemon) | `podroid-hostd.service` (simple) | binary is already foreground |
| `podroid-vsock` (+ AVF gate) | `podroid-vsock.service` | `mark_service_inactive` -> `ConditionKernelCommandLine=podroid.backend=avf` |
| `podroid-downloads` (+ AVF gate) | `podroid-downloads.service` | same condition + `After=podroid-vsock podroid-network` |
| inittab getty respawn | `podroid-getty@tty.service` | wrapper keeps `podroid.tty=` selection + sleep-park; getty path auto-detected (`getty`/`agetty`) |

## Intentionally NOT changed

- `init-podroid` (initramfs PID 1) — distro-agnostic
- custom kernel + `vmlinuz-virt` / `initrd.img` assets
- host bridge / vsock-agent C binaries and wire protocol
- console marker strings, hvc0/1/2 roles, 9922/5900/4713 implicit forwards
- storage layout (`/mnt/persist`, container binds, plain overlay)
- asset file name `alpine-rootfs.squashfs` (legacy name, keeps APK untouched)

## Known gaps (documented, same as upstream)

1. `ssh=1` / `androidip=` cmdline tokens are consumed by nobody (upstream dead params).
2. guest dropbear always on :22 with root/`podroid`; security relies on no LAN forward.
3. `/etc/subuid`+`/etc/subgid` absent -> "rootless podman" claim needs verification;
   rootful podman/docker/lxc are the supported path.
4. `/etc/resolv.conf` rewritten every boot by `podroid-network` (QEMU branch).
