#!/bin/sh
# tools/boot-test.sh — adb smoke test (adapted from upstream build-all.sh:run_boot_test).
#
# Starts the VM via the debug APK, polls files/console.log for the contract
# markers, then reports. Requires: adb, the debug package installed
# (./build-all.sh apk deploy in the Podroid checkout).
set -eu

PKG=com.excp.podroid.debug
TIMEOUT=${BOOT_TIMEOUT:-90}

die() { echo "FAIL: $*" >&2; exit 1; }

adb get-state >/dev/null 2>&1 || die "no adb device"

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

echo "==> X11 forward (5900) and audio (4713), loopback only"
for p in 5900 4713; do
    if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null; then
        echo "OK  port $p open"
    else
        echo "MISS port $p closed"
    fi
done

echo
echo "done. Full log: adb exec-out run-as $PKG cat files/console.log"
