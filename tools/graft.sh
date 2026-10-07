#!/bin/sh
# tools/graft.sh — install the built Debian rootfs into a Podroid checkout.
#
#   ./tools/graft.sh /path/to/Podroid
#
# Copies out/debian-rootfs.squashfs into the checkout under the LEGACY asset
# name `alpine-rootfs.squashfs` so no Kotlin change is needed (referenced by
# PodroidApplication.kt:107, QemuEngine.kt:575, AvfEngine.kt:1027).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(dirname "$HERE")
SRC=${1:-}

[ -n "$SRC" ] || { echo "usage: $0 /path/to/Podroid" >&2; exit 2; }
[ -d "$SRC/app/src/main/assets" ] || { echo "FATAL: not a Podroid checkout: $SRC" >&2; exit 1; }
SQ=$PROJ/out/debian-rootfs.squashfs
[ -f "$SQ" ] || { echo "FATAL: $SQ missing — run ./build/build-rootfs.sh first" >&2; exit 1; }

ASSETS=$SRC/app/src/main/assets
cp "$SQ" "$ASSETS/alpine-rootfs.squashfs"
echo "OK: -> $ASSETS/alpine-rootfs.squashfs ($(du -h "$ASSETS/alpine-rootfs.squashfs" | cut -f1))"
echo
cat <<'EOF'
Next steps (in the Podroid checkout / app):
  1. ./build-all.sh apk deploy          # rebuild + install the APK
  2. In the app: Settings -> Reset VM   # MANDATORY: wipes the Alpine overlay
                                         # upper, otherwise Alpine files shadow Debian
  3. Start the VM, then verify:
       ./tools/boot-test.sh             # polls files/console.log for "Ready!"
     or watch the in-app terminal for the login prompt.
EOF
