#!/bin/sh
# build/local-rootfs-minimal.sh — 首发最小镜像（DESIGN §4.5）的 local debootstrap 路径。
#
# 与 build/local-rootfs.sh（全量基线 362 包 / out/debian-rootfs.squashfs）并行，
# 但工作目录固定为 work-minimal/，**不触碰 work/** 与 out/debian-rootfs.squashfs。
#
# 需要：root（chroot/mount）、qemu-user-static + arm64 binfmt、squashfs-tools。
# 产物：out/debian-rootfs-minimal.squashfs（zstd-19，参数与全量一致）
#
# 用法：sudo build/local-rootfs-minimal.sh
#   DEBIAN_MIRROR=...  覆盖默认源（默认 deb.debian.org 直连，本机已实测可达）
#   SYSTEM_VERSION=34  覆盖 /etc/podroid/system-version（默认 34 = manifest system_version）
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(dirname "$HERE")
# deb.debian.org 直连可达（本机 sudo 环境无代理变量），debootstrap 不需要代理；
# 需要国内镜像时用 DEBIAN_MIRROR=http://mirrors.aliyun.com/debian 覆盖。
MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
SUITE=${DEBIAN_SUITE:-trixie}
SYSVER=${SYSTEM_VERSION:-34}
WORK=$PROJ/work-minimal/rootfs
OUT=$PROJ/out
PKGLIST=$HERE/packages-minimal.list
SQUASH=$OUT/debian-rootfs-minimal.squashfs

[ "$(id -u)" -eq 0 ] || { echo "local path needs root (chroot/mount): sudo $0" >&2; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || {
    echo "FATAL: arm64 binfmt not registered (apt install qemu-user-static;" >&2
    echo "       sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc)" >&2
    exit 1; }
command -v mksquashfs >/dev/null || { echo "FATAL: squashfs-tools not installed" >&2; exit 1; }
[ -f "$PKGLIST" ] || { echo "FATAL: missing $PKGLIST" >&2; exit 1; }

mkdir -p "$OUT" "$WORK"
# debootstrap 的 check_sane_mount 会在目标目录里 echo 一个设备节点来探测 nodev。
# 本机数据盘由 udisks2 挂成 nosuid,nodev → 会报 "mounted with noexec or nodev" 而失败。
# 解法：把 work-minimal/ 自挂载到自身并只放开 dev（影响范围仅这棵子树）。
if ! (mknod "$WORK/.devnode-probe" c 1 3 2>/dev/null && echo t > "$WORK/.devnode-probe" 2>/dev/null); then
    rm -f "$WORK/.devnode-probe"
    echo "==> target is mounted nodev: self-bind + remount,dev for $PROJ/work-minimal"
    mount --bind "$PROJ/work-minimal" "$PROJ/work-minimal"
    mount -o remount,bind,dev "$PROJ/work-minimal"
fi
rm -f "$WORK/.devnode-probe"
if [ ! -f "$WORK/.second-stage-done" ]; then
    echo "==> debootstrap --foreign ($SUITE arm64, minbase) -> work-minimal/"
    debootstrap --arch=arm64 --foreign --variant=minbase "$SUITE" "$WORK" "$MIRROR"
    cp /usr/bin/qemu-aarch64-static "$WORK/usr/bin/"
    echo "==> second stage (arm64 via binfmt)"
    chroot "$WORK" /debootstrap/debootstrap --second-stage
    touch "$WORK/.second-stage-done"
    # 记录 minbase 基础包数（dpkg/apt/coreutils/tar/gzip/sed/grep/login/ncurses/
    # tzdata… 这些不是任何清单条目的依赖，但在 dpkg -l 里计数）。
    # 供 finalize-minimal.sh 区分"deps 闭包"与"dpkg -l 总数"两种口径。
    chroot "$WORK" dpkg -l | grep -c '^ii' > "$PROJ/work-minimal/.base-pkg-count"
    echo "==> base packages: $(cat "$PROJ/work-minimal/.base-pkg-count")"
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

echo "==> packages (minimal: $PKGLIST)"
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
# Strip comments (whole-line AND trailing) then drop blanks — apt gets words only.
grep -vE '^[[:space:]]*(#|$)' "$PKGLIST" \
    | sed 's/#.*$//' | sed -e 's/[[:space:]]*$//' -e '/^$/d' > "$WORK/tmp/packages.list"
[ -s "$WORK/tmp/packages.list" ] || { echo "FATAL: empty package list" >&2; exit 1; }
# Retries: flaky proxies return intermittent 502s on bulk downloads.
APT_OPTS="-o Acquire::Retries=20 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
# shellcheck disable=SC2086
chroot "$WORK" env DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS update
# shellcheck disable=SC2086
chroot "$WORK" env DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confold $(cat "$WORK/tmp/packages.list")
rm -f "$WORK/tmp/packages.list"

echo "==> native binaries (from sibling Podroid checkout / native/staged)"
PODROID_SRC=${PODROID_SRC:-$PROJ/../Podroid}
STAGE=$PROJ/native/staged
if [ ! -x "$STAGE/podroid-hostd" ] || [ ! -x "$STAGE/podroid-overlay-normalize" ]; then
    echo "   building C sources from $PODROID_SRC"
    "$HERE/build-native.sh" "$PODROID_SRC"
fi
for b in podroid-hostd podroid-vsock-agent podroid-overlay-normalize; do
    [ -x "$STAGE/$b" ] || { echo "FATAL: missing $STAGE/$b (run build/build-native.sh)" >&2; exit 1; }
done
install -m 0755 "$STAGE"/podroid-hostd "$WORK/usr/local/bin/"
install -m 0755 "$STAGE"/podroid-vsock-agent "$WORK/usr/local/bin/"
install -m 0755 "$STAGE"/podroid-overlay-normalize "$WORK/usr/local/bin/"

echo "==> overlay + finalize (shared rootfs-finalize.sh, then finalize-minimal.sh)"
mkdir -p "$WORK/opt/podroid-rootfs-overlay"
cp -a "$PROJ/rootfs"/. "$WORK/opt/podroid-rootfs-overlay/"
cp "$HERE/rootfs-finalize.sh" "$WORK/opt/"
cp "$HERE/finalize-minimal.sh" "$WORK/opt/"
SYSTEM_VERSION=$SYSVER chroot "$WORK" /bin/sh /opt/rootfs-finalize.sh
BASE_PKG_COUNT=$(cat "$PROJ/work-minimal/.base-pkg-count" 2>/dev/null || echo 0)
BASE_PKG_COUNT=$BASE_PKG_COUNT SYSTEM_VERSION=$SYSVER \
    chroot "$WORK" /bin/sh /opt/finalize-minimal.sh
rm -f "$WORK/opt/rootfs-finalize.sh" "$WORK/opt/finalize-minimal.sh" \
      "$WORK/usr/bin/qemu-aarch64-static"

echo "==> mksquashfs"
cleanup; trap - EXIT
# Same compressor/settings as the full build so the two are comparable.
# mksquashfs 4.6 没有 -f/-y，目标已存在时会退出：先删旧产物，避免交互式提问。
rm -f "$SQUASH"
mksquashfs "$WORK" "$SQUASH" \
    -comp zstd -Xcompression-level 19 -all-root -noappend \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" "mnt/*" "debootstrap/*" ".second-stage-done"

echo "OK: $SQUASH ($(du -h "$SQUASH" | cut -f1))"
