#!/bin/sh
# build/build-native.sh — build the guest C binaries (hostd, vsock-agent,
# overlay-normalize) from the sibling Podroid checkout into native/staged/.
# They are plain musl/glibc-static-ish programs; building them under the host
# toolchain is fine (they run in the guest, statically linked).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(dirname "$HERE")
SRC=${1:-${PODROID_SRC:-$PROJ/../Podroid}}
STAGE=$PROJ/native/staged

[ -d "$SRC/build-rootfs/host-bridge" ] || {
    echo "FATAL: Podroid source not found at $SRC (set PODROID_SRC=...)" >&2; exit 1; }

command -v gcc >/dev/null || { echo "FATAL: gcc not installed" >&2; exit 1; }

mkdir -p "$STAGE"
for comp in host-bridge vsock-agent overlay-normalize; do
    echo "==> $comp"
    make -C "$SRC/build-rootfs/$comp" clean >/dev/null 2>&1 || true
    make -C "$SRC/build-rootfs/$comp" CC=gcc
    bin=$(ls -1 "$SRC/build-rootfs/$comp"/podroid-* 2>/dev/null | grep -v '\.\(o\|d\)$' | head -1)
    [ -n "$bin" ] || { echo "FATAL: no binary produced in $comp" >&2; exit 1; }
    cp "$bin" "$STAGE/"
done

# overlay-normalize's binary name is podroid-overlay-normalize — all three are
# plain `podroid-*` files so the loop above picks them up; verify explicitly:
for b in podroid-hostd podroid-vsock-agent podroid-overlay-normalize; do
    [ -x "$STAGE/$b" ] || { echo "FATAL: missing $STAGE/$b" >&2; exit 1; }
done
# static link keeps the guest free of a libc version dependency
for b in "$STAGE"/*; do
    file "$b" | grep -q "statically linked" || \
        echo "WARN: $(basename "$b") is not statically linked: $(file -b "$b")"
done
echo "OK: staged in $STAGE"
