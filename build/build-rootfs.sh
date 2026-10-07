#!/bin/sh
# build/build-rootfs.sh — entry point.
#
#   ./build/build-rootfs.sh --check     report which build path is available
#   ./build/build-rootfs.sh             auto: docker if usable, else local(root)
#   ./build/build-rootfs.sh docker      force docker buildx path
#   ./build/build-rootfs.sh local       force debootstrap path (root)
#   ... [--desktop] [--system-version N]
#
# Output: out/debian-rootfs.squashfs
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(dirname "$HERE")
OUT=$PROJ/out
SYSVER=${SYSTEM_VERSION:-33}
MODE=auto
DESKTOP=0

for a in "$@"; do
    case "$a" in
        --check) MODE=check ;;
        docker|local) MODE=$a ;;
        --desktop) DESKTOP=1 ;;
        --system-version) ;; # value handled below
        --system-version=*) SYSVER=${a#*=} ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) if [ "$PREV_ARG" = "--system-version" ]; then SYSVER=$a; fi ;;
    esac
    PREV_ARG=$a
done

have() { command -v "$1" >/dev/null 2>&1; }

docker_ok() {
    have docker || return 1
    docker info >/dev/null 2>&1 || return 1          # daemon reachable
    docker buildx version >/dev/null 2>&1 || return 1
    # arm64 emulation: binfmt qemu present either on host or inside docker
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && return 0
    docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 || return 1
    return 0
}

local_ok() {
    have debootstrap || return 1
    have mksquashfs  || return 1
    have qemu-aarch64-static || return 1
    [ "$(id -u)" -eq 0 ] || return 1                 # chroot/mount need root
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || return 1
    return 0
}

if [ "$MODE" = check ]; then
    echo "Podroid-Debian build environment check"
    echo "--------------------------------------"
    if docker_ok; then echo "[OK ] docker path: buildx + arm64 binfmt available"
    else echo "[NO ] docker path:"; docker info >/dev/null 2>&1 || echo "       - docker not installed / daemon not reachable (sudo apt install docker.io)"
         have docker || true
         [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || echo "       - arm64 binfmt missing (docker run --privileged --rm tonistiigi/binfmt --install arm64)"
    fi
    if local_ok; then echo "[OK ] local path: debootstrap + qemu-user-static + root"
    else
        echo "[NO ] local path:"
        have debootstrap   || echo "       - debootstrap missing (sudo apt install debootstrap)"
        have mksquashfs    || echo "       - mksquashfs missing (sudo apt install squashfs-tools)"
        have qemu-aarch64-static || echo "       - qemu-user-static missing (sudo apt install qemu-user-static)"
        [ "$(id -u)" -eq 0 ] || echo "       - needs root (run via sudo)"
        [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || echo "       - binfmt qemu-aarch64 not registered"
    fi
    echo "--------------------------------------"
    docker_ok || local_ok || { echo "RESULT: no usable build path (see PLAN.md Phase 2)"; exit 2; }
    echo "RESULT: ready"
    exit 0
fi

# ---- native binaries (needed by both paths) ------------------------------
if [ ! -x "$PROJ/native/staged/podroid-hostd" ]; then
    "$HERE/build-native.sh"
fi

mkdir -p "$OUT"

run_docker() {
    echo "==> docker buildx (arm64) SYSTEM_VERSION=$SYSVER"
    EXTRA=""
    [ "$DESKTOP" -eq 1 ] && echo "WARN: --desktop not yet wired into the docker path (see PLAN Phase 7); ignoring"
    docker buildx build -f "$HERE/Dockerfile.rootfs" --platform linux/arm64 \
        --build-arg "SYSTEM_VERSION=$SYSVER" \
        --output "type=local,dest=$OUT" "$PROJ"
    [ -f "$OUT/debian-rootfs.squashfs" ] || { echo "FATAL: build produced no squashfs" >&2; exit 1; }
}

run_local() {
    if [ "$DESKTOP" -eq 1 ]; then "$HERE/local-rootfs.sh" --desktop; else "$HERE/local-rootfs.sh"; fi
}

case "$MODE" in
    docker) docker_ok || { echo "FATAL: docker path unavailable (--check for details)" >&2; exit 1; }; run_docker ;;
    local)  local_ok  || { echo "FATAL: local path unavailable (--check for details)" >&2; exit 1; }; run_local ;;
    auto)
        if docker_ok; then run_docker
        elif [ "$(id -u)" -eq 0 ] && local_ok; then run_local
        else
            echo "FATAL: no usable build path. Run: ./build/build-rootfs.sh --check" >&2
            exit 1
        fi ;;
esac

echo
echo "OK: $OUT/debian-rootfs.squashfs ($(du -h "$OUT/debian-rootfs.squashfs" 2>/dev/null | cut -f1))"
echo "Next:"
echo "  ./tools/graft.sh /path/to/Podroid     # install into the APK assets"
echo "  In the Podroid app: Settings -> Reset VM   (wipe Alpine overlay upper)"
echo "  Then rebuild the APK: ./build-all.sh apk   (in the Podroid checkout)"
