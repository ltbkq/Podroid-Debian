#!/usr/bin/env bash
#
# tests/gen-vectors.sh — generate the interoperability test vectors
#
#   tests/data/            fake payloads, bare squashfs, manifests, vector images
#   tests/vectors/vectors.json   expectations for the Kotlin VmdImageCodec
#                                (vmdroid side) and for shell-side checks here
#
# Vectors are built with tools/mkimg.sh (so they prove the real generator) and
# the expectations are then computed by an INDEPENDENT reader in this script.
# Layout/field offsets follow IMAGE-FORMAT.md v1.0 (§2 §3 §8).
#
# Idempotent: re-running overwrites everything below tests/data/vectors/.
#
set -euo pipefail

SELF=$(readlink -f "$0")
TESTS_DIR=$(cd "$(dirname "$SELF")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
DATA="$TESTS_DIR/data"
IMGD="$DATA/vectors"
VECJSON="$TESTS_DIR/vectors/vectors.json"
MKIMG="$REPO_ROOT/tools/mkimg.sh"

die() { echo "gen-vectors: ERROR: $*" >&2; exit 1; }
note() { echo "gen-vectors: $*"; }

[ -x "$MKIMG" ] || die "missing $MKIMG"
mkdir -p "$DATA" "$IMGD" "$(dirname "$VECJSON")"

# ---------------------------------------------------------------- 1. payloads
note "1/5 fake payloads (arm64 Image magic 'ARM\\x64' @0x38, ~2 MiB each)"
python3 - "$DATA" <<'PY'
import os, struct, sys
d = sys.argv[1]

# fake arm64 Image: header per Documentation/arm64/boot.rst — "ARM\x64" magic at
# 0x38 (DESIGN / IMAGE-FORMAT), image_size at 0x10 (QEMU rejects a bogus size),
# deterministic non-zero payload so any byte-copy error is detectable.
k = bytearray(2 * 1024 * 1024)
for i in range(0, len(k), 4):
    struct.pack_into("<I", k, i, (i * 2654435761) & 0xFFFFFFFF)
struct.pack_into("<Q", k, 0x08, 0x80000)        # text_offset
struct.pack_into("<Q", k, 0x10, len(k))         # image_size
struct.pack_into("<Q", k, 0x18, 0)              # flags
k[0x38:0x3c] = b"ARM\x64"
struct.pack_into("<I", k, 0x3c, 0)              # res5 (PE COFF offset)
open(os.path.join(d, "fake-kernel.bin"), "wb").write(bytes(k))

i_ = bytearray(2 * 1024 * 1024)
for off in range(0, len(i_), 4):
    struct.pack_into("<I", i_, off, (off * 40503) & 0xFFFFFFFF)
open(os.path.join(d, "fake-initrd.img"), "wb").write(bytes(i_))
print("  fake-kernel.bin=%d fake-initrd.img=%d" % (len(k), len(i_)))
PY

# ---------------------------------------------------------------- 2. squashfs
BARE="$DATA/bare-rootfs.sqfs"
note "2/5 bare squashfs -> $BARE (size must exceed 8192 for the N4 vector)"
SQSRC=$(mktemp -d)
trap 'rm -rf "$SQSRC"' EXIT
mkdir -p "$SQSRC/etc" "$SQSRC/usr/local/bin" "$SQSRC/etc/dropbear"
printf 'root:x:0:0:root:/root:/bin/bash\nltbkq:x:1000:1000::/home/ltbkq:/bin/bash\n' > "$SQSRC/etc/passwd"
printf 'vmdroid test rootfs (vectors) — IMAGE-FORMAT §8 bare-squashfs vector\n' \
    > "$SQSRC/etc/issue"
# 确定性 payload（IMP-T02：/dev/urandom 使 rootfs_sha256/file_sha256 每次重跑全变，
# 测试向量失去回归价值）。用 SHA-256 链生成不可压缩的确定性字节：跨 Python 版本
# 稳定、且不会被 zstd 压成 4 KiB 导致"bare squashfs too small"。
python3 - "$SQSRC/usr/local/bin/payload" <<'PY'
import hashlib, sys
chunks = [hashlib.sha256(("vmdroid-vector-payload:%d" % i).encode()).digest()
          for i in range((8192 + 31) // 32)]
open(sys.argv[1], "wb").write(b"".join(chunks)[:8192])
PY
chmod 755 "$SQSRC/usr/local/bin/payload"
mksquashfs "$SQSRC" "$BARE" -comp zstd -noappend -no-xattrs -no-progress -quiet \
    -mkfs-time 0 -all-time 0 -processors 1 >/dev/null
BARE_SIZE=$(stat -c%s "$BARE")
[ "$BARE_SIZE" -gt 8192 ] || die "bare squashfs too small ($BARE_SIZE)"
note "  bare-rootfs.sqfs=$BARE_SIZE bytes"

# a deliberately tiny kernel (mkimg must refuse payloads < 1 MiB)
python3 - "$DATA" <<'PY'
import os, sys
open(os.path.join(sys.argv[1], "too-small-kernel.bin"), "wb").write(b"tiny" * 1024)
PY

# --------------------------------------------------------------- 3. manifests
note "3/5 manifests"
MANIFEST_VALID="$DATA/manifest-valid.json"
cat > "$MANIFEST_VALID" <<'EOF'
{
  "format": "vmdroid-system-image",
  "format_version": 1,
  "image": {
    "id": "debian-minimal-arm64",
    "display_name": "Debian 13 (trixie) · 最小化",
    "identity": "debian:trixie",
    "variant": "minimal",
    "version": "2026.10.0-r1",
    "system_version": 34,
    "arch": "arm64",
    "distro": { "name": "debian", "release": "trixie", "init": "systemd" },
    "created_at": "2026-10-07T00:00:00Z",
    "source": "https://github.com/ltbkq/Podroid-Debian",
    "license": "GPL-2.0-or-later"
  },
  "contract": {
    "version": 1,
    "markers": ["Loading kernel modules...", "Network found",
                "Starting SSH...", "Almost ready...", "Ready!"],
    "ttys": { "hvc0": "login", "hvc1": "resize",
              "hvc2": "host-bridge", "ttyAMA0": "console" },
    "kernel": { "builtin_only": true, "min": "6.0", "max": "7.99" }
  },
  "capabilities": {
    "ssh": true,
    "x11": true,
    "desktop": false,
    "containers": false,
    "desktop_profile": false,
    "downloads_share": true,
    "usb_passthrough_host": true
  },
  "accounts": {
    "ssh": [
      { "user": "root",  "password": "123", "sudo": false },
      { "user": "ltbkq", "password": "123", "sudo": true }
    ],
    "default_user": "ltbkq",
    "ssh_port": 22
  },
  "app": { "min_version_code": 1 },
  "boot": {
    "machine": "virt",
    "cpu": "max",
    "append": "console=ttyAMA0 mitigations=off",
    "drives": { "vda": "storage.img(rw,ext4)", "vdb": "<self>(ro,squashfs)" }
  }
}
EOF

python3 - "$MANIFEST_VALID" "$DATA" <<'PY'
import json, os, sys
src, data = sys.argv[1], sys.argv[2]
base = json.load(open(src, encoding="utf-8"))

def save(name, mut):
    m = json.loads(json.dumps(base, ensure_ascii=False))
    mut(m)
    with open(os.path.join(data, name), "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False, indent=2)
        f.write("\n")

save("manifest-arch-x86_64.json",   lambda m: m["image"].__setitem__("arch", "x86_64"))
save("manifest-ssh-false.json",     lambda m: m["capabilities"].__setitem__("ssh", False))
save("manifest-ssh-port-2222.json", lambda m: m["accounts"].__setitem__("ssh_port", 2222))
save("manifest-bad-image-id.json",  lambda m: m["image"].__setitem__("id", "Debian-Minimal-ARM64"))
save("manifest-format-wrong.json",  lambda m: m.__setitem__("format", "Xmdroid-system-image"))
print("  wrote 5 invalid manifests (each must make mkimg fail)")
PY

# ------------------------------------------------------------- 4. mkimg builds
note "4/5 building positive images with tools/mkimg.sh (--no-smoke: fake payload)"
"$MKIMG" --rootfs "$BARE" --manifest "$MANIFEST_VALID" \
         --kernel "$DATA/fake-kernel.bin" --initrd "$DATA/fake-initrd.img" \
         -o "$IMGD/valid-full.img" --no-smoke >/dev/null || die "valid-full build failed"
"$MKIMG" --rootfs "$BARE" --manifest "$MANIFEST_VALID" \
         -o "$IMGD/valid-min.img" --no-smoke >/dev/null || die "valid-min build failed"
note "  valid-full.img=$(stat -c%s "$IMGD/valid-full.img") bytes (flags=0x3)"
note "  valid-min.img=$(stat -c%s "$IMGD/valid-min.img") bytes (flags=0x0)"

note "4b/5 asserting mkimg REFUSES invalid input (IMAGE-FORMAT §4 / §8)"
NEG_LOG=$(mktemp); NEG_TSV=$(mktemp)
trap 'rm -rf "$SQSRC" "$NEG_LOG" "$NEG_TSV"' EXIT

# name | 描述 | mkimg 参数（相对仓库根；-o 由执行者补）
BUILD_NEGATIVES=(
 'mkimg-arch-x86_64|arch != arm64|--rootfs tests/data/bare-rootfs.sqfs --manifest tests/data/manifest-arch-x86_64.json'
 'mkimg-ssh-false|capabilities.ssh == false|--rootfs tests/data/bare-rootfs.sqfs --manifest tests/data/manifest-ssh-false.json'
 'mkimg-ssh-port-2222|accounts.ssh_port != 22|--rootfs tests/data/bare-rootfs.sqfs --manifest tests/data/manifest-ssh-port-2222.json'
 'mkimg-bad-image-id|image.id 不匹配 ^[a-z0-9][a-z0-9._-]{0,63}$|--rootfs tests/data/bare-rootfs.sqfs --manifest tests/data/manifest-bad-image-id.json'
 'mkimg-format-wrong|manifest.format != vmdroid-system-image|--rootfs tests/data/bare-rootfs.sqfs --manifest tests/data/manifest-format-wrong.json'
 'mkimg-rootfs-not-squashfs|rootfs 不是 squashfs|--rootfs tests/data/manifest-valid.json --manifest tests/data/manifest-valid.json'
 'mkimg-kernel-too-small|kernel payload < 1 MiB|--rootfs tests/data/bare-rootfs.sqfs --manifest tests/data/manifest-valid.json --kernel tests/data/too-small-kernel.bin'
)
: > "$NEG_TSV"
for spec in "${BUILD_NEGATIVES[@]}"; do
    name=${spec%%|*}; rest=${spec#*|}; desc=${rest%%|*}; args=${rest#*|}
    # shellcheck disable=SC2086  # 参数按空白切分（路径不含空格）
    if (cd "$REPO_ROOT" && "$MKIMG" $args -o "$IMGD/.should-not-exist.img" --no-smoke) \
            >/dev/null 2>"$NEG_LOG"; then
        cat "$NEG_LOG" >&2
        die "mkimg should have rejected: $name ($desc)"
    fi
    note "  rejected as expected: $name — $(grep -o 'mkimg: ERROR:.*' "$NEG_LOG" | head -1)"
    printf '%s\t%s\n' "$name" "$args" >> "$NEG_TSV"
done
rm -f "$IMGD/.should-not-exist.img"

# ------------------------------------------- 5. derive negatives + expectations
# catalog 签名测试向量：固定 key/message/sig 已提交（tests/vectors/catalog-test-*）。
# IMP-T02：openssl ECDSA 每次用随机 nonce，签名无法逐字节复现 → 签一次冻结入库，
# 之后每次生成只读取不重签，保证 vectors.json 字节级确定性。
VECDIR="$TESTS_DIR/vectors"
KEY_PEM="$VECDIR/catalog-test-key.pem"
SIG_B64="$VECDIR/catalog-test-sig.b64"
MSG_TXT="$VECDIR/catalog-test-message.txt"
for f in "$KEY_PEM" "$SIG_B64" "$MSG_TXT"; do
    [ -f "$f" ] || die "missing committed signature vector: $f"
done
# 自检：冻结的签名必须能验证过冻结的 message + key（防提交时被改坏）
openssl dgst -sha256 -verify \
    <(openssl pkey -in "$KEY_PEM" -pubout) \
    -signature <(openssl base64 -A -d < "$SIG_B64") \
    "$MSG_TXT" >/dev/null 2>&1 || die "committed catalog-test-sig.b64 does not verify"
note "4c/5 catalog signature vectors (fixed, committed): $KEY_PEM"

note "5/5 deriving negative vectors and writing $(basename "$VECJSON")"
python3 - "$DATA" "$IMGD" "$VECJSON" "$NEG_TSV" "$VECDIR" <<'PY'
import hashlib, json, os, struct, sys

DATA, IMGD, VECJSON, NEGT, VECDIR = sys.argv[1:6]
MAGIC = b"VMDIMG01"
FOOTER = 4096
MIB = 1 << 20

# IMAGE-FORMAT §3 frozen offsets (seed removed 2026-10-08; R3 renumbering)
LAYOUT = [
    ("magic",           0,    8,   "bytes",  "VMDIMG01"),
    ("format_version",  8,    4,   "u32le",  1),
    ("footer_size",     12,   4,   "u32le",  4096),
    ("file_size",       16,   8,   "u64le",  None),
    ("rootfs_offset",   24,   8,   "u64le",  0),
    ("rootfs_size",     32,   8,   "u64le",  None),
    ("rootfs_sha256",   40,   32,  "bytes32", None),
    ("manifest_offset", 72,   8,   "u64le",  None),
    ("manifest_size",   80,   8,   "u64le",  None),
    ("manifest_sha256", 88,   32,  "bytes32", None),
    ("flags",           120,  4,   "u32le",  None),
    ("kernel_offset",   124,  8,   "u64le",  None),
    ("kernel_size",     132,  8,   "u64le",  None),
    ("kernel_sha256",   140,  32,  "bytes32", None),
    ("initrd_offset",   172,  8,   "u64le",  None),
    ("initrd_size",     180,  8,   "u64le",  None),
    ("initrd_sha256",   188,  32,  "bytes32", None),
    ("reserved",        220,  3868, "zero",  None),
    ("magic_tail",      4088, 8,   "bytes",  "VMDIMG01"),
]


def die(msg):
    sys.stderr.write("gen-vectors: ERROR: %s\n" % msg)
    sys.exit(1)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    with open(path, "rb") as f:
        return bytearray(f.read())


def write_sparse(path, buf):
    """Zero runs are not written to disk (fixtures stay physically small;
    bytes on read-back are identical)."""
    with open(path, "wb") as f:
        i, n = 0, len(buf)
        while i < n:
            if buf[i] == 0:
                i += 1
                continue
            j = i
            while j < n and buf[j] != 0:
                j += 1
            f.seek(i)
            f.write(buf[i:j])
            i = j
        f.truncate(n)


def fields(buf):
    n = len(buf)
    ft = buf[n - FOOTER:]
    if bytes(ft[0:8]) != MAGIC or bytes(ft[4088:4096]) != MAGIC:
        die("internal: base image lost its magic")
    out = {}
    for name, off, size, typ, _ in LAYOUT:
        out[name] = bytes(ft[off:off + size])
    return out


def u64(b): return struct.unpack("<Q", b)[0]
def u32(b): return struct.unpack("<I", b)[0]


def fbase(buf):
    """文件内 footer 起点：IMAGE-FORMAT §3 的 footer 字段偏移都要加这个基址。"""
    return len(buf) - FOOTER


def rewrite_manifest(buf, mutate, new_size_hook=None):
    """Apply a semantic change to the embedded manifest and keep the footer
    self-consistent (manifest_size + manifest_sha256), so the rejection can
    only come from the *content*, not from the sha check."""
    f = fields(buf)
    m_off = u64(f["manifest_offset"])
    m_size = u64(f["manifest_size"])
    footer_off = len(buf) - FOOTER
    man = json.loads(bytes(buf[m_off:m_off + m_size]).decode("utf-8"))
    mutate(man)
    blob = (json.dumps(man, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if m_off + len(blob) > footer_off:
        die("internal: rewritten manifest collides with footer")
    end = max(m_off + len(blob), m_off + m_size)
    buf[m_off:end] = b"\0" * (end - m_off)
    buf[m_off:m_off + len(blob)] = blob
    fb = fbase(buf)
    struct.pack_into("<Q", buf, fb + 80, len(blob))            # manifest_size
    buf[fb + 88:fb + 120] = hashlib.sha256(blob).digest()      # manifest_sha256
    if new_size_hook:
        new_size_hook(len(blob))
    return buf


def expectations(buf, deep=True):
    """Independent reader: every footer field, segment, sha256, alignment."""
    n = len(buf)
    f = fields(buf)
    if u64(f["file_size"]) != n:
        die("internal: file_size mismatch on a vector")
    r_off, r_size = u64(f["rootfs_offset"]), u64(f["rootfs_size"])
    k_off, k_size = u64(f["kernel_offset"]), u64(f["kernel_size"])
    i_off, i_size = u64(f["initrd_offset"]), u64(f["initrd_size"])
    m_off, m_size = u64(f["manifest_offset"]), u64(f["manifest_size"])
    flags = u32(f["flags"])
    segs = {"rootfs": (r_off, r_size), "manifest": (m_off, m_size)}
    if flags & 1:
        segs["kernel"] = (k_off, k_size)
    if flags & 2:
        segs["initrd"] = (i_off, i_size)
    out_segs = {}
    for name, (off, size) in sorted(segs.items()):
        out_segs[name] = {
            "offset": off,
            "size": size,
            "sha256": sha(bytes(buf[off:off + size])),
        }
    out_segs["footer"] = {"offset": n - FOOTER, "size": FOOTER}
    footer_off = n - FOOTER
    align_ok = (m_off % MIB == 0 and footer_off % 4096 == 0
                and (not (flags & 1) or k_off % MIB == 0)
                and (not (flags & 2) or i_off % MIB == 0))
    if not align_ok:
        die("internal: vector alignment is wrong")
    res = {
        "result": "accept",
        "file_size": n,
        "flags": flags,
        "segments": out_segs,
        "file_sha256": sha(bytes(buf)),
    }
    return res


def reject(name, base_file, buf, stage, reason, bootguard, rule, note_txt=None,
           patches=None, mk_re=None):
    e = {"result": "reject", "stage": stage, "reason": reason,
         "bootGuard": bootguard, "rule": rule}
    if mk_re:
        e["mkimg_pattern"] = mk_re
    if note_txt:
        e["note"] = note_txt
    v = {"name": name, "file": os.path.join("..", "data", "vectors", name + ".img"),
         "derived_from": base_file, "patches": patches or [],
         "size": len(buf), "sha256": sha(bytes(buf)), "expect": e}
    write_sparse(os.path.join(IMGD, name + ".img"), buf)
    return v


def accept(name, base_file, buf, rule, extra=None):
    e = expectations(buf)
    e["rule"] = rule
    if extra:
        e.update(extra)
    v = {"name": name, "file": os.path.join("..", "data", "vectors", name + ".img"),
         "derived_from": base_file, "patches": [],
         "size": len(buf), "sha256": e["file_sha256"], "expect": e}
    write_sparse(os.path.join(IMGD, name + ".img"), buf)
    return v


vectors = []

# ---- positive -------------------------------------------------------------
full = read(os.path.join(IMGD, "valid-full.img"))
mini = read(os.path.join(IMGD, "valid-min.img"))
vectors.append(accept("valid-full", None, full,
                      "IMAGE-FORMAT §2 布局 + §3 footer 全字段 + §8 第1/2行",
                      {"description": "rootfs+kernel+initrd+manifest，flags==0x3，"
                                      "kernel/initrd 偏移 1 MiB 对齐且与源文件逐字节一致"}))
vectors.append(accept("valid-min", None, mini,
                      "IMAGE-FORMAT §8 第1行（合法最小镜像）",
                      {"description": "rootfs+manifest，无 kernel/initrd，flags==0"}))

# ---- footer / structure rejections ---------------------------------------
b = read(os.path.join(IMGD, "valid-min.img")); struct.pack_into("<I", b, fbase(b) + 120, 0x4)
vectors.append(reject("unknown-flags-bit2", "valid-min", b, "footer",
                      "FORMAT_UNSUPPORTED", "FORMAT_UNSUPPORTED",
                      "IMAGE-FORMAT §3 解析规则2：flags 合法掩码 0x3（bit2 保留必须为 0）",
                      "flags = 0x4（bit2 置位；合法掩码 0x3）",
                      [{"offset": 120, "hex": "04000000"}], mk_re='unknown flags'))

b = read(os.path.join(IMGD, "valid-min.img")); b = b[:-1]
vectors.append(reject("truncated-1byte", "valid-min", b, "footer",
                      "NOT_AN_IMAGE", "NOT_AN_IMAGE",
                      "IMAGE-FORMAT §5：截断必须拒绝（§8 第4行）",
                      "注意：截断 1 字节使 footer 读取窗口左移 1 字节 → 双 magic 先失败，"
                      "reason 因此是 NOT_AN_IMAGE 而非 TRUNCATED（见规格问题登记）",
                      [{"truncate": "size-1"}], mk_re='bad magic'))

b = read(os.path.join(IMGD, "valid-min.img"))
struct.pack_into("<Q", b, fbase(b) + 16, len(b) + 1)
vectors.append(reject("file-size-mismatch", "valid-min", b, "footer",
                      "TRUNCATED", "CORRUPT",
                      "IMAGE-FORMAT §3 解析规则3：footer.file_size != 实际大小",
                      "footer.file_size 被 +1（footer 双 magic 完好，故能走到该分支）",
                      [{"offset": 16, "hex_from_u64": "file_size+1"}], mk_re='footer\\.file_size'))

b = read(os.path.join(IMGD, "valid-min.img")); b[len(b) - 4096:] = b"\0" * 4096
vectors.append(reject("footer-overwritten", "valid-min", b, "footer",
                      "NOT_AN_IMAGE", "NOT_AN_IMAGE",
                      "IMAGE-FORMAT §5：尾部 4 KiB 覆写 → 双 magic 失败（§8 第3行）",
                      "最后 4096 字节全零（同时覆盖 magic 与 magic_tail）",
                      [{"offset": "size-4096", "hex": "00 * 4096"}], mk_re='bad magic'))

b = read(os.path.join(IMGD, "valid-min.img")); struct.pack_into("<I", b, fbase(b) + 8, 2)
vectors.append(reject("format-version-2", "valid-min", b, "footer",
                      "FORMAT_UNSUPPORTED", "FORMAT_UNSUPPORTED",
                      "IMAGE-FORMAT §3 解析规则2：format_version > 1（§8 第9行）",
                      None, [{"offset": 8, "hex": "02000000"}], mk_re='format_version'))

b = read(os.path.join(IMGD, "valid-min.img")); struct.pack_into("<I", b, fbase(b) + 120, 0x1)
vectors.append(reject("flags-kernel-mismatch", "valid-min", b, "footer",
                      "CORRUPT", "CORRUPT",
                      "IMAGE-FORMAT §3 解析规则4：bit0 置位但 kernel_size == 0（§8 第11行）",
                      None, [{"offset": 120, "hex": "01000000"}], mk_re='flags bit0 vs kernel_size'))

b = read(os.path.join(IMGD, "valid-min.img"))
limit = len(b) - 4096
struct.pack_into("<Q", b, fbase(b) + 72, limit - 16)          # manifest_offset + size 越界
vectors.append(reject("manifest-out-of-range", "valid-min", b, "footer",
                      "CORRUPT", "CORRUPT",
                      "IMAGE-FORMAT §3 解析规则5：manifest_offset+manifest_size > file_size-4096",
                      None, [{"offset": 72, "hex_from_u64": "file_size-4096-16"}], mk_re='out of range'))

b = read(os.path.join(IMGD, "valid-min.img"))
struct.pack_into("<Q", b, fbase(b) + 72, 8)                   # 早于 rootfs 末尾 → 段序/重叠
vectors.append(reject("manifest-overlap", "valid-min", b, "footer",
                      "CORRUPT", "CORRUPT",
                      "IMAGE-FORMAT §3 解析规则5：manifest_offset < rootfs 末尾（重叠/乱序）",
                      None, [{"offset": 72, "hex_from_u64": "8"}], mk_re='overlap/order'))

bare = read(os.path.join(DATA, "bare-rootfs.sqfs"))
v = {"name": "bare-squashfs",
     "file": os.path.join("..", "data", "bare-rootfs.sqfs"),
     "derived_from": None, "patches": [], "size": len(bare),
     "sha256": sha(bytes(bare)),
     "expect": {"result": "reject", "stage": "footer", "reason": "NOT_AN_IMAGE",
                "bootGuard": "NOT_AN_IMAGE",
                "rule": "IMAGE-FORMAT §1 目标5 / §7 矩阵（N4）：裸 squashfs 一律拒绝并提示封装",
                "mkimg_pattern": "bad magic",
                "note": "offset 0 是 hsqs superblock、无 VMDIMG01 footer；"
                        "提示信息应包含 mkimg.sh"}}
vectors.append(v)

z = bytearray(16384)
z[0:4] = b"PK\x03\x04"
v = {"name": "zip-as-img", "file": os.path.join("..", "data", "vectors", "zip-as-img.img"),
     "derived_from": None, "patches": [{"offset": 0, "hex": "504b0304"}],
     "size": len(z), "sha256": sha(bytes(z)),
     "expect": {"result": "reject", "stage": "footer", "reason": "NOT_AN_IMAGE",
                "bootGuard": "NOT_AN_IMAGE",
                "rule": "IMAGE-FORMAT §8 末行：扩展名 .img 但内容是 zip → 以 footer 魔数为准",
                "mkimg_pattern": "bad magic",
                "note": "16 KiB，开头 PK\\x03\\x04，尾部全零"}}
write_sparse(os.path.join(IMGD, "zip-as-img.img"), z)
vectors.append(v)

# ---- payload sha rejections ------------------------------------------------
b = read(os.path.join(IMGD, "valid-min.img"))
f = fields(b); m_off = u64(f["manifest_offset"])
b[m_off + 16] ^= 0x01
vectors.append(reject("manifest-flip", "valid-min", b, "payload",
                      "PAYLOAD_CORRUPT", "CORRUPT",
                      "IMAGE-FORMAT §3 解析规则6：manifest_sha256 不匹配（§8 第5行）",
                      "manifest 第 16 字节取反，footer 内 manifest_sha256 未更新",
                      [{"offset": "manifest_offset+16", "xor": "0x01"}], mk_re='manifest sha256 mismatch'))

b = read(os.path.join(IMGD, "valid-full.img"))
f = fields(b); k_off = u64(f["kernel_offset"])
b[k_off + 0x100] ^= 0x01
vectors.append(reject("kernel-flip", "valid-full", b, "payload",
                      "PAYLOAD_CORRUPT", "CORRUPT",
                      "IMAGE-FORMAT §3 解析规则7 / §8 第13行：kernel_sha256 不匹配",
                      "kernel 第 0x100 字节取反（坏内核不能上机，R-16）",
                      [{"offset": "kernel_offset+256", "xor": "0x01"}], mk_re='kernel sha256 mismatch'))

b = read(os.path.join(IMGD, "valid-full.img"))
f = fields(b); i_off = u64(f["initrd_offset"])
b[i_off + 0x100] ^= 0x01
vectors.append(reject("initrd-flip", "valid-full", b, "payload",
                      "PAYLOAD_CORRUPT", "CORRUPT",
                      "IMAGE-FORMAT §3 解析规则7：initrd_sha256 不匹配",
                      None,
                      [{"offset": "initrd_offset+256", "xor": "0x01"}], mk_re='initrd sha256 mismatch'))

# ---- manifest semantics rejections ----------------------------------------
b = rewrite_manifest(read(os.path.join(IMGD, "valid-min.img")),
                     lambda m: m["image"].__setitem__("arch", "x86_64"))
vectors.append(reject("arch-amd64", "valid-min", b, "manifest",
                      "ARCH_MISMATCH", "ARCH_MISMATCH",
                      "IMAGE-FORMAT §5：arch != arm64（§8 第6行）",
                      "footer/manifest 自洽，仅语义非法",
                      [{"set_manifest": "image.arch=x86_64", "update": "manifest_size+sha256"}], mk_re='image.arch'))

b = rewrite_manifest(read(os.path.join(IMGD, "valid-min.img")),
                     lambda m: m["capabilities"].__setitem__("ssh", False))
vectors.append(reject("ssh-cap-false", "valid-min", b, "manifest",
                      "SSH_CAPABILITY_MISSING", "SSH_CAPABILITY_MISSING",
                      "IMAGE-FORMAT §4 字段规则：capabilities.ssh == false（DESIGN §4.8）",
                      None,
                      [{"set_manifest": "capabilities.ssh=false",
                        "update": "manifest_size+sha256"}], mk_re='capabilities.ssh'))

b = rewrite_manifest(read(os.path.join(IMGD, "valid-min.img")),
                     lambda m: m["accounts"].__setitem__("ssh_port", 2222))
vectors.append(reject("ssh-port-2222", "valid-min", b, "manifest",
                      "SSH_PORT_INVALID", "SSH_PORT_INVALID",
                      "IMAGE-FORMAT §4 字段规则：accounts.ssh_port != 22（DESIGN §4.8）",
                      None,
                      [{"set_manifest": "accounts.ssh_port=2222",
                        "update": "manifest_size+sha256"}], mk_re='accounts.ssh_port'))

b = rewrite_manifest(read(os.path.join(IMGD, "valid-min.img")),
                     lambda m: m["image"].__setitem__("id", "Debian-Minimal-ARM64"))
vectors.append(reject("bad-image-id", "valid-min", b, "manifest",
                      "IMAGE_ID_INVALID", "IMAGE_ID_INVALID",
                      "IMAGE-FORMAT §5：image.id 不匹配 ^[a-z0-9][a-z0-9._-]{0,63}$（防 -drive 注入）",
                      None,
                      [{"set_manifest": "image.id=Debian-Minimal-ARM64",
                        "update": "manifest_sha256"}], mk_re='image\\.id'))

b = rewrite_manifest(read(os.path.join(IMGD, "valid-min.img")),
                     lambda m: m.__setitem__("format", "Xmdroid-system-image"))
vectors.append(reject("manifest-format-wrong", "valid-min", b, "manifest",
                      "MANIFEST_INVALID", "NOT_AN_IMAGE",
                      "IMAGE-FORMAT §5：format != vmdroid-system-image → 非 VMDroid 镜像",
                      None,
                      [{"set_manifest": "format=Xmdroid-system-image",
                        "update": "manifest_sha256"}], mk_re='manifest format'))

# ---- parse OK, activation reject ------------------------------------------
b = rewrite_manifest(read(os.path.join(IMGD, "valid-min.img")),
                     lambda m: m["app"].__setitem__("min_version_code", 999999))
v = {"name": "app-too-old", "file": os.path.join("..", "data", "vectors", "app-too-old.img"),
     "derived_from": "valid-min",
     "patches": [{"set_manifest": "app.min_version_code=999999",
                  "update": "manifest_size+sha256"}],
     "size": len(b), "sha256": sha(bytes(b)),
     "expect": {"result": "accept", "stage": "parse",
                "rule": "DESIGN §7.4 #5：app.min_version_code > 当前 versionCode",
                "activate": {"result": "reject", "reason": "APP_TOO_OLD",
                             "bootGuard": "APP_TOO_OLD",
                             "context": {"currentVersionCode": 1}},
                "note": "解析期必须通过（footer/manifest 自洽），仅在激活期"
                        "以 currentVersionCode=1 复检时拒绝"}}
write_sparse(os.path.join(IMGD, "app-too-old.img"), b)
vectors.append(v)

# ---------------------------------------------- catalog signature vectors ---
# 固定签名向量（IMP-T02）：key/message/sig 已提交在 tests/vectors/，只读不重签。
# （openssl ECDSA 每次随机 nonce → 重签会破坏 vectors.json 字节级确定性。）
import subprocess
key = os.path.join(VECDIR, "catalog-test-key.pem")
message = open(os.path.join(VECDIR, "catalog-test-message.txt"), encoding="utf-8").read()
sig_b64 = open(os.path.join(VECDIR, "catalog-test-sig.b64"), encoding="utf-8").read().strip()
pub = subprocess.run(["openssl", "pkey", "-in", key, "-pubout"],
                     check=True, capture_output=True).stdout.decode()

doc = {
    "schema": 1,
    "spec": "docs/IMAGE-FORMAT.md v1.0 (format_version=1)",
    "design": "docs/DESIGN.md §6.1 catalog · §7.4 BootGuard reason · §8 测试向量",
    "generator": "Podroid-Debian/tests/gen-vectors.sh",
    "generator_note": "正向镜像由 tools/mkimg.sh 真实构建；期望值由本脚本内"
                      "独立读取器（非 mkimg 代码）计算；负向镜像在正向镜像上按"
                      "下表 patches 派生并保持 footer 自洽（除 sha/flips 类）。",
    "consumer": {
        "kotlin": "vmdroid VmdImageCodec：逐向量把 file 读入，按 expect.result 断言；"
                  "reject 时断言 expect.reason（codec 枚举）与 expect.bootGuard（DESIGN §7.4）；"
                  "accept 时逐字段比对 expect.segments。",
        "patches": "仅作说明（bytes 语义已固化在文件里）：offset 可为整数或 "
                   "'<seg>_offset+N'/'size-N' 形式；hex=写入字节；xor=按字节异或；"
                   "truncate=截断；set_manifest=重写 manifest 并同步 manifest_size/sha256。",
    },
    "footer_layout": [
        {"field": n, "offset": o, "size": s, "type": t, "fixed_value": fv}
        for (n, o, s, t, fv) in LAYOUT
    ],
    "alignment": {"kernel/initrd/manifest": 1048576, "footer": 4096,
                  "order": ["rootfs", "kernel", "initrd", "manifest", "footer"],
                  "file_size": "footer_offset + 4096"},
    "build_negative_vectors": [
        {"name": n, "args": a.split(),
         "expect": {"result": "reject", "stage": "mkimg-build",
                    "note": "mkimg 必须在写出前拒绝（IMAGE-FORMAT §4 字段规则 / §2 段约束）"}}
        for n, a in (line.rstrip("\n").split("\t")
                     for line in open(NEGT, encoding="utf-8") if line.strip())
    ],
    "catalog_signature": {
        "algorithm": "ECDSA P-256 + SHA-256 (openssl dgst -sha256 -sign), "
                     "signature = base64(DER)，detached — DESIGN §6.1",
        "android": 'Signature("SHA256withECDSA") + Base64.getDecoder()（非 MIME）',
        "public_key_pem": pub,
        "private_key_pem": open(key, encoding="utf-8").read(),
        "private_key_warning": "TEST VECTOR KEY ONLY — 绝不可用于真实发布（CI secret）",
        "message_path": "catalog-test-message.txt",
        "message": message,
        "message_sha256": sha(message.encode()),
        "signature_b64": sig_b64,
        "verify": {"valid_message": True, "tampered_message": False},
        "tampered_message": message + "tampered",
    },
    "vectors": vectors,
}
with open(VECJSON, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")

acc = sum(1 for v in vectors if v["expect"]["result"] == "accept")
print("  vectors: %d (accept=%d reject=%d)"
      % (len(vectors), acc, len(vectors) - acc))
print("  wrote %s" % VECJSON)
PY

note "done."
