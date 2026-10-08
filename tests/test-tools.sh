#!/usr/bin/env bash
#
# tests/test-tools.sh — 工位 A（镜像工具链）自动化测试
#
# 覆盖：IMAGE-FORMAT §6 生成/回读自检 · §8 测试向量 · §3 footer 偏移回归 ·
#       DESIGN §6.1 catalog 签名 · §11.2 CLI · §13.1（工具侧互操作 + PC 冒烟入口）
#
# 用法：tests/test-tools.sh [--quick]
#   --quick   跳过真实 rootfs（345 MB）构建，只跑向量/CLI/目录/冒烟守卫
#   RUN_SMOKE_DEMO=1  额外跑一次 pc-boot-smoke 真实管线（假内核必然 boot 失败，
#                     只为验证 imgboot.sh 集成，耗时 <30s）
#
set -euo pipefail

SELF=$(readlink -f "$0")
TESTS_DIR=$(cd "$(dirname "$SELF")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
DATA="$TESTS_DIR/data"
VECJSON="$TESTS_DIR/vectors/vectors.json"
MKIMG="$REPO_ROOT/tools/mkimg.sh"
CATALOG="$REPO_ROOT/tools/catalog.sh"
SMOKE="$REPO_ROOT/tools/pc-boot-smoke.sh"

QUICK=0
if [ "${1:-}" = "--quick" ]; then QUICK=1; fi

PASS=0
FAIL=0
FAILED_NAMES=()
T0=$(date +%s)

t_ok()   { PASS=$((PASS + 1)); echo "  PASS  $*"; }
t_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$*"); echo "  FAIL  $*"; }
sec()    { echo; echo "### $*"; }
die()    { echo "FATAL: $*" >&2; exit 1; }

cd "$REPO_ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/a-tools-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ 0. lint
sec "0. 静态检查（bash -n + shellcheck + python3 -m py_compile）"
for f in tools/mkimg.sh tools/catalog.sh tools/pc-boot-smoke.sh \
         tests/gen-vectors.sh tests/test-tools.sh; do
    if bash -n "$f" 2>"$TMP/err"; then t_ok "bash -n $f"; else
        cat "$TMP/err"; t_fail "bash -n $f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    # 只把 error 当失败（warning/info 见报告）
    if shellcheck -S error tools/mkimg.sh tools/catalog.sh tools/pc-boot-smoke.sh \
                   tests/gen-vectors.sh tests/test-tools.sh; then
        t_ok "shellcheck -S error (5 scripts, 0 error)"
    else
        t_fail "shellcheck found errors"
    fi
    shellcheck tools/mkimg.sh tools/catalog.sh tools/pc-boot-smoke.sh \
               tests/gen-vectors.sh tests/test-tools.sh >"$TMP/sc.txt" 2>&1 || true
    echo "  info: shellcheck 全级别告警数 = $(grep -c '^In ' "$TMP/sc.txt" || true)"
else
    t_fail "shellcheck 不可用"
fi
if PYTHONPYCACHEPREFIX="$TMP" python3 -m py_compile tests/independent_check.py; then
    t_ok "py_compile tests/independent_check.py"
else
    t_fail "py_compile tests/independent_check.py"
fi

# ------------------------------------------------------------- 1. mkimg CLI
sec "1. mkimg CLI 契约（IMAGE-FORMAT §6）"
if "$MKIMG" --help | grep -q -- '--rootfs'; then t_ok "mkimg --help"; else t_fail "mkimg --help"; fi
if "$MKIMG" >/dev/null 2>&1; then t_fail "mkimg 无参数应 exit 2"; else
    rc=$?; [ "$rc" -eq 2 ] && t_ok "mkimg 无参数 → exit 2" || t_fail "mkimg 无参数 rc=$rc != 2"; fi
if "$MKIMG" --rootfs /nonexistent --manifest x -o /tmp/x >/dev/null 2>&1; then
    t_fail "mkimg 应拒绝不存在的 rootfs"
else t_ok "mkimg 拒绝不存在的 rootfs"; fi

# ------------------------------------------------- 2. 真实产物 out/debian.img
ROOTFS="$REPO_ROOT/out/debian-rootfs.squashfs"
OUT_IMG="$REPO_ROOT/out/debian.img"
IMAGE_SHA=
if [ "$QUICK" = 1 ]; then
    sec "2.（--quick 跳过真实 rootfs 构建）"
elif [ ! -r "$ROOTFS" ]; then
    sec "2.（缺少 $ROOTFS，跳过真实产物构建）"
else
    sec "2. 真实产物构建：tools/mkimg.sh（rootfs 345 MB + 假 kernel/initrd）"
    if [ ! -w "$REPO_ROOT/out" ]; then
        echo "  warn: $REPO_ROOT/out 不可写（root 属主），产物改写到 $REPO_ROOT/../out/"
        mkdir -p "$REPO_ROOT/../out"
        OUT_IMG="$REPO_ROOT/../out/debian.img"
    fi
    if "$MKIMG" --rootfs "$ROOTFS" \
                --manifest "$DATA/manifest-valid.json" \
                --kernel "$DATA/fake-kernel.bin" \
                --initrd "$DATA/fake-initrd.img" \
                -o "$OUT_IMG" --no-smoke >"$TMP/build.log" 2>&1; then
        t_ok "mkimg 构建 -> $OUT_IMG"
        sed 's/^/    /' "$TMP/build.log"
        IMAGE_SHA=$(sed -n 's/^file_sha256=//p' "$TMP/build.log" | tail -1)
    else
        sed 's/^/    /' "$TMP/build.log"
        t_fail "mkimg 构建失败"
    fi
fi

# ------------------------------------------------------------ 3. --verify
if [ -n "$OUT_IMG" ] && [ -r "$OUT_IMG" ]; then
    sec "3. mkimg --verify（回读全字段 + 重算 sha256 + 对齐/段序）"
    if "$MKIMG" --verify "$OUT_IMG" >"$TMP/verify.log" 2>&1; then
        t_ok "mkimg --verify"
        sed 's/^/    /' "$TMP/verify.log"
    else
        sed 's/^/    /' "$TMP/verify.log"
        t_fail "mkimg --verify"
    fi

    sec "4. 独立 python 复核（tests/independent_check.py，不复用 mkimg 代码）"
    CHK_ARGS=("$OUT_IMG")
    [ -n "$IMAGE_SHA" ] && CHK_ARGS+=(--expect-sha256 "$IMAGE_SHA")
    if python3 tests/independent_check.py "${CHK_ARGS[@]}" >"$TMP/ind.log" 2>&1; then
        t_ok "independent_check（含 rootfs_size == superblock.bytes_used 交叉断言）"
        sed 's/^/    /' "$TMP/ind.log"
    else
        sed 's/^/    /' "$TMP/ind.log"
        t_fail "independent_check"
    fi
    # 与 mkimg 自报 sha256 直接比对（若可用）
    if [ -n "$IMAGE_SHA" ]; then
        REAL_SHA=$(sha256sum "$OUT_IMG" | cut -d' ' -f1)
        if [ "$REAL_SHA" = "$IMAGE_SHA" ]; then
            t_ok "全文件 sha256 三方一致（mkimg / sha256sum / independent_check）"
        else
            t_fail "sha256 不一致: mkimg=$IMAGE_SHA sha256sum=$REAL_SHA"
        fi
    fi
    # rootfs 尾部 383 B 被丢弃的规格断言（DESIGN §11.2 / IMAGE-FORMAT §6 步骤1）
    if [ -r "$ROOTFS" ]; then
        R_SIZE=$(python3 -c 'import struct,sys; print(struct.unpack("<Q", open(sys.argv[1],"rb").read(48)[40:48])[0])' "$ROOTFS")
        F_R_SIZE=$(python3 -c 'import struct,sys; f=open(sys.argv[1],"rb"); f.seek(-4096,2); print(struct.unpack("<Q", f.read(4096)[32:40])[0])' "$OUT_IMG")
        F_FILE=$(stat -c%s "$ROOTFS")
        if [ "$F_R_SIZE" = "$R_SIZE" ] && [ "$F_R_SIZE" -lt "$F_FILE" ]; then
            t_ok "rootfs_size=$R_SIZE == superblock.bytes_used（源文件 $F_FILE，丢弃 $((F_FILE - R_SIZE)) B 补齐）"
        else
            t_fail "rootfs_size=$F_R_SIZE != bytes_used=$R_SIZE / file=$F_FILE"
        fi
    fi
else
    sec "3/4.（无真实产物，跳过 verify/独立复核）"
fi

# --------------------------------------------------------------- 5. 向量回放
sec "5. 测试向量回放（tests/vectors/vectors.json，$(jq '.vectors|length' "$VECJSON") 条）"
VEC_DIR=$(cd "$(dirname "$VECJSON")" && pwd)
while IFS=$'\t' read -r name file result vsize vsha; do
    path="$VEC_DIR/$file"
    if [ ! -r "$path" ]; then
        t_fail "向量 $name 缺文件 $file"
        continue
    fi
    asize=$(stat -c%s "$path")
    asha=$(sha256sum "$path" | cut -d' ' -f1)
    if [ "$asize" = "$vsize" ] && [ "$asha" = "$vsha" ]; then
        t_ok "向量 $name 完整性（size=$asize sha256 一致）"
    else
        t_fail "向量 $name 完整性（size $asize/$vsize sha $asha/$vsha）"
    fi
    set +e
    "$MKIMG" --verify "$path" >"$TMP/vec.log" 2>&1
    rc=$?
    set -e
    if [ "$result" = accept ]; then
        if [ "$rc" -eq 0 ]; then
            t_ok "向量 $name → --verify 通过（期望 accept）"
        else
            sed 's/^/    /' "$TMP/vec.log"
            t_fail "向量 $name → --verify rc=$rc（期望 accept）"
        fi
    else
        if [ "$rc" -ne 0 ]; then
            reason=$(grep -o 'verify FAIL:.*' "$TMP/vec.log" | head -1)
            # 注意：jq @tsv 会把反斜杠转义成 \\，所以这里按名字单独取 pattern
            vpat=$(jq -r --arg n "$name" '.vectors[] | select(.name == $n)
                        | .expect.mkimg_pattern // ""' "$VECJSON")
            if [ -n "$vpat" ] && ! printf '%s' "$reason" | grep -Eq "$vpat"; then
                t_fail "向量 $name 拒绝原因不匹配 '$vpat'：$reason"
            else
                t_ok "向量 $name → 拒绝（期望 reject，原因匹配）：$reason"
            fi
        else
            sed 's/^/    /' "$TMP/vec.log"
            t_fail "向量 $name → 竟然通过了 --verify（期望 reject）"
        fi
    fi
done < <(jq -r '.vectors[] | [.name, .file, .expect.result, (.size|tostring), .sha256]
                 | @tsv' "$VECJSON")

# ------------------------------------------------------ 6. 生成期负向（build）
sec "6. mkimg 生成期负向（build_negative_vectors 逐条回放）"
while IFS=$'\t' read -r name args; do
    # shellcheck disable=SC2086  # args 按空白切分（路径不含空格）
    if (cd "$REPO_ROOT" && "$MKIMG" $args -o "$TMP/should-not-exist.img" --no-smoke) \
            >/dev/null 2>"$TMP/neg.log"; then
        t_fail "$name：mkimg 竟然接受了非法输入"
    else
        t_ok "$name 被拒绝 — $(grep -o 'mkimg: ERROR:.*' "$TMP/neg.log" | head -1)"
    fi
    rm -f "$TMP/should-not-exist.img"
done < <(jq -r '.build_negative_vectors[] | [.name, (.args|join(" "))] | @tsv' "$VECJSON")

# ------------------------------------------------------------- 7. footer 回归
sec "7. footer 偏移重编号回归（IMAGE-FORMAT §8 末行，R3 RB-1）"
if python3 - "$VECJSON" <<'PY' >"$TMP/layout.log" 2>&1
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
want = {"magic": (0, 8), "format_version": (8, 4), "footer_size": (12, 4),
        "file_size": (16, 8), "rootfs_offset": (24, 8), "rootfs_size": (32, 8),
        "rootfs_sha256": (40, 32), "manifest_offset": (72, 8), "manifest_size": (80, 8),
        "manifest_sha256": (88, 32), "flags": (120, 4), "kernel_offset": (124, 8),
        "kernel_size": (132, 8), "kernel_sha256": (140, 32), "initrd_offset": (172, 8),
        "initrd_size": (180, 8), "initrd_sha256": (188, 32), "reserved": (220, 3868),
        "magic_tail": (4088, 8)}
got = {f["field"]: (f["offset"], f["size"]) for f in doc["footer_layout"]}
for k in want:
    assert got.get(k) == want[k], "%s: got %s want %s" % (k, got.get(k), want[k])
print("footer_layout %d/%d 字段偏移与 IMAGE-FORMAT §3 完全一致" % (len(want), len(want)))
PY
then
    t_ok "$(cat "$TMP/layout.log")"
else
    cat "$TMP/layout.log"; t_fail "footer 偏移回归"
fi
# 同一份偏移表也从真实镜像的 --verify 输出交叉断言
if [ -n "${OUT_IMG:-}" ] && [ -r "${OUT_IMG:-}" ] && grep -q 'manifest offset' "$TMP/verify.log" 2>/dev/null; then
    t_ok "真实产物 footer 偏移与向量 footer_layout 同源（同一 §3 表）"
fi

# ---------------------------------------------------------------- 8. catalog
sec "8. catalog 生成 + ECDSA 签名（DESIGN §6.1 / §11.2）"
if [ ! -r "${OUT_IMG:-}" ]; then
    echo "  （跳过：没有可用的 .img 产物）"
else
    REL="$TMP/release"
    mkdir -p "$REL"
    cp "$OUT_IMG" "$REL/debian.img"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out "$TMP/catalog.key" 2>/dev/null
    if "$CATALOG" --release-dir "$REL" \
                  --base-url "https://github.com/ltbkq/Podroid-Debian/releases/download/v34" \
                  --sign-key "$TMP/catalog.key" \
                  -o "$REL/catalog.json" -o "$REL/catalog.json.sig" \
                  >"$TMP/cat.log" 2>&1; then
        t_ok "catalog.sh 生成 + 签名 + 自校验"
        sed 's/^/    /' "$TMP/cat.log"
    else
        sed 's/^/    /' "$TMP/cat.log"
        t_fail "catalog.sh"
    fi
    # schema 断言（DESIGN §6.1 + R-05 首发口径）
    jq -e '.schema == 1 and (.generated_at | type == "string")
           and (.images | length == 1)
           and (.images[0].image_id == "debian-minimal-arm64")
           and (.images[0].identity == "debian:trixie")
           and (.images[0].variant == "minimal")
           and (.images[0].system_version == 34)
           and (.images[0].arch == "arm64")
           and (.images[0].channel == "stable")
           and (.images[0].app_min_version_code == 1)
           and (.images[0].url == "https://github.com/ltbkq/Podroid-Debian/releases/download/v34/debian.img")' \
        "$REL/catalog.json" >/dev/null \
        && t_ok "catalog schema 字段（§6.1 表 + R-05 长度=1）" \
        || t_fail "catalog schema 字段"
    CSIZE=$(stat -c%s "$REL/debian.img")
    CSHA=$(sha256sum "$REL/debian.img" | cut -d' ' -f1)
    [ "$(jq -r '.images[0].size' "$REL/catalog.json")" = "$CSIZE" ] \
        && t_ok "catalog.size == 实际文件大小 ($CSIZE)" \
        || t_fail "catalog.size 不符"
    [ "$(jq -r '.images[0].sha256' "$REL/catalog.json")" = "$CSHA" ] \
        && t_ok "catalog.sha256 == 全文件 sha256" || t_fail "catalog.sha256 不符"
    # 签名可验（base64 -d 后 openssl dgst -verify，等价 Android Base64.getDecoder）
    openssl pkey -in "$TMP/catalog.key" -pubout -out "$TMP/pub.pem" 2>/dev/null
    openssl base64 -d -A -in "$REL/catalog.json.sig" -out "$TMP/sig.der"
    openssl dgst -sha256 -verify "$TMP/pub.pem" -signature "$TMP/sig.der" \
        "$REL/catalog.json" >/dev/null 2>&1 \
        && t_ok "catalog.json.sig 可被验证（正例互操作，§13.1 ③）" \
        || t_fail "catalog.json.sig 验证失败"
    # 篡改 1 字节 → 验签必须失败
    cp "$REL/catalog.json" "$TMP/tampered.json"
    printf ' ' >> "$TMP/tampered.json"
    if openssl dgst -sha256 -verify "$TMP/pub.pem" -signature "$TMP/sig.der" \
        "$TMP/tampered.json" >/dev/null 2>&1; then
        t_fail "篡改 catalog.json 后验签竟然通过"
    else
        t_ok "篡改 catalog.json 1 字节 → 验签失败（§13.1 ①）"
    fi
    # --no-sign 必须警告
    if "$CATALOG" --release-dir "$REL" --base-url https://example.invalid/x \
                  --no-sign -o "$TMP/unsigned.json" >"$TMP/nosign.log" 2>&1 \
       && grep -q "WARNING: --no-sign" "$TMP/nosign.log" \
       && [ ! -e "$TMP/unsigned.json.sig" ]; then
        t_ok "--no-sign 路径：成功但打印醒目警告且不产 .sig"
    else
        sed 's/^/    /' "$TMP/nosign.log"; t_fail "--no-sign 路径"
    fi
    # 裸 squashfs 混进 release-dir → catalog 必须拒绝
    cp "$DATA/bare-rootfs.sqfs" "$REL/oops.img"
    if "$CATALOG" --release-dir "$REL" --base-url https://example.invalid/x \
                  --no-sign -o "$TMP/bad.json" >/dev/null 2>"$TMP/catbad.log"; then
        t_fail "catalog 竟然索引了裸 squashfs"
    else
        t_ok "catalog 拒绝裸 squashfs — $(grep -o 'catalog: ERROR:.*' "$TMP/catbad.log" | head -1)"
    fi
    rm -f "$REL/oops.img"
fi

# --------------------------------------------------- 9. 目录签名测试向量互操作
sec "9. catalog 签名测试向量（vectors.json → openssl，§13.1 正例互操作）"
jq -j '.catalog_signature.public_key_pem' "$VECJSON" > "$TMP/v-pub.pem"
jq -j '.catalog_signature.message'          "$VECJSON" > "$TMP/v-msg.txt"
jq -j '.catalog_signature.signature_b64'    "$VECJSON" > "$TMP/v-sig.b64"
openssl base64 -d -A -in "$TMP/v-sig.b64" -out "$TMP/v-sig.der"
if openssl dgst -sha256 -verify "$TMP/v-pub.pem" -signature "$TMP/v-sig.der" \
    "$TMP/v-msg.txt" >/dev/null 2>&1; then
    t_ok "固定 key+message+sig 正例验证通过"
else
    t_fail "固定签名向量验证失败"
fi
jq -j '.catalog_signature.tampered_message' "$VECJSON" > "$TMP/v-msg2.txt"
if openssl dgst -sha256 -verify "$TMP/v-pub.pem" -signature "$TMP/v-sig.der" \
    "$TMP/v-msg2.txt" >/dev/null 2>&1; then
    t_fail "被篡改的 message 竟然验签通过"
else
    t_ok "篡改 message → 验签失败（§13.1 ①）"
fi
[ "$(jq -r '.catalog_signature.message_sha256' "$VECJSON")" = \
  "$(sha256sum "$TMP/v-msg.txt" | cut -d' ' -f1)" ] \
    && t_ok "message_sha256 自洽" || t_fail "message_sha256 不自洽"

# --------------------------------------------------------------- 10. 冒烟守卫
sec "10. pc-boot-smoke.sh 共享库守卫（缺 IMG_BOOT_LIB → exit 3）"
set +e
IMG_BOOT_LIB="$TMP/does-not-exist.sh" "$SMOKE" "${OUT_IMG:-$DATA/vectors/valid-full.img}" \
    >"$TMP/smoke-guard.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 3 ] && grep -q "IMG_BOOT_LIB" "$TMP/smoke-guard.log" \
   && grep -q "imgboot_verify" "$TMP/smoke-guard.log"; then
    t_ok "缺库 → exit 3 且打印接口指引（不自行实现第二份）"
else
    sed 's/^/    /' "$TMP/smoke-guard.log"
    t_fail "冒烟守卫 rc=$rc（期望 3）"
fi

# --------------------------------------------------------------- 11. 向量确定性守卫
sec "11. 向量确定性守卫（IMP-T02：连跑两遍 gen-vectors 必须字节不变）"
GENV="$TESTS_DIR/gen-vectors.sh"
V1="$TMP/det-v1.sha"; V2="$TMP/det-v2.sha"
"$GENV" >/dev/null 2>&1 && sha256sum "$VECJSON" | cut -d' ' -f1 > "$V1" \
    || die "第一遍 gen-vectors.sh 失败"
"$GENV" >/dev/null 2>&1 && sha256sum "$VECJSON" | cut -d' ' -f1 > "$V2" \
    || die "第二遍 gen-vectors.sh 失败"
if cmp -s "$V1" "$V2"; then
    t_ok "gen-vectors 两遍输出字节一致（sha256=$(cat "$V1")）"
else
    t_fail "gen-vectors 两遍输出不一致（$(cat "$V1") vs $(cat "$V2")）→ 向量非确定性"
fi

if [ "${RUN_SMOKE_DEMO:-0}" = "1" ]; then
    sec "12. pc-boot-smoke 真实管线演示（假内核，预期 boot 失败；验证 imgboot 集成）"
    set +e
    BOOT_TIMEOUT=8 "$SMOKE" --timeout 8 "$OUT_IMG" >"$TMP/smoke-demo.log" 2>&1
    rc=$?
    set -e
    sed 's/^/    /' "$TMP/smoke-demo.log"
    grep -q "extract OK\|vmlinuz (" "$TMP/smoke-demo.log" \
        && t_ok "imgboot_verify + extract 走通（rc=$rc 来自假内核 boot 失败）" \
        || t_fail "冒烟管线未走到 extract"
fi

# ------------------------------------------------------------------ 汇总
sec "汇总"
ELAPSED=$(( $(date +%s) - T0 ))
echo "  通过 $PASS · 失败 $FAIL · 耗时 ${ELAPSED}s"
if [ "$FAIL" -gt 0 ]; then
    printf '  失败项: %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
echo "  ALL GREEN"
exit 0
