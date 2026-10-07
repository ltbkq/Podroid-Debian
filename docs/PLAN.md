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
| 2 | Build environment on the dev machine | done | local debootstrap path (`qemu-user-static` + binfmt + root; no docker needed) |
| 3 | First successful `out/debian-rootfs.squashfs` build | done | 284M, zstd-19, trixie + 283 pkgs, 12 systemd units enabled |
| 4 | Graft + boot test on device (QEMU backend, console `Ready!`) | graft done | boot test: install `app-release.apk` (uninstall old pkg first) → Reset VM → `./tools/boot-test.sh` |
| 5 | Service verification pass (dropbear/9922, hostd, resize, x11, containers) | pending | Phase 4 |
| 6 | AVF backend verification (vsock agent, downloads 9p, port forwards) | pending | a pKVM device |
| 7 | Hardening: rootfs-identity guard (auto-wipe upper on distro switch), desktop profile | pending | Phase 5 |

### APK rebuild notes (this machine, 2026-10-07)

The checkout had none of the generated assets (all gitignored). Instead of
running upstream's docker builds, they were extracted from the APK already
installed on the phone:

- `assets/vmlinuz-virt`, `assets/initrd.img` — initramfs `/init` verified
  distro-neutral (plain overlay, calls `/mnt/lower/usr/local/bin/podroid-overlay-normalize`,
  which this rootfs ships at exactly that path), so no kernel/initramfs rebuild.
- `jniLibs/arm64-v8a/{libqemu-system-aarch64,libslirp,libpodroid-bridge,libpodroid-launcher}.so`
  (libqemu verified 16KB-aligned).
- SDK/NDK live on the data disk (`/media/ltbkq/mydata/android-sdk`, root fs was 99%
  full); `local.properties` points at it, Gradle home is
  `GRADLE_USER_HOME=/media/ltbkq/mydata/gradle-home` (proxy systemProps live there).
- Release APK signed with a **project-local keystore**
  (`Podroid-Debian/keys/`, gitignored, password not in VCS) passed as
  `-PPODROID_RELEASE_*` — the installed phone build is signed with a key we do
  not have, so switching packages requires uninstall + install (app data lost;
  `storage.img` is recreated on first boot).
- Result: `app/build/outputs/apk/release/app-release.apk` (367M), package
  `com.excp.podroid`, versionCode 33 == rootfs `system-version=33`,
  embeds `assets/alpine-rootfs.squashfs` = the Debian image (297,156,608 bytes).

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
