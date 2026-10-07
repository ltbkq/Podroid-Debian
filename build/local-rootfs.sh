#!/bin/sh
# build/local-rootfs.sh — debootstrap path (no docker).
# Needs: root (chroot/mount), qemu-user-static with arm64 binfmt, squashfs-tools.
# Produces: out/debian-rootfs.squashfs
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(dirname "$HERE")
MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
SUITE=${DEBIAN_SUITE:-trixie}
SYSVER=${SYSTEM_VERSION:-33}
WORK=$PROJ/work/rootfs
OUT=$PROJ/out

[ "$(id -u)" -eq 0 ] || { echo "local path needs root (chroot/mount): sudo $0" >&2; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || {
    echo "FATAL: arm64 binfmt not registered (apt install qemu-user-static;" >&2
    echo "       sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc)" >&2
    exit 1; }
command -v mksquashfs >/dev/null || { echo "FATAL: squashfs-tools not installed" >&2; exit 1; }

mkdir -p "$OUT" "$WORK"
if [ ! -f "$WORK/.second-stage-done" ]; then
    echo "==> debootstrap --foreign ($SUITE arm64)"
    debootstrap --arch=arm64 --foreign --variant=minbase "$SUITE" "$WORK" "$MIRROR"
    cp /usr/bin/qemu-aarch64-static "$WORK/usr/bin/"
    echo "==> second stage (arm64 via binfmt)"
    chroot "$WORK" /debootstrap/debootstrap --second-stage
    touch "$WORK/.second-stage-done"
fi

echo "==> mounts"
mount --bind /dev  "$WORK/dev"
mount --bind /proc "$WORK/proc"
mount -t sysfs sysfs "$WORK/sys"
cleanup() {
    umount "$WORK/sys" 2>/dev/null || true
    umount "$WORK/proc" 2>/dev/null || true
    umount "$WORK/dev" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> packages"
mkdir -p "$WORK/etc/dpkg/dpkg.cfg.d"
cat > "$WORK/etc/dpkg/dpkg.cfg.d/01-nodoc" <<'EOF'
path-exclude=/usr/share/man/*
path-exclude=/usr/share/doc/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locales.alias
EOF
printf '#!/bin/sh\nexit 101\n' > "$WORK/usr/sbin/policy-rc.d"
chmod +x "$WORK/usr/sbin/policy-rc.d"
grep -vE '^\s*(#|$)' "$HERE/packages.list" > "$WORK/tmp/packages.list"
[ "${1:-}" = "--desktop" ] && grep -vE '^\s*(#|$)' "$HERE/packages-desktop.list" >> "$WORK/tmp/packages.list"
chroot "$WORK" apt-get update
chroot "$WORK" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confold $(cat "$WORK/tmp/packages.list")
rm -f "$WORK/tmp/packages.list"

echo "==> native binaries (from sibling Podroid checkout)"
PODROID_SRC=${PODROID_SRC:-$PROJ/../Podroid}
STAGE=$PROJ/native/staged
if [ ! -x "$STAGE/podroid-hostd" ]; then
    echo "   building C sources from $PODROID_SRC"
    "$HERE/build-native.sh" "$PODROID_SRC"
fi
install -m 0755 "$STAGE"/podroid-hostd "$WORK/usr/local/bin/"
install -m 0755 "$STAGE"/podroid-vsock-agent "$WORK/usr/local/bin/"
install -m 0755 "$STAGE"/podroid-overlay-normalize "$WORK/usr/local/bin/"

echo "==> overlay + finalize"
mkdir -p "$WORK/opt/podroid-rootfs-overlay"
cp -a "$PROJ/rootfs"/. "$WORK/opt/podroid-rootfs-overlay/"
cp "$HERE/rootfs-finalize.sh" "$WORK/opt/"
SYSTEM_VERSION=$SYSVER chroot "$WORK" /bin/sh /opt/rootfs-finalize.sh
rm -f "$WORK/opt/rootfs-finalize.sh" "$WORK/usr/bin/qemu-aarch64-static"

echo "==> mksquashfs"
cleanup; trap - EXIT
# Excluding runtime dirs keeps the image clean (they are tmpfs/empty anyway).
mksquashfs "$WORK" "$OUT/debian-rootfs.squashfs" \
    -comp zstd -Xcompression-level 19 -all-root -noappend \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" "mnt/*" "debootstrap/*" ".second-stage-done"

echo "OK: $OUT/debian-rootfs.squashfs ($(du -h "$OUT/debian-rootfs.squashfs" | cut -f1))"
