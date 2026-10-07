#!/bin/sh
# build/rootfs-finalize.sh — runs INSIDE the arm64 rootfs (chroot / container).
# Shared by the docker and local debootstrap paths.
#
# Responsibilities:
#   1. copy the rootfs/ overlay (systemd units, helpers) into place
#   2. configure identity (hostname, root password 123), dropbear
#   3. enable units via OFFLINE SYMLINKS (systemctl enable is not reliable in a
#      build chroot; upstream build-rootfs.sh does the same for openrc runlevels)
#   4. mask units that would fight over the ttys / are VM-irrelevant
#   5. apply rootfs identity marker + system-version (Podroid migration anchor)
set -eu

OVERLAY_DIR="${OVERLAY_DIR:-/opt/podroid-rootfs-overlay}"
SYSVER="${SYSTEM_VERSION:-33}"
MARKER="debian-trixie-arm64"

log() { printf 'finalize: %s\n' "$*"; }

# ---------------------------------------------------------------- 1. overlay
if [ -d "$OVERLAY_DIR" ]; then
    # cp -a keeps exec bits and (later, in mksquashfs) xattrs.
    cp -a "$OVERLAY_DIR"/. /
    log "overlay copied from $OVERLAY_DIR"
fi

# ---------------------------------------------------------------- 2. identity
printf 'podroid\n' > /etc/hostname
printf '127.0.0.1\tlocalhost podroid\n' > /etc/hosts

# Root password = "123" (guest SSH contract: ssh root@<phone> -p 9922).
# Changed from upstream's "podroid" at the user's request (2026-10-07).
# chpasswd works in the arm64 chroot (both build paths run arm64 postinst);
# fall back to a pre-generated sha512 hash if it is provided.
if [ -n "${PODROID_ROOT_SHA512:-}" ]; then
    awk -v h="$PODROID_ROOT_SHA512" 'BEGIN{FS=":";OFS=":"} $1=="root"{$2=h} {print}' \
        /etc/shadow > /etc/shadow.tmp && mv /etc/shadow.tmp /etc/shadow
    chmod 640 /etc/shadow
    log "root shadow hash written from PODROID_ROOT_SHA512"
else
    printf 'root:123\n' | chpasswd
    log "root password set via chpasswd"
fi

# systemd-machine-id: leave empty so first boot generates one (persistent upper).
if [ -f /etc/machine-id ] && [ -s /etc/machine-id ]; then
    : > /etc/machine-id
fi
rm -f /var/lib/dbus/machine-id

# dropbear: password auth for root on :22 (upstream contract). Debian's unit
# reads /etc/default/dropbear; keep extra args empty (never pass -s).
cat > /etc/default/dropbear <<'EOF'
# Podroid: guest SSH server. Host side forwards 9922 -> 22 (implicit rule).
DROPBEAR_PORT=22
DROPBEAR_EXTRA_ARGS=
DROPBEAR_BANNER=
DROPBEAR_RECEIVE_WINDOW=65536
EOF

# ------------------------------------------------------- 3. enable the units
WANTS=/etc/systemd/system/multi-user.target.wants
mkdir -p "$WANTS"

# Core bring-up chain (order encoded in the units themselves).
ENABLED="
podroid-migrate.service
podroid-bootstrap.service
podroid-network.service
podroid-resize.service
podroid-hostd.service
podroid-vsock.service
podroid-downloads.service
podroid-xvnc.service
podroid-pulse.service
podroid-ready.service
"
# Getty: instantiate the template for both ttys (systemd wants-symlinks point
# at podroid-getty@.service and systemd derives the instance from the link name).
GETTY_TEMPLATE=podroid-getty@.service
GETTY_INSTANCES="hvc0 ttyS0"
# Stock services the contract relies on (present after packages.list install).
OPTIONAL="
dropbear.service
docker.service
lxc-net.service
dbus.service
"
for u in $ENABLED $OPTIONAL; do
    if [ -e "/etc/systemd/system/$u" ] || [ -e "/lib/systemd/system/$u" ]; then
        ln -sf "/etc/systemd/system/$u" "$WANTS/$u" 2>/dev/null || \
            ln -sf "/lib/systemd/system/$u" "$WANTS/$u"
        log "enabled $u"
    else
        log "WARN missing unit: $u"
    fi
done

# Getty instances (template must exist before we link).
if [ -e "/etc/systemd/system/$GETTY_TEMPLATE" ]; then
    for inst in $GETTY_INSTANCES; do
        ln -sf "/etc/systemd/system/$GETTY_TEMPLATE" "$WANTS/podroid-getty@$inst.service"
        log "enabled podroid-getty@$inst.service"
    done
else
    log "WARN missing unit: $GETTY_TEMPLATE"
fi

# systemd-networkd is not used (podroid-network owns the NIC); make sure the
# Debian default networking never races our static 10.0.2.15 config.
for u in systemd-networkd.service systemd-resolved.service getty@tty1.service \
         serial-getty@ttyAMA0.service serial-getty@hvc0.service; do
    ln -sf /dev/null "/etc/systemd/system/$u"
done
log "masked networkd/resolved/tty1/serial-getty units"

# The Debian dnsmasq package auto-enables a STANDALONE dnsmasq.service that
# grabs *:53; lxc-net then fails with "failed to create listening socket for
# 10.0.3.1: Address already in use". lxc-net runs its own dnsmasq instance, so
# drop the package service's wants-symlink (offline-safe systemctl disable).
if [ -L "$WANTS/dnsmasq.service" ] || [ -e "$WANTS/dnsmasq.service" ]; then
    rm -f "$WANTS/dnsmasq.service"
    log "disabled dnsmasq.service (lxc-net owns dnsmasq)"
fi

# default target
mkdir -p /etc/systemd/system
ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

# ------------------------------------------------------- 4. Podroid anchors
mkdir -p /etc/podroid /mnt/persist/.podroid 2>/dev/null || mkdir -p /etc/podroid
printf '%s\n' "$SYSVER" > /etc/podroid/system-version   # migration version anchor
printf '%s\n' "$MARKER"  > /etc/podroid/rootfs-id       # distro identity (Phase 7 guard)

# file capabilities for rootless helper (mksquashfs preserves xattrs:
# we deliberately do NOT pass -no-xattrs)
for b in /usr/bin/newuidmap /usr/bin/newgidmap; do
    [ -e "$b" ] && setcap cap_setuid+ep "$b" 2>/dev/null || true
    [ -e "$b" ] && setcap cap_setgid+ep "$b" 2>/dev/null || true
done

# ------------------------------------------------------- 5. sanity + cleanup
# Contract binaries (fail the build early instead of booting a broken image).
for b in /usr/local/bin/podroid-hostd \
         /usr/local/bin/podroid-vsock-agent \
         /usr/local/lib/podroid/podroid-bootstrap \
         /usr/local/lib/podroid/podroid-network \
         /usr/local/lib/podroid/podroid-ready \
         /usr/local/bin/podroid-getty \
         /usr/local/bin/podroid-resize; do
    [ -x "$b" ] || { echo "FATAL: missing or not executable: $b" >&2; exit 1; }
done

# /etc/resolv.conf must be a plain file: podroid-network rewrites it every boot
# (a systemd-resolved symlink would break the QEMU branch).
if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    printf 'nameserver 10.0.2.3\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi

# no ifupdown (podroid-network owns eth0); drop a stub if a package pulled it in
if [ -f /etc/network/interfaces ]; then
    printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
fi

apt-get clean || true
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/* /var/tmp/*
rm -f /opt/podroid-rootfs-overlay 2>/dev/null || true

log "done (system-version=$SYSVER, id=$MARKER)"
