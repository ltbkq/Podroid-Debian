#!/bin/sh
# tests/test_dns.sh — regression test for podroid-network's resolver ordering.
# Port of upstream build-rootfs/tests/test_podroid_network_dns.sh: it sources
# the real script (functions only; main() is guarded) and asserts qemu_resolv_conf
# output. Runs on any host, no root, no network.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NET_SCRIPT=$HERE/../rootfs/usr/local/lib/podroid/podroid-network

[ -f "$NET_SCRIPT" ] || { echo "FAIL: $NET_SCRIPT not found" >&2; exit 1; }

# shellcheck disable=SC1090
. "$NET_SCRIPT"

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        echo "  expected: $(printf '%s' "$2" | tr '\n' '|')"
        echo "  actual:   $(printf '%s' "$3" | tr '\n' '|')"
        fail=1
    fi
}

E_DEFAULT='nameserver 10.0.2.3
nameserver 8.8.8.8
nameserver 1.1.1.1'

check "empty cmdline keeps 10.0.2.3 fallback" "$E_DEFAULT" "$(qemu_resolv_conf "")"

check "single device DNS first + public fallbacks" \
'nameserver 192.168.1.1
nameserver 8.8.8.8
nameserver 1.1.1.1' "$(qemu_resolv_conf '192.168.1.1')"

check "two device DNS entries, no public dupes" \
'nameserver 10.1.2.3
nameserver 10.4.5.6
nameserver 8.8.8.8' "$(qemu_resolv_conf '10.1.2.3,10.4.5.6,10.4.5.6')"

check "device DNS equal to 8.8.8.8 not duplicated" \
'nameserver 8.8.8.8
nameserver 1.1.1.1' "$(qemu_resolv_conf '8.8.8.8')"

# Injection attempts must be rejected as a whole (allowlist: [0-9.,]).
check "cmdline injection rejected" "$E_DEFAULT" \
    "$(qemu_resolv_conf '2001:db8::1,1.2.3.4;touch /tmp/podroid-dns')"

check "leading-zero octet rejected" "$E_DEFAULT" "$(qemu_resolv_conf '01.2.3.4')"

check "out-of-range octet rejected" "$E_DEFAULT" "$(qemu_resolv_conf '1.2.3.999')"

check "loopback / wildcard rejected" "$E_DEFAULT" "$(qemu_resolv_conf '127.0.0.1,0.0.0.0')"

# Only two device slots exist (DEVICE_DNS_1/2); a third entry is dropped and
# the 3rd line becomes the public fallback — matches upstream behavior.
check "third device DNS dropped, 3 nameserver cap" \
'nameserver 1.1.1.1
nameserver 2.2.2.2
nameserver 8.8.8.8' "$(qemu_resolv_conf '1.1.1.1,2.2.2.2,3.3.3.3')"

if [ "$fail" -eq 0 ]; then
    echo "PASS ($(grep -c '^check' "$0") cases)"
else
    echo "FAILURES"
    exit 1
fi
