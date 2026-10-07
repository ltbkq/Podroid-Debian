# Podroid-Debian

**Debian (arm64) rootfs for [Podroid](https://github.com/ExTV/Podroid)** — a drop-in
replacement for Podroid's Alpine `alpine-rootfs.squashfs`, keeping the exact same
guest <-> Android boot contract.

Podroid boots a custom 7.1.5 aarch64 kernel + `init-podroid` (PID 1) that mounts a
squashfs lower + ext4 upper overlay and `switch_root`s into `/sbin/init`. This project
provides a **systemd-based Debian rootfs** that plugs into that same pipeline, so the
APK-side code (QemuEngine / AvfEngine / BootStageDetector / host bridge) needs **zero
changes**.

> Status: **scaffolding / Phase 1**. See [docs/PLAN.md](docs/PLAN.md).

## Why Debian (and not "Linux Mint")

Linux Mint ships no ARM images and this VM is aarch64-only (`--target-list=aarch64-softmmu`).
Debian arm64 is Mint's upstream base, has the apt ecosystem, systemd, and packages for the
whole container stack. See [docs/DELTAS.md](docs/DELTAS.md) for the Alpine -> Debian mapping.

## Layout

```
build/          build pipeline (docker path + local root path)
  build-rootfs.sh      entry point: --check | docker | local
  Dockerfile.rootfs    arm64 container build (needs binfmt/qemu-user)
  local-rootfs.sh      debootstrap path (needs root + qemu-user-static)
  rootfs-finalize.sh   shared in-chroot assembly (units, password, cleanup)
  packages.list        apt package set (container + base + X11)
  packages-desktop.list  optional desktop profile (experimental)
rootfs/         overlay copied verbatim into the image
  etc/systemd/system/  systemd units replacing Alpine's openrc podroid-* scripts
  etc/podroid/         forwards.conf, migrations/
  usr/local/lib/podroid/  ported bring-up scripts (start logic kept verbatim)
  usr/local/bin/       getty/login/resize helpers (same contract as upstream)
tests/          regression tests (DNS resolver ordering, ported from upstream)
tools/          graft.sh (install into a Podroid checkout), boot-test.sh (adb)
docs/           PLAN / COMPAT / DELTAS
native/         pointer to the upstream C sources (hostd, vsock-agent) — not vendored
```

## Quick start

```sh
# 1. check what this machine needs to build
./build/build-rootfs.sh --check

# 2. build (docker with arm64 binfmt, or root + qemu-user-static)
./build/build-rootfs.sh
#    -> out/debian-rootfs.squashfs

# 3. install into a Podroid checkout (legacy asset name is intentional)
./tools/graft.sh /path/to/Podroid

# 4. in the Podroid app: Settings -> Reset VM  (IMPORTANT: wipes the Alpine overlay upper)
# 5. rebuild + install the APK, start the VM
./build-all.sh apk deploy   # inside the Podroid checkout
./tools/boot-test.sh        # adb smoke test: poll console.log for "Ready!"
```

## Hard requirements

- The VM keeps Podroid's **custom kernel** (everything builtin, no `/lib/modules` needed —
  same assumption as upstream Alpine).
- First boot on an existing install **must wipe the overlay upper** (`Reset VM`), otherwise
  Alpine copy-up files shadow the Debian rootfs.
- Asset file name stays `alpine-rootfs.squashfs` so no Kotlin change is needed
  (`PodroidApplication.kt:107`, `QemuEngine.kt:575`, `AvfEngine.kt:1027`).

## License

GPLv2, same as Podroid. Boot scripts are ports of ExTV/Podroid's openrc scripts
(original logic preserved and marked with comments).
