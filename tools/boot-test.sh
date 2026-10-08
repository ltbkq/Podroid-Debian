#!/bin/sh
# tools/boot-test.sh — adb smoke test (adapted from upstream build-all.sh:run_boot_test).
#
#   ./tools/boot-test.sh [PKG]              # PKG=${1:-io.github.ltbkq.vmdroid.debug}
#   BOOT_TIMEOUT=120 ./tools/boot-test.sh   # poll budget (default 90s, §11.4 threshold)
#
# Starts the VM via the debug APK, polls files/console.log for the contract
# markers, then reports. Requires: adb + the debug package installed
# (./build-all.sh apk deploy in the app checkout).
#
# Parameterization (DESIGN §13.1 回归行 / R1: B-R1-8):
#   * package name comes from $1 with the VMDroid default;
#   * the script builds its OWN `adb forward tcp:9922 tcp:9922` for the guest
#     SSH probe — 9922/5900/4713 bind to the DEVICE loopback only (S7), so
#     without a forward every port probe would MISS regardless of VM health.
set -eu

PKG=${1:-io.github.ltbkq.vmdroid.debug}
TIMEOUT=${BOOT_TIMEOUT:-90}

die() { echo "FAIL: $*" >&2; exit 1; }

adb get-state >/dev/null 2>&1 || die "no adb device"

# Host-side forward for the guest SSH probe; drop any stale spec first so the
# call is idempotent across runs (a leftover forward to another device port
# would otherwise make this bind fail).
adb forward --remove tcp:9922 >/dev/null 2>&1 || true
adb forward tcp:9922 tcp:9922 >/dev/null || die "adb forward tcp:9922 tcp:9922 failed"

console() { adb exec-out run-as "$PKG" cat files/console.log 2>/dev/null; }

echo "==> launching VM (force-stop $PKG first)"
adb shell am force-stop "$PKG" || true
sleep 1
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null

echo "==> polling console.log for markers (timeout ${TIMEOUT}s)"
t=0
ready=0
while [ "$t" -lt "$TIMEOUT" ]; do
    if console | grep -q 'Ready!'; then ready=1; break; fi
    sleep 3; t=$((t + 3))
done

LOG=$(console || true)
if [ "$ready" -eq 1 ]; then
    echo "OK: 'Ready!' seen after ~${t}s"
else
    echo "---- console.log tail ----"
    echo "$LOG" | tail -30
    die "no 'Ready!' within ${TIMEOUT}s"
fi

echo "==> contract markers"
for m in 'Loading kernel modules' 'Network found' 'Almost ready'; do
    if echo "$LOG" | grep -q "$m"; then echo "OK  $m"; else echo "MISS $m"; fi
done

echo "==> guest SSH (host forward 9922)"
if timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/9922' 2>/dev/null; then
    echo "OK  port 9922 open"
else
    echo "MISS port 9922 closed (dropbear or the SSH forward is broken)"
fi

echo "==> X11 (5900) and audio (4713): forward then probe, loopback only"
for p in 5900 4713; do
    adb forward --remove tcp:$p >/dev/null 2>&1 || true
    adb forward tcp:$p tcp:$p >/dev/null 2>&1 || true
    if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null; then
        echo "OK  port $p open"
    else
        echo "MISS port $p closed"
    fi
done

echo
echo "done. Full log: adb exec-out run-as $PKG cat files/console.log"
