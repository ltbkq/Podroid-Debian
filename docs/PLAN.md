# Plan

## Goal

Replace the Alpine guest rootfs with Debian arm64 while keeping the Podroid app
contract untouched (console markers, hvc0/hvc1/hvc2, host bridge, port forwarding,
storage layout).

## Phases

| # | Phase | Status | Blocking |
|---|-------|--------|----------|
| 0 | Research: boot contract, openrc -> systemd mapping, persistence model | done | - |
| 1 | Project scaffolding (build scripts, units, ported bring-up scripts, docs) | done | - |
| 2 | Build environment on the dev machine | **blocked** | no `docker`, no passwordless `sudo` on this host |
| 3 | First successful `out/debian-rootfs.squashfs` build | pending | Phase 2 |
| 4 | Graft + boot test on device (QEMU backend, console `Ready!`) | pending | Phase 3 + device access |
| 5 | Service verification pass (dropbear/9922, hostd, resize, x11, containers) | pending | Phase 4 |
| 6 | AVF backend verification (vsock agent, downloads 9p, port forwards) | pending | a pKVM device |
| 7 | Hardening: rootfs-identity guard (auto-wipe upper on distro switch), desktop profile | pending | Phase 5 |

### Phase 2 details (build environment)

The rootfs must run **arm64 package postinst scripts**. Two supported paths:

1. **Docker (preferred)** — `docker buildx` + `qemu-user-static` binfmt registration
   (`docker run --privileged tonistiigi/binfmt --install arm64`). Needs docker installed
   (`sudo apt install docker.io` or upstream's `./build-all.sh` prerequisites).
2. **Local debootstrap** — `sudo apt install qemu-user-static` (binfmt `qemu-aarch64`)
   + `debootstrap --arch=arm64 --foreign`, second stage in a chroot, `squashfs-tools`.
   Needs root (chroot/mount).

`./build/build-rootfs.sh --check` reports which path is available.

### Phase 7 hardening (recommended)

- Patch upstream `init-podroid` (or add a `podroid-migrate` script) to compare
  `/etc/os-release` identity stored in `/mnt/persist/.podroid/rootfs-id` against the
  current lower, and wipe `upper/` + container binds on mismatch. Until then, the
  **Reset VM** step in the README is mandatory when switching Alpine -> Debian.
- Optional desktop profile (`packages-desktop.list`): xfce4/lightdm under Xvnc — needs
  session-start integration with `podroid-x11` (startxfce4 inside the VNC session).

## Risks / open questions

| Risk | Impact | Mitigation |
|------|--------|------------|
| Debian package set differs from Alpine (netavark/aardvark/dnsmasq-lxc bridge) | containers networking broken | verify at Phase 5; `packages.list` mirrors upstream set |
| `Xvnc` binary path / fonts on Debian (`tigervnc-standalone-server`) | X11 viewer dead | check at Phase 5, wrapper supports fallback path |
| dropbear unit defaults (root login with password) | SSH 9922 dead | `/etc/default/dropbear` written by finalize; test at Phase 5 |
| systemd + custom kernel without `/lib/modules` | some units warn | all features builtin upstream (`forced_builtin.config`); silence `systemd-modules-load` if noisy |
| Debian postinst wants dbus/udev during build (chroot) | build failure | `-o policy-rc.d` stub + `RUN systemctl` avoided; units enabled by manual symlinks |
| Storage: Debian is larger than Alpine (docker.io + X11) | storage.img growth | squashfs zstd level 19; dpkg nodoc excludes |
