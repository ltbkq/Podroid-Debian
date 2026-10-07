#!/bin/sh
# build/build-native.sh — build the guest C binaries (hostd, vsock-agent,
# overlay-normalize) from the sibling Podroid checkout into native/staged/.
# The GUEST is aarch64, so cross-compile with aarch64-linux-gnu-gcc whenever
# the build host is not arm64 (the first squashfs was baked with native x86_64
# binaries — they died with ENOEXEC/"Exec format error" in the guest).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(dirname "$HERE")
SRC=${1:-${PODROID_SRC:-$PROJ/../Podroid}}
STAGE=$PROJ/native/staged

[ -d "$SRC/build-rootfs/host-bridge" ] || {
    echo "FATAL: Podroid source not found at $SRC (set PODROID_SRC=...)" >&2; exit 1; }

case "$(uname -m)" in
    aarch64|arm64) CROSS_CC=${CROSS_CC:-gcc} ;;          # native arm64 host
    *)             CROSS_CC=${CROSS_CC:-aarch64-linux-gnu-gcc} ;;
esac
command -v "$CROSS_CC" >/dev/null || {
    echo "FATAL: $CROSS_CC not installed (sudo apt install gcc-aarch64-linux-gnu)" >&2
    exit 1; }
echo "==> CC=$CROSS_CC (host $(uname -m))"

# linux/vm_sockets.h (UAPI) references struct sockaddr / sa_family_t without
# including <sys/socket.h> itself; the sources include it alphabetically BEFORE
# sys/socket.h, which newer glibc/linux-libc-dev headers reject (cross headers
# hit this, the older native ones did not). Force-include instead of patching
# the upstream sources.
CC_CMD="$CROSS_CC -include sys/socket.h"

mkdir -p "$STAGE"
for comp in host-bridge vsock-agent overlay-normalize; do
    echo "==> $comp"
    make -C "$SRC/build-rootfs/$comp" clean >/dev/null 2>&1 || true
    make -C "$SRC/build-rootfs/$comp" CC="$CC_CMD"
    bin=$(ls -1 "$SRC/build-rootfs/$comp"/podroid-* 2>/dev/null | grep -v '\.\(o\|d\)$' | head -1)
    [ -n "$bin" ] || { echo "FATAL: no binary produced in $comp" >&2; exit 1; }
    cp "$bin" "$STAGE/"
done

# overlay-normalize's binary name is podroid-overlay-normalize — all three are
# plain `podroid-*` files so the loop above picks them up; verify explicitly:
for b in podroid-hostd podroid-vsock-agent podroid-overlay-normalize; do
    [ -x "$STAGE/$b" ] || { echo "FATAL: missing $STAGE/$b" >&2; exit 1; }
done
# static link keeps the guest free of a libc version dependency; the arch MUST
# be aarch64 (regression guard: an x86_64 build once shipped in squashfs v1).
for b in "$STAGE"/*; do
    desc=$(file -b "$b")
    echo "$desc" | grep -q "statically linked" || \
        echo "WARN: $(basename "$b") is not statically linked: $desc"
    echo "$desc" | grep -q "aarch64" || {
        echo "FATAL: $(basename "$b") is not aarch64: $desc" >&2; exit 1; }
done
echo "OK: staged in $STAGE (all aarch64 + static)"
