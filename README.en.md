# Podroid-Debian

**English** | [简体中文](#下面)

**Debian (arm64) rootfs for [Podroid](https://github.com/ExTV/Podroid)** — a drop-in
replacement for Podroid's Alpine `alpine-rootfs.squashfs`, keeping the exact same
guest ↔ Android boot contract.

Podroid boots a custom 7.1.5 aarch64 kernel + `init-podroid` (PID 1) that mounts a
squashfs lower + ext4 upper overlay and `switch_root`s into `/sbin/init`. This project
provides a **systemd-based Debian rootfs** that plugs into that same pipeline, so the
APK-side code (QemuEngine / AvfEngine / BootStageDetector / host bridge) needs **zero
changes**.

> Status: **Phases 2–4 done** (build, on-device install). `graft.sh` is **abolished**
> per `DESIGN.md §11.2`: systems ship as standalone `.img` files, the APK no longer
> bundles a rootfs. See [docs/PLAN.md](docs/PLAN.md).

## Why Debian (and not "Linux Mint")

Linux Mint ships no ARM images and this VM is aarch64-only (`--target-list=aarch64-softmmu`).
Debian arm64 is Mint's upstream base, has the apt ecosystem, systemd, and packages for the
whole container stack. See [docs/DELTAS.md](docs/DELTAS.md) for the Alpine → Debian mapping.

## Layout

```
build/          build pipeline (docker path + local root path)
  build-rootfs.sh      entry point: --check | docker | local
  Dockerfile.rootfs    arm64 container build (needs binfmt/qemu-user)
  local-rootfs.sh      debootstrap path (needs root + qemu-user-static)
  rootfs-finalize.sh   shared in-chroot assembly (units, password, cleanup)
  build-native.sh      cross-compiles guest C binaries (aarch64 static)
  packages.list        apt package set (container + base + X11)
  packages-desktop.list  optional desktop profile (experimental)
rootfs/         overlay copied verbatim into the image
  etc/systemd/system/  systemd units replacing Alpine's openrc podroid-* scripts
  etc/podroid/         forwards.conf, migrations/
  usr/local/lib/podroid/  ported bring-up scripts (start logic kept verbatim)
  usr/local/bin/       getty/login/resize helpers (same contract as upstream)
tests/          regression tests (DNS resolver ordering, ported from upstream)
tools/          mkimg.sh (pack/verify .img), catalog.sh, pc-boot-smoke.sh, boot-test.sh (adb smoke)
docs/           PLAN / COMPAT / DELTAS
native/         staged aarch64 binaries (hostd, vsock-agent, overlay-normalize)
```

## Quick start

```sh
# 1. check what this machine needs to build
./build/build-rootfs.sh --check

# 2. build (docker with arm64 binfmt, or root + qemu-user-static)
./build/build-rootfs.sh
#    -> out/debian-rootfs.squashfs

# 3. pack the .img (R-16 requires the kernel/initrd payload inside; DESIGN §2/§6)
tools/mkimg.sh --rootfs out/debian-rootfs.squashfs --manifest <manifest.json> \
               --kernel <vmlinuz> --initrd <initrd.img> -o out/debian.img
#    note: graft.sh is ABOLISHED per DESIGN §11.2 (the APK no longer bundles a
#    rootfs; systems are distributed as standalone .img files)

# 4. import the .img into the app (setup/images page "import from file" or
#    catalog download), activate it via the Home boot-image selector (§8.2), start

# 5. adb smoke test: poll console.log for "Ready!" (script builds its own
#    adb forward tcp:9922)
./tools/boot-test.sh                      # PKG defaults to io.github.ltbkq.vmdroid.debug
./tools/boot-test.sh <other.pkg.debug>    # or pass the package name as $1
```

## Default credentials (DESIGN §4.8)

| user | password |
|------|----------|
| `root` | **`123`** |
| `ltbkq` | **`123`** (passwordless sudo) |

```sh
adb forward tcp:9922 tcp:9922
ssh ltbkq@localhost -p 9922       # password: 123
ssh root@localhost -p 9922        # password: 123
```

> Upstream Alpine rootfs used `podroid`; changed to `123` (2026-10-07) at the
> maintainer's request — set in `build/rootfs-finalize.sh`.

## Hard requirements

- The VM keeps Podroid's **custom kernel** (everything builtin, no `/lib/modules` —
  same assumption as upstream Alpine).
- Upgrading from Alpine **must wipe the overlay upper** (`Reset VM` on first boot),
  otherwise Alpine copy-up files shadow the Debian rootfs.
- Asset file name stays `alpine-rootfs.squashfs` so no Kotlin change is needed
  (`PodroidApplication.kt:107`, `QemuEngine.kt:575`, `AvfEngine.kt:1027`).

## License

GPLv2, same as Podroid. Boot scripts are ports of ExTV/Podroid's openrc scripts
(original logic preserved and marked with comments).
