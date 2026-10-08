#!/usr/bin/env bash
#
# tools/pc-boot-smoke.sh — CI smoke test for a packaged .img (R-16 / DESIGN §11.4, §13.1)
#
#   boot the .img in qemu-system-aarch64 and assert, within 90 s:
#     1) the guest console prints "Ready!"
#     2) `ssh -p 9922` to the guest answers (password login, DESIGN §4.8)
#
# Extraction / verification / qemu argv / readiness polling are NOT implemented
# here: they come from the single shared library owned by the vmdroid repo
# (tools/lib/imgboot.sh — also used by pc-run.sh --smoke, DESIGN §11.2 "单一来源").
#
# usage: tools/pc-boot-smoke.sh [--timeout N] [--work DIR] [--keep] <image.img>
# env  : IMG_BOOT_LIB   path to imgboot.sh (default: ../vmdroid/tools/lib/imgboot.sh
#                       relative to this repository)
#        BOOT_TIMEOUT   seconds, default 90 (DESIGN §11.4 / §13.1)
#        SMOKE_SSH_PORT default 9922
#        SMOKE_SSH_USER default ltbkq · SMOKE_SSH_PASS default 123
#        SMOKE_STORAGE  storage.img path (default: <work>/storage.img, created 4G ext4)
#
# exit: 0 pass · 1 assertion failed · 2 usage · 3 shared tooling missing
#
set -euo pipefail

SELF=$(readlink -f "$0")
TOOLS_DIR=$(cd "$(dirname "$SELF")" && pwd)
REPO_ROOT=$(cd "$TOOLS_DIR/.." && pwd)

die() { echo "pc-boot-smoke: FAIL: $*" >&2; exit 1; }
note() { echo "pc-boot-smoke: $*"; }

usage() {
    cat <<'EOF'
usage: tools/pc-boot-smoke.sh [--timeout N] [--work DIR] [--keep] <image.img>

  asserts, within the timeout (default 90 s):
    - imgboot_verify/extract succeeded (footer + payload sha256)
    - guest console contains "Ready!"
    - ssh -p 9922 ltbkq@127.0.0.1 answers with password 123

env: IMG_BOOT_LIB (required library, see below), BOOT_TIMEOUT=90,
     SMOKE_SSH_PORT=9922, SMOKE_SSH_USER=ltbkq, SMOKE_SSH_PASS=123,
     SMOKE_STORAGE=<path>, KEEP_WORK=1

exit: 0 pass · 1 assertion failed · 2 usage · 3 tooling missing
EOF
}

# ------------------------------------------------------- shared library guard
IMG_BOOT_LIB=${IMG_BOOT_LIB:-$REPO_ROOT/../vmdroid/tools/lib/imgboot.sh}
if [ ! -r "$IMG_BOOT_LIB" ]; then
    cat >&2 <<EOF
pc-boot-smoke: ERROR: 缺 IMG_BOOT_LIB —— 共享启动库不可读:
    $IMG_BOOT_LIB

  这个文件由 vmdroid 仓库提供（工位 C，tools/lib/imgboot.sh），必须提供：
      imgboot_verify      <img>              # footer 校验, exit 0/1
      imgboot_extract     <img> <dir>        # 提取 <dir>/vmlinuz + <dir>/initrd.img
      imgboot_qemu_argv   <img> <storage>    # 打印 qemu 命令行
      imgboot_wait_ready  <console.log> <s>  # 轮询 Ready!, exit 0/1
  pc-boot-smoke.sh 刻意不再实现第二份（避免与 pc-run.sh 漂移，DESIGN §11.2 单一来源）。

  修复方法（二选一）：
      export IMG_BOOT_LIB=/path/to/vmdroid/tools/lib/imgboot.sh
    或把 vmdroid 仓库放在本仓库同级目录: $REPO_ROOT/../vmdroid/tools/lib/imgboot.sh
EOF
    exit 3
fi
# shellcheck source=/dev/null
. "$IMG_BOOT_LIB"
for fn in imgboot_verify imgboot_extract imgboot_qemu_argv imgboot_wait_ready; do
    if ! declare -F "$fn" >/dev/null; then
        echo "pc-boot-smoke: ERROR: $IMG_BOOT_LIB does not define $fn()" >&2
        exit 3
    fi
done
note "imgboot library: $IMG_BOOT_LIB"
# ------------------------------------------------------------------- options
TIMEOUT=${BOOT_TIMEOUT:-90}
SSH_PORT=${SMOKE_SSH_PORT:-9922}
SSH_USER=${SMOKE_SSH_USER:-ltbkq}
SSH_PASS=${SMOKE_SSH_PASS:-123}
WORK=
KEEP=${KEEP_WORK:-0}
IMG=

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
        --work)    [ $# -ge 2 ] || die "--work needs a value";    WORK=$2;    shift 2 ;;
        --keep)    KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; break ;;
        -*)        echo "pc-boot-smoke: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)         [ -z "$IMG" ] || die "unexpected argument: $1"; IMG=$1; shift ;;
    esac
done
[ -n "$IMG" ] || { usage >&2; exit 2; }
[ -r "$IMG" ] || die "cannot read image: $IMG"
command -v qemu-system-aarch64 >/dev/null 2>&1 \
    || die "qemu-system-aarch64 not installed (apt install qemu-system-arm)"

if [ -z "$WORK" ]; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/pc-boot-smoke.XXXXXX")
    OWN_WORK=1
else
    mkdir -p "$WORK"
    OWN_WORK=0
fi

QEMU_PID=
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    rc=$?
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "$OWN_WORK" = 1 ] && [ "$KEEP" = 1 ]; then
        note "work dir kept: $WORK"
    elif [ "$OWN_WORK" = 1 ] && [ "$rc" -eq 0 ]; then
        rm -rf "$WORK"
    elif [ "$rc" -ne 0 ]; then
        note "work dir kept for diagnosis: $WORK"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------- 1. verify + extract (R-16)
# imgboot_* failure paths call `exit 1` inside the shared library, so every
# call runs in a subshell here to keep our diagnostics and cleanup trap alive.
note "step 1/4: imgboot_verify $IMG"
if ! ( imgboot_verify "$IMG" ); then
    die "imgboot_verify failed (footer/sha256 check) — see message above"
fi

EXTRACT="$WORK/extract"
RUN_DIR="$WORK/run"
export IMGBOOT_EXTRACT_DIR=$EXTRACT
export IMGBOOT_RUN_DIR=$RUN_DIR
if type imgboot_prepare_run_dir >/dev/null 2>&1; then
    ( imgboot_prepare_run_dir "$RUN_DIR" ) || die "imgboot_prepare_run_dir failed"
else
    mkdir -p "$RUN_DIR"
fi

note "step 2/4: imgboot_extract -> $EXTRACT"
if ! ( imgboot_extract "$IMG" "$EXTRACT" ); then
    die "imgboot_extract failed (kernel/initrd payload) — see message above"
fi
[ -s "$EXTRACT/vmlinuz" ]    || die "imgboot_extract produced no $EXTRACT/vmlinuz"
[ -s "$EXTRACT/initrd.img" ] || die "imgboot_extract produced no $EXTRACT/initrd.img"
note "kernel=$(stat -c%s "$EXTRACT/vmlinuz") bytes, initrd=$(stat -c%s "$EXTRACT/initrd.img") bytes"

# --------------------------------------------------------------- 2. storage vda
STORAGE=${SMOKE_STORAGE:-$WORK/storage.img}
if type imgboot_storage_init >/dev/null 2>&1; then
    note "step 3/4: imgboot_storage_init $STORAGE ${SMOKE_STORAGE_GB:-4}G"
    if ! ( imgboot_storage_init "$STORAGE" "${SMOKE_STORAGE_GB:-4}" ); then
        die "imgboot_storage_init failed"
    fi
else
    note "step 3/4: storage (local fallback: truncate 4G + mkfs.ext4) -> $STORAGE"
    if [ ! -s "$STORAGE" ]; then
        command -v truncate >/dev/null 2>&1 || die "truncate not available"
        command -v mkfs.ext4 >/dev/null 2>&1 || die "mkfs.ext4 not available (e2fsprogs)"
        truncate -s 4G "$STORAGE"
        mkfs.ext4 -F -q "$STORAGE" >/dev/null || die "mkfs.ext4 failed on $STORAGE"
    fi
fi

# ------------------------------------------------------------------- 3. qemu up
QEMU_BIN=${QEMU_BIN:-qemu-system-aarch64}
ARGV=$(imgboot_qemu_argv "$IMG" "$STORAGE") || die "imgboot_qemu_argv failed"
[ -n "$ARGV" ] || die "imgboot_qemu_argv printed nothing"
note "qemu argv: $ARGV"

CONSOLE="$WORK/console.log"
: > "$CONSOLE"
case "$ARGV" in
    qemu*|*"qemu-system-aarch64"*) ;;
    *) ARGV="$QEMU_BIN $ARGV" ;;   # library printed bare args -> prepend the binary
esac

HAS_SERIAL=0
HAS_DISPLAY=0
# imgboot_qemu_argv 输出的是 shell 转义过的单行命令（'-serial' 'mon:stdio'），
# 匹配前先去掉引号，否则会误判成“没有 -display/-serial”而重复追加。
ARGV_PLAIN=$(printf '%s' "$ARGV" | tr -d "'\"")
case " $ARGV_PLAIN " in *" -serial "*)  HAS_SERIAL=1  ;; esac
case " $ARGV_PLAIN " in *" -display "*) HAS_DISPLAY=1 ;; esac

EXTRA_STR=""
if [ "$HAS_DISPLAY" = 0 ]; then
    note "note: qemu argv has no -display, adding '-display none' (DESIGN §11.4)"
    EXTRA_STR="$EXTRA_STR $(printf '%q' -display) $(printf '%q' none)"
fi
if [ "$HAS_SERIAL" = 0 ]; then
    # no serial in the library argv -> capture ttyAMA0 ourselves so that
    # "Ready!" has somewhere to land; stdout of qemu goes to a sibling file.
    note "note: qemu argv has no -serial, adding '-serial file:$CONSOLE'"
    EXTRA_STR="$EXTRA_STR $(printf '%q' -serial) $(printf '%q' "file:$CONSOLE")"
    QEMU_STDOUT="$WORK/qemu.stdout.log"
else
    QEMU_STDOUT="$CONSOLE"
fi

note "step 4/4: boot (timeout ${TIMEOUT}s), console -> $CONSOLE"
# shellcheck disable=SC2086,SC2089
eval "$ARGV $EXTRA_STR >\"\$QEMU_STDOUT\" 2>&1 &"
QEMU_PID=$!
note "qemu pid $QEMU_PID"
sleep 1
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    set +e; wait "$QEMU_PID"; QRC=$?; set -e
    die "qemu exited immediately (rc=$QRC); argv: $ARGV${EXTRA_STR}"
fi

set +e
# subshell: imgboot_wait_ready aborts with `exit 1` on timeout
( imgboot_wait_ready "$CONSOLE" "$TIMEOUT" "$QEMU_PID" )
READY_RC=$?
set -e

if [ "$READY_RC" -ne 0 ]; then
    echo "---- console.log tail ----" >&2
    tail -40 "$CONSOLE" >&2 || true
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        set +e; wait "$QEMU_PID" 2>/dev/null; QRC=$?; set -e
        echo "---- qemu is gone (exit status $QRC), stdout tail ----" >&2
        tail -20 "$QEMU_STDOUT" >&2 || true
    fi
    die "no 'Ready!' within ${TIMEOUT}s"
fi
note "OK: 'Ready!' seen within ${TIMEOUT}s"

# ------------------------------------------------------------- 4. ssh 探活
if command -v sshpass >/dev/null 2>&1; then
    note "ssh probe: sshpass -p <pw> ssh -p $SSH_PORT $SSH_USER@127.0.0.1"
    LOGIN_OUT=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o BatchMode=no \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p "$SSH_PORT" "$SSH_USER@127.0.0.1" 'echo SMOKE_LOGIN_OK' 2>/dev/null) || true
    case "$LOGIN_OUT" in
        *SMOKE_LOGIN_OK*) note "OK: ssh login as $SSH_USER (pw $SSH_PASS)" ;;
        *) die "ssh login failed on port $SSH_PORT as $SSH_USER" ;;
    esac
else
    note "sshpass not installed -> TCP liveness probe only on port $SSH_PORT"
    if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null; then
        note "OK: port $SSH_PORT open (login not exercised: install sshpass for the full R-16 assert)"
    else
        die "port $SSH_PORT closed (dropbear or hostfwd is broken)"
    fi
fi

note "PASS: Ready! + ssh:$SSH_PORT within ${TIMEOUT}s (R-16)"
exit 0
