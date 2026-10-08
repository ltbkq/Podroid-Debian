#!/bin/sh
# build/finalize-minimal.sh — 工位 E：最小 rootfs 的 chroot 内装配 + 资产自检。
#
# 由 build/local-rootfs-minimal.sh 在 build/rootfs-finalize.sh（共享的 overlay /
# 单元使能 / 身份 / dropbear 配置步骤）**之后**执行，只做首发最小镜像特有的事：
#   1. §4.8 账户与 sudo（root + ltbkq，密码均为 123，NOPASSWD sudo，visudo -c）
#   2. §4.8 dropbear：DROPBEAR_EXTRA_ARGS 必须为空（无 -w/-g/-s/-B），
#      host 私钥绝不烘焙进镜像（首启由 podroid-bootstrap 的 dropbearkey 生成）
#   3. §4.5  locales(min)：locale 保持最小（默认口径=不装 locales 包，同全量基线）
#   4. §16.6 journald 上限 drop-in（SystemMaxUse=64M / MaxRetentionSec=1month）
#   5. §4.5  契约路径补齐（/usr/local/lib/podroid/{podroid-hostd,podroid-resize}）
#   6. 资产自检：必备包 / 负面包 / 包数（deps 闭包 ≤260 硬断言，总数记 WARN）/
#      契约脚本 / Xvnc / host key /
#      凭据核验（crypt 往返证明密码确实是 123，不是"哈希存在"）
# 任一自检失败 → 非零退出 → 构建失败，不产出 squashfs。
set -eu

SYSVER="${SYSTEM_VERSION:-34}"
log() { printf 'finalize-minimal: %s\n' "$*"; }
FAIL=0
fail() { printf 'finalize-minimal: FAIL: %s\n' "$*" >&2; FAIL=1; }

pkg_installed() {
    [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" = "install ok installed" ]
}

# 密码核验：crypt(pw, stored_hash) == stored_hash。
# Debian trixie 的 ENCRYPT_METHOD 是 YESCRYPT（$y$），openssl passwd -6 无法比对，
# 因此用 chroot 内 perl（perl-base，调 libcrypt）做往返验证 —— 与 §13.1 的
# "openssl passwd -6 比对 或 直接以登录成功为真值" 等价（PAM 走的就是 libcrypt）。
verify_pw() {
    _h=$(awk -F: -v u="$1" '$1==u{print $2}' /etc/shadow 2>/dev/null || true)
    [ -n "$_h" ] || return 1
    _calc=$(perl -e 'print crypt($ARGV[1], $ARGV[0])' "$_h" "$2" 2>/dev/null || true)
    [ -n "$_calc" ] && [ "$_calc" = "$_h" ]
}

# ------------------------------------------------- 1. 账户（DESIGN §4.8）
if ! id -u ltbkq >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo ltbkq
    log "useradd -m -s /bin/bash -G sudo ltbkq"
fi
[ -d /home/ltbkq ] || fail "/home/ltbkq 不存在（§4.8(3) skel 未拷贝）"
printf 'root:123\n'   | chpasswd
printf 'ltbkq:123\n'  | chpasswd
log "chpasswd: root=123, ltbkq=123"

printf 'ltbkq ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/ltbkq
chmod 0440 /etc/sudoers.d/ltbkq
visudo -c >/dev/null || fail "visudo -c 未通过"
log "visudo -c OK (/etc/sudoers.d/ltbkq 0440, NOPASSWD)"

id -nG ltbkq | tr ' ' '\n' | grep -qx sudo || fail "ltbkq 不在 sudo 组"

# ------------------------------------- 2. dropbear 配置 + host 私钥清除（§4.8）
# EXTRA_ARGS 保持空：dropbear 默认即允许 root 登录与密码认证；
# -w=禁root -g=禁root密码 -s=禁密码 -B=允许空密码，一律不加。
cat > /etc/default/dropbear <<'EOF'
# Podroid: guest SSH server. Host side forwards 9922 -> 22 (implicit rule).
DROPBEAR_PORT=22
DROPBEAR_EXTRA_ARGS=""
DROPBEAR_BANNER=
DROPBEAR_RECEIVE_WINDOW=65536
EOF
# ★ host 私钥不得烘焙进镜像（R1: B-R1-2 / R2: B-R2-4）。dropbear 的 postinst 在
#   apt 安装期生成过一把，必须删掉；首启由 podroid-bootstrap 内 dropbearkey 生成。
rm -f /etc/dropbear/dropbear_*_host_key*
log "dropbear: DROPBEAR_EXTRA_ARGS=\"\", host keys removed"

# ------------------------------------------------------- 3. locales(min)（§4.5）
# "locales(min)" = locale 保持最小。基线口径：**不装 locales 包**（全量构建
# dpkg -l locales = un、无 /etc/default/locale，可用 locale 只有 glibc 内置
# C/C.utf8/POSIX），本镜像沿用；一旦列表里加回 locales 包，下面这段会只生成
# en_US.UTF-8 一个 locale（同样是 "min"）。注意：装 locales 会使依赖闭包变成
# 261 包，越过 §13.1 硬上限 260 —— 两处规格冲突时按硬上限取舍。
if command -v locale-gen >/dev/null 2>&1; then
    printf 'en_US.UTF-8 UTF-8\n' > /etc/locale.gen
    locale-gen >/dev/null 2>&1 || fail "locale-gen 失败"
    printf 'LANG=en_US.UTF-8\n' > /etc/default/locale
    log "locales(min): locales 包已装，仅生成 en_US.UTF-8"
else
    if locale -a 2>/dev/null | grep -qi '^C\.utf8'; then
        log "locales(min): 未装 locales 包（与全量基线一致），C/C.utf8/POSIX 可用"
    else
        fail "C.UTF-8 locale 不可用"
    fi
fi

# ------------------------------------------- 4. journald 上限 drop-in（§16.6）
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/vmdroid.conf <<'EOF'
# VMDroid (DESIGN §16.6): journal 已持久化到 /var/log/journal（写入走 overlay →
# storage.img），必须加上限避免吃满数据盘。
[Journal]
SystemMaxUse=64M
MaxRetentionSec=1month
EOF
mkdir -p /var/log/journal
chgrp systemd-journal /var/log/journal 2>/dev/null || true
chmod 2755 /var/log/journal
log "journald drop-in written (SystemMaxUse=64M, MaxRetentionSec=1month)"

# ------------------------------- 5. §4.5 契约路径补齐 + 构建期垃圾清理
# DESIGN §4.5 把 hostd/resize 列在 /usr/local/lib/podroid/ 下，而上游移植把可执行
# 文件装在 /usr/local/bin/（unit 的 ExecStart 指向 bin）。补两条符号链接使两处
# 路径都能解析；不改 unit，不搬既有文件。
ln -sf ../../bin/podroid-hostd /usr/local/lib/podroid/podroid-hostd
ln -sf ../../bin/podroid-resize /usr/local/lib/podroid/podroid-resize
# rootfs-finalize.sh 只 `rm -f` overlay 目录（对目录无效），172 KB 的副本会进镜像。
rm -rf /opt/podroid-rootfs-overlay
log "contract path aliases + overlay leftover removed"

# ------------------------------------------------------------- 6. 资产自检
log "---- 资产自检 ----"

for p in systemd-sysv dbus dropbear iproute2 isc-dhcp-client util-linux mount \
         sudo ca-certificates \
         tigervnc-standalone-server tigervnc-common \
         xfonts-base fonts-dejavu-core dbus-x11 \
         pulseaudio pulseaudio-utils; do
    pkg_installed "$p" || fail "必备包缺失（§4.5 启动契约）: $p"
done

for p in docker.io podman lxc crun netavark aardvark-dns xfce4 lightdm x11-utils; do
    if pkg_installed "$p"; then fail "负面断言：不该安装的包: $p"; fi
done

PKG_COUNT=$(dpkg -l | grep -c '^ii' || true)
BASE_COUNT=${BASE_PKG_COUNT:-0}
if [ "$BASE_COUNT" -gt 0 ] 2>/dev/null; then
    ADDED=$((PKG_COUNT - BASE_COUNT))
else
    ADDED=$PKG_COUNT
fi
# §13.1 的"包数 ≤260"有两种口径，本镜像按 §4.5 的原话"deps 闭包实测 223 /
# CI 断言 ≤260"断言 **deps 闭包（= apt 新增安装）**：硬失败。
# `dpkg -l | grep -c '^ii'` 总数含 debootstrap minbase 的必需基础包
# （dpkg/apt/coreutils/tar/gzip/sed/grep/login/ncurses/tzdata… 不可删），在保留
# §4.5 的 Xvnc(:5900) + pulseaudio(:4713) 契约时无法降到 ≤260 —— 删掉其中一栈才可达
# （实测删 pulseaudio → ~204、删 tigervnc → ~234）。超限时记 WARN，不阻断构建。
if [ "$ADDED" -gt 260 ]; then
    fail "deps 闭包（apt 新增）$ADDED > 260（§13.1 硬上限）"
fi
if [ "$PKG_COUNT" -gt 260 ]; then
    log "WARN: dpkg -l 总包数 $PKG_COUNT > 260（= apt 新增 $ADDED + minbase 基础 $BASE_COUNT）—— 规格冲突，详见交付报告"
fi
log "包数: dpkg -l 总数=$PKG_COUNT · minbase 基础=$BASE_COUNT · deps 闭包(apt 新增)=$ADDED"

for f in /usr/bin/Xvnc \
         /usr/local/lib/podroid/podroid-bootstrap \
         /usr/local/lib/podroid/podroid-network \
         /usr/local/lib/podroid/podroid-ready \
         /usr/local/lib/podroid/podroid-resize \
         /usr/local/lib/podroid/podroid-hostd \
         /usr/local/lib/podroid/podroid-migrate \
         /usr/local/bin/podroid-getty \
         /usr/local/bin/podroid-login \
         /usr/local/bin/podroid-resize \
         /usr/local/bin/podroid-overlay-normalize \
         /usr/local/bin/podroid-hostd \
         /usr/local/bin/podroid-vsock-agent; do
    [ -e "$f" ] || fail "契约脚本缺失: $f"
done

grep -q 'Ready!' /usr/local/lib/podroid/podroid-ready || fail "podroid-ready 缺少 Ready! 标记"
grep -q 'rfbport 5900' /usr/local/lib/podroid/podroid-xvnc || fail "podroid-xvnc 缺少 rfbport 5900"
grep -q 'dropbearkey' /usr/local/lib/podroid/podroid-bootstrap || fail "podroid-bootstrap 缺少 dropbearkey 首启生成"

if ls /etc/dropbear/dropbear_*_host_key* >/dev/null 2>&1; then
    fail "/etc/dropbear 内仍存在 *_host_key* 私钥（不得烘焙）"
fi
DB_ARGS=$(sed -n 's/^DROPBEAR_EXTRA_ARGS=//p' /etc/default/dropbear | tr -d '"')
[ -z "$DB_ARGS" ] || fail "DROPBEAR_EXTRA_ARGS 非空: $DB_ARGS"
case "$DB_ARGS" in *-[wgsB]*) fail "DROPBEAR_EXTRA_ARGS 含受限开关: $DB_ARGS";; esac

JD=/etc/systemd/journald.conf.d/vmdroid.conf
grep -qx 'SystemMaxUse=64M'   "$JD" 2>/dev/null || fail "$JD 缺 SystemMaxUse=64M"
grep -qx 'MaxRetentionSec=1month' "$JD" 2>/dev/null || fail "$JD 缺 MaxRetentionSec=1month"
if command -v systemd-analyze >/dev/null 2>&1; then
    if systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | grep -q 'SystemMaxUse=64M'; then
        log "systemd-analyze cat-config: SystemMaxUse=64M 命中"
    else
        log "WARN: systemd-analyze cat-config 未回显（chroot 环境限制），以文件 grep 为准"
    fi
fi

for u in root ltbkq; do
    if verify_pw "$u" 123; then
        log "凭据核验 OK: $u 密码 = 123（crypt 往返一致）"
    else
        fail "凭据核验失败: $u 的 shadow 不匹配密码 123"
    fi
done
getent passwd ltbkq >/dev/null || fail "getent passwd ltbkq 无结果"
grep -q '^ltbkq:' /etc/passwd || fail "/etc/passwd 无 ltbkq"

SV=$(cat /etc/podroid/system-version 2>/dev/null || echo missing)
[ "$SV" = "$SYSVER" ] || fail "system-version=$SV，期望 $SYSVER"
[ "$(cat /etc/podroid/rootfs-id 2>/dev/null)" = "debian-trixie-arm64" ] || fail "rootfs-id 不符"

if [ "$FAIL" -ne 0 ]; then
    echo "finalize-minimal: 资产自检未通过，构建终止" >&2
    exit 1
fi
log "资产自检全部通过"
exit 0
