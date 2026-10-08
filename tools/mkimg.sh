#!/usr/bin/env bash
#
# tools/mkimg.sh — pack / verify a VMDroid single-file system image (.img)
#
# Spec (frozen v1.0): IMAGE-FORMAT.md §2 (layout) §3 (footer) §4 (manifest) §6 (CLI)
#                     DESIGN.md §11.2 / §12.2
#
#   build : tools/mkimg.sh --rootfs <squashfs> --manifest <json> \
#                           [--kernel <Image>] [--initrd <img>] -o <out.img>
#   verify: tools/mkimg.sh --verify <out.img>
#
# Layout written: rootfs(0) -> [1MiB] kernel -> [1MiB] initrd -> [1MiB] manifest
#                 -> [4KiB] footer(4096B),  file_size = footer_offset + 4096
# All footer fields little-endian; there is no seed segment (v1 decision 2026-10-08).
#
# python3 is a documented dependency (DESIGN §11.4). All binary packing,
# hashing and read-back checking live in the embedded programs below and the
# verifier is invoked twice (once for --verify, once as the build self-check),
# so build and verify share exactly one parser (IMAGE-FORMAT §6 step 6).
#
set -euo pipefail

SELF=$(readlink -f "$0")
TOOLS_DIR=$(cd "$(dirname "$SELF")" && pwd)
REPO_ROOT=$(cd "$TOOLS_DIR/.." && pwd)

die() { echo "mkimg: ERROR: $*" >&2; exit 1; }
warn() { echo "mkimg: warn: $*" >&2; }

usage() {
    cat <<'EOF'
usage:
  tools/mkimg.sh --rootfs <squashfs> --manifest <manifest.json>
                 [--kernel <arm64-Image>] [--initrd <initrd.img>]
                 -o <out.img> [--smoke | --no-smoke]

  tools/mkimg.sh --verify <out.img>

  --rootfs     squashfs source; only superblock bytes_used is copied (the
               4096-block padding tail is dropped, IMAGE-FORMAT §6 step 1)
  --manifest   manifest JSON (UTF-8, no BOM); derived fields
               checksums.rootfs_sha256 / boot.*_sha256 /
               contract.kernel.image_sha256 are (re)written by mkimg
  --kernel     arm64 Image payload (size must be 0 or >= 1 MiB)
  --initrd     initrd payload (size must be 0 or >= 4096)
  -o           output path (exactly one)
  --smoke      force pc-boot-smoke.sh after the self-check (failure = build failure)
  --no-smoke   skip the boot smoke test (default: auto-run when a payload is
               present and tools/pc-boot-smoke.sh + IMG_BOOT_LIB exist)
  --verify     read back an existing .img: every footer field, segment
               offset/size/sha256, alignment, order and full-file sha256

exit codes: 0 ok · 1 invalid input / failed self-check · 2 usage
            3 smoke requested but tooling missing
EOF
}

# --------------------------------------------------------------------------
# verify_img <img> — IMAGE-FORMAT §3 read-back checker (used for --verify and
# as the post-build self-check of §6 step 6.①).
# --------------------------------------------------------------------------
verify_img() {
    python3 - verify "$1" <<'PY'
import hashlib, json, os, re, struct, sys

MAGIC = b"VMDIMG01"
FOOTER_SIZE = 4096
M1 = 1 << 20
K4 = 4096
FLAGS_MASK = 0x3                     # bit0 HAS_KERNEL | bit1 HAS_INITRD (v1: no seed)
MAX_MANIFEST = 65536
MIN_KERNEL = M1
MIN_INITRD = 4096
IMG_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")

# footer field table (offset, size) — IMAGE-FORMAT.md §3 (frozen offsets)
F = {
    "magic":           (0, 8),
    "format_version":  (8, 4),
    "footer_size":     (12, 4),
    "file_size":       (16, 8),
    "rootfs_offset":   (24, 8),
    "rootfs_size":     (32, 8),
    "rootfs_sha256":   (40, 32),
    "manifest_offset": (72, 8),
    "manifest_size":   (80, 8),
    "manifest_sha256": (88, 32),
    "flags":           (120, 4),
    "kernel_offset":   (124, 8),
    "kernel_size":     (132, 8),
    "kernel_sha256":   (140, 32),
    "initrd_offset":   (172, 8),
    "initrd_size":     (180, 8),
    "initrd_sha256":   (188, 32),
    "reserved":        (220, 3868),
    "magic_tail":      (4088, 8),
}
# regression guards: seed-removal offset renumbering (R3: RB-1 / A-R3-31)
assert F["manifest_offset"][0] == 72 and F["flags"][0] == 120
assert F["kernel_offset"][0] == 124 and F["initrd_offset"][0] == 172
assert F["reserved"][0] + F["reserved"][1] == 4088


def die(msg):
    print("mkimg: verify FAIL: %s" % msg, file=sys.stderr)
    raise SystemExit(1)


def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]


def region_sha(path, off, size):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        f.seek(off)
        left = size
        while left:
            c = f.read(min(1 << 20, left))
            if not c:
                die("%s: short read (file truncated?)" % path)
            h.update(c)
            left -= len(c)
    return h.hexdigest()


def validate_manifest(man):
    """IMAGE-FORMAT §4 field rules — identical code path in build and verify."""
    if not isinstance(man, dict):
        die("manifest is not a JSON object")
    if man.get("format") != "vmdroid-system-image":
        die('manifest format != "vmdroid-system-image"')
    if man.get("format_version") != 1:
        die("manifest format_version != 1")
    img = man.get("image")
    if not isinstance(img, dict):
        die("manifest.image missing")
    iid = img.get("id")
    if not isinstance(iid, str) or not IMG_ID_RE.match(iid):
        die("image.id %r does not match ^[a-z0-9][a-z0-9._-]{0,63}$" % iid)
    for k in ("identity", "variant", "version", "display_name"):
        if not isinstance(img.get(k), str) or not img.get(k):
            die("image.%s missing/empty" % k)
    if not isinstance(img.get("system_version"), int):
        die("image.system_version missing/not an integer")
    if img.get("arch") != "arm64":
        die("image.arch %r != arm64" % img.get("arch"))
    caps = man.get("capabilities") or {"ssh": True, "x11": True, "containers": True}
    if not isinstance(caps, dict) or caps.get("ssh") is not True:
        die("capabilities.ssh must be true (DESIGN §4.8)")
    acc = man.get("accounts") or {}
    port = acc.get("ssh_port", 22) if isinstance(acc, dict) else 22
    if port != 22:
        die("accounts.ssh_port %r != 22 (DESIGN §4.8)" % port)
    app = man.get("app")
    if not isinstance(app, dict) or not isinstance(app.get("min_version_code"), int) \
            or app["min_version_code"] < 1:
        die("app.min_version_code missing/not a positive integer")
    if "contract" in man:
        c = man["contract"]
        if not isinstance(c, dict) or not isinstance(c.get("version"), int):
            die("contract.version missing/not an integer")


def fmt_seg(name, off, size, sha):
    return "%-8s offset=%-12d size=%-10d sha256=%s" % (name, off, size, sha)


def verify(path):
    size = os.path.getsize(path)
    if size < FOOTER_SIZE:
        die("file smaller than 4096 bytes (%d)" % size)
    with open(path, "rb") as f:
        f.seek(size - FOOTER_SIZE)
        ft = f.read(FOOTER_SIZE)
    if len(ft) != FOOTER_SIZE:
        die("short read of footer")
    if ft[0:8] != MAGIC or ft[4088:4096] != MAGIC:
        die("bad magic %r / magic_tail %r (not a VMDroid .img)"
            % (ft[0:8], ft[4088:4096]))
    if size < 8192:
        die("file_size < 8192 after magic match (R1: B-R1-11)")
    if u32(ft, F["footer_size"][0]) != FOOTER_SIZE:
        die("footer_size %d != 4096" % u32(ft, F["footer_size"][0]))
    fmt = u32(ft, F["format_version"][0])
    if fmt > 1:
        die("format_version %d > 1 (unsupported format, update the app/tool)" % fmt)
    file_size = u64(ft, F["file_size"][0])
    if file_size != size:
        die("footer.file_size %d != actual size %d (truncated or concatenated)"
            % (file_size, size))
    flags = u32(ft, F["flags"][0])
    if flags & ~FLAGS_MASK:
        die("unknown flags 0x%x (legal mask 0x%x)" % (flags, FLAGS_MASK))
    if bool(flags & 0x1) != (u64(ft, F["kernel_size"][0]) > 0):
        die("flags bit0 vs kernel_size mismatch")
    if bool(flags & 0x2) != (u64(ft, F["initrd_size"][0]) > 0):
        die("flags bit1 vs initrd_size mismatch")
    if not (flags & 0x1) and (u64(ft, F["kernel_offset"][0]) or u64(ft, F["kernel_size"][0])):
        die("kernel absent but kernel_offset/kernel_size != 0")
    if not (flags & 0x2) and (u64(ft, F["initrd_offset"][0]) or u64(ft, F["initrd_size"][0])):
        die("initrd absent but initrd_offset/initrd_size != 0")

    r_off, r_size = u64(ft, F["rootfs_offset"][0]), u64(ft, F["rootfs_size"][0])
    k_off, k_size = u64(ft, F["kernel_offset"][0]), u64(ft, F["kernel_size"][0])
    i_off, i_size = u64(ft, F["initrd_offset"][0]), u64(ft, F["initrd_size"][0])
    m_off, m_size = u64(ft, F["manifest_offset"][0]), u64(ft, F["manifest_size"][0])
    r_sha = ft[F["rootfs_sha256"][0]:F["rootfs_sha256"][0] + 32]
    k_sha = ft[F["kernel_sha256"][0]:F["kernel_sha256"][0] + 32]
    i_sha = ft[F["initrd_sha256"][0]:F["initrd_sha256"][0] + 32]
    m_sha = ft[F["manifest_sha256"][0]:F["manifest_sha256"][0] + 32]

    if r_off != 0:
        die("rootfs_offset %d != 0" % r_off)
    if r_size == 0:
        die("rootfs_size == 0")
    if not (1 <= m_size <= MAX_MANIFEST):
        die("manifest_size %d outside [1, %d]" % (m_size, MAX_MANIFEST))
    if k_size and k_size < MIN_KERNEL:
        die("kernel_size %d < 1 MiB" % k_size)
    if i_size and i_size < MIN_INITRD:
        die("initrd_size %d < 4096" % i_size)
    if ft[F["reserved"][0]:F["reserved"][0] + F["reserved"][1]] != b"\0" * F["reserved"][1]:
        die("reserved region not all zero")

    limit = file_size - FOOTER_SIZE          # every segment must live below the footer
    segs = [("rootfs", r_off, r_size)]
    if flags & 0x1:
        segs.append(("kernel", k_off, k_size))
    if flags & 0x2:
        segs.append(("initrd", i_off, i_size))
    segs.append(("manifest", m_off, m_size))

    prev_end = None
    for name, off, sz in segs:
        if off > 0xFFFFFFFFFFFFFFFF - sz or off + sz > limit:
            die("%s [%d,%d) out of range (limit %d)" % (name, off, off + sz, limit))
        if prev_end is None:
            if off != 0:
                die("rootfs must start at 0, got %d" % off)
            prev_end = off + sz
        else:
            if off < prev_end:
                die("%s offset %d < previous segment end %d (overlap/order)" % (name, off, prev_end))
            prev_end = off + sz
    footer_off = file_size - FOOTER_SIZE
    if prev_end > footer_off:
        die("last segment end %d > footer_offset %d" % (prev_end, footer_off))
    if (flags & 0x1) and k_off % M1:
        die("kernel_offset %d not 1 MiB aligned" % k_off)
    if (flags & 0x2) and i_off % M1:
        die("initrd_offset %d not 1 MiB aligned" % i_off)
    if m_off % M1:
        die("manifest_offset %d not 1 MiB aligned" % m_off)
    if footer_off % K4:
        die("footer_offset %d not 4 KiB aligned" % footer_off)

    checks = []
    got = region_sha(path, r_off, r_size)
    if got != r_sha.hex():
        die("rootfs sha256 mismatch (footer %s != %s)" % (r_sha.hex(), got))
    checks.append("rootfs sha256 OK")
    with open(path, "rb") as f:
        f.seek(m_off)
        m_bytes = f.read(m_size)
    if hashlib.sha256(m_bytes).hexdigest() != m_sha.hex():
        die("manifest sha256 mismatch")
    checks.append("manifest sha256 OK")
    if flags & 0x1:
        if region_sha(path, k_off, k_size) != k_sha.hex():
            die("kernel sha256 mismatch")
        checks.append("kernel sha256 OK")
    if flags & 0x2:
        if region_sha(path, i_off, i_size) != i_sha.hex():
            die("initrd sha256 mismatch")
        checks.append("initrd sha256 OK")
    try:
        man = json.loads(m_bytes.decode("utf-8"))
    except Exception as e:
        die("manifest is not valid UTF-8 JSON: %s" % e)
    validate_manifest(man)
    checks.append("manifest semantics OK (IMAGE-FORMAT §4)")

    print("== footer @ offset %d   (file_size %d, actual %d)" % (footer_off, file_size, size))
    print("  magic              %r" % ft[0:8])
    print("  magic_tail         %r" % ft[4088:4096])
    print("  format_version     %d" % fmt)
    print("  footer_size        %d" % u32(ft, F["footer_size"][0]))
    print("  file_size          %d" % file_size)
    names = {0: " (none)", 1: " (HAS_KERNEL)", 2: " (HAS_INITRD)", 3: " (HAS_KERNEL|HAS_INITRD)"}
    print("  flags              0x%x%s" % (flags, names.get(flags, "")))
    print("  reserved[220..]    all-zero OK (%d B)" % F["reserved"][1])
    print("-- segments")
    print("  " + fmt_seg("rootfs", r_off, r_size, r_sha.hex()))
    print("  " + fmt_seg("kernel", k_off, k_size,
                         k_sha.hex() if (flags & 0x1) else "0" * 64))
    print("  " + fmt_seg("initrd", i_off, i_size,
                         i_sha.hex() if (flags & 0x2) else "0" * 64))
    print("  " + fmt_seg("manifest", m_off, m_size, m_sha.hex()))
    print("  %-8s offset=%-12d size=%d" % ("footer", footer_off, FOOTER_SIZE))
    print("-- checks")
    for c in checks:
        print("  " + c)
    print("  segment bounds/order OK · 1MiB/4KiB alignment OK · flags↔segments OK")
    print("  file sha256        %s" % region_sha(path, 0, file_size))
    print("VERIFY OK: %s" % path)


if len(sys.argv) != 3 or sys.argv[1] != "verify":
    die("internal: bad verify invocation")
verify(sys.argv[2])
PY
}

# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------
MODE=build
ROOTFS=
MANIFEST=
KERNEL=
INITRD=
OUT=
SMOKE=auto
VERIFY_ARG=

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs)    [ $# -ge 2 ] || die "--rootfs needs a value";  ROOTFS=$2;   shift 2 ;;
        --manifest)  [ $# -ge 2 ] || die "--manifest needs a value"; MANIFEST=$2; shift 2 ;;
        --kernel)    [ $# -ge 2 ] || die "--kernel needs a value";  KERNEL=$2;   shift 2 ;;
        --initrd)    [ $# -ge 2 ] || die "--initrd needs a value";  INITRD=$2;   shift 2 ;;
        -o|--output) [ $# -ge 2 ] || die "-o needs a value";        OUT=$2;      shift 2 ;;
        --verify)    [ $# -ge 2 ] || die "--verify needs a value";  MODE=verify; VERIFY_ARG=$2; shift 2 ;;
        --smoke)     SMOKE=1;   shift ;;
        --no-smoke)  SMOKE=0;   shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        -*)          echo "mkimg: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)           die "unexpected argument: $1" ;;
    esac
done

if [ "$MODE" = verify ]; then
    [ -r "$VERIFY_ARG" ] || die "cannot read $VERIFY_ARG"
    verify_img "$VERIFY_ARG"
    exit $?
fi

# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------
[ -n "$ROOTFS"   ] || { echo "mkimg: --rootfs is required" >&2; usage >&2; exit 2; }
[ -n "$MANIFEST" ] || { echo "mkimg: --manifest is required" >&2; usage >&2; exit 2; }
[ -n "$OUT"       ] || { echo "mkimg: -o is required" >&2; usage >&2; exit 2; }
[ -r "$ROOTFS"   ] || die "cannot read rootfs: $ROOTFS"
[ -r "$MANIFEST" ] || die "cannot read manifest: $MANIFEST"
[ -z "$KERNEL" ] || [ -r "$KERNEL" ] || die "cannot read kernel: $KERNEL"
[ -z "$INITRD" ] || [ -r "$INITRD" ] || die "cannot read initrd: $INITRD"
[ "$ROOTFS" != "$OUT" ] || die "output would overwrite the rootfs source"

set +e
BUILD_OUT=$(python3 - build "$ROOTFS" "$MANIFEST" "${KERNEL:-}" "${INITRD:-}" "$OUT" <<'PY'
# --- IMAGE-FORMAT §6 build algorithm ---------------------------------------
import hashlib, json, os, re, struct, sys

MAGIC = b"VMDIMG01"
FOOTER_SIZE = 4096
M1 = 1 << 20
K4 = 4096
SQUASH_MAGIC = b"hsqs"
SQUASH_BYTES_USED_OFF = 40        # squashfs 4.0 superblock: u64 bytes_used @0x28
MAX_MANIFEST = 65536
MIN_KERNEL = M1
MIN_INITRD = 4096
IMG_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")

F = {
    "magic":           (0, 8),
    "format_version":  (8, 4),
    "footer_size":     (12, 4),
    "file_size":       (16, 8),
    "rootfs_offset":   (24, 8),
    "rootfs_size":     (32, 8),
    "rootfs_sha256":   (40, 32),
    "manifest_offset": (72, 8),
    "manifest_size":   (80, 8),
    "manifest_sha256": (88, 32),
    "flags":           (120, 4),
    "kernel_offset":   (124, 8),
    "kernel_size":     (132, 8),
    "kernel_sha256":   (140, 32),
    "initrd_offset":   (172, 8),
    "initrd_size":     (180, 8),
    "initrd_sha256":   (188, 32),
    "reserved":        (220, 3868),
    "magic_tail":      (4088, 8),
}
assert F["manifest_offset"][0] == 72 and F["flags"][0] == 120
assert F["kernel_offset"][0] == 124 and F["initrd_offset"][0] == 172
assert F["reserved"][0] + F["reserved"][1] == 4088


def die(msg):
    print("mkimg: ERROR: %s" % msg, file=sys.stderr)
    raise SystemExit(1)


def align_up(v, a):
    return (v + a - 1) // a * a


def region_sha(path, off, size):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        f.seek(off)
        left = size
        while left:
            c = f.read(min(1 << 20, left))
            if not c:
                die("%s: short read" % path)
            h.update(c)
            left -= len(c)
    return h.hexdigest()


def squashfs_bytes_used(path):
    """rootfs_size = superblock.bytes_used (§6 step 1: drop the 4096-block
    padding tail — measured 345251457 vs file 345251840 => 383 B dropped)."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        sb = f.read(96)
    if len(sb) < 48:
        die("rootfs smaller than a squashfs superblock")
    if sb[0:4] != SQUASH_MAGIC:
        die("rootfs is not a squashfs (superblock magic %r != 'hsqs'): %s"
            % (sb[0:4], path))
    bu = struct.unpack_from("<Q", sb, SQUASH_BYTES_USED_OFF)[0]
    if bu == 0 or bu > size:
        die("bad superblock bytes_used=%d (file size %d)" % (bu, size))
    if size - bu >= 4096:
        print("mkimg: warn: rootfs padding tail is %d bytes (>=4096), expected <4096"
              % (size - bu), file=sys.stderr)
    return bu


def validate_manifest(man):
    if not isinstance(man, dict):
        die("manifest is not a JSON object")
    if man.get("format") != "vmdroid-system-image":
        die('manifest format != "vmdroid-system-image"')
    if man.get("format_version") != 1:
        die("manifest format_version != 1")
    img = man.get("image")
    if not isinstance(img, dict):
        die("manifest.image missing")
    iid = img.get("id")
    if not isinstance(iid, str) or not IMG_ID_RE.match(iid):
        die("image.id %r does not match ^[a-z0-9][a-z0-9._-]{0,63}$" % iid)
    for k in ("identity", "variant", "version", "display_name"):
        if not isinstance(img.get(k), str) or not img.get(k):
            die("image.%s missing/empty" % k)
    if not isinstance(img.get("system_version"), int):
        die("image.system_version missing/not an integer")
    if img.get("arch") != "arm64":
        die("image.arch %r != arm64" % img.get("arch"))
    caps = man.get("capabilities") or {"ssh": True, "x11": True, "containers": True}
    if not isinstance(caps, dict) or caps.get("ssh") is not True:
        die("capabilities.ssh must be true (DESIGN §4.8)")
    acc = man.get("accounts") or {}
    port = acc.get("ssh_port", 22) if isinstance(acc, dict) else 22
    if port != 22:
        die("accounts.ssh_port %r != 22 (DESIGN §4.8)" % port)
    app = man.get("app")
    if not isinstance(app, dict) or not isinstance(app.get("min_version_code"), int) \
            or app["min_version_code"] < 1:
        die("app.min_version_code missing/not a positive integer")
    if "contract" in man:
        c = man["contract"]
        if not isinstance(c, dict) or not isinstance(c.get("version"), int):
            die("contract.version missing/not an integer")


def dump_footer(fields):
    buf = bytearray(FOOTER_SIZE)          # reserved region is already zero
    buf[0:8] = MAGIC
    buf[4088:4096] = MAGIC
    struct.pack_into("<I", buf, F["format_version"][0], fields["format_version"])
    struct.pack_into("<I", buf, F["footer_size"][0], fields["footer_size"])
    struct.pack_into("<I", buf, F["flags"][0], fields["flags"])
    for name in ("file_size", "rootfs_offset", "rootfs_size", "manifest_offset",
                 "manifest_size", "kernel_offset", "kernel_size",
                 "initrd_offset", "initrd_size"):
        struct.pack_into("<Q", buf, F[name][0], fields[name])
    for name in ("rootfs_sha256", "manifest_sha256", "kernel_sha256", "initrd_sha256"):
        h = fields[name]
        if h is None:
            h = b"\0" * 32
        elif isinstance(h, str):
            h = bytes.fromhex(h)
        if len(h) != 32:
            die("%s is not 32 bytes" % name)
        o = F[name][0]
        buf[o:o + 32] = h
    return bytes(buf)


def cmd_build(rootfs, manifest_path, kernel, initrd, out):
    R = squashfs_bytes_used(rootfs)
    rootfs_sha = region_sha(rootfs, 0, R)

    k_size = os.path.getsize(kernel) if kernel else 0
    i_size = os.path.getsize(initrd) if initrd else 0
    if kernel and k_size < MIN_KERNEL:
        die("kernel payload %d bytes < 1 MiB (IMAGE-FORMAT §2)" % k_size)
    if initrd and i_size < MIN_INITRD:
        die("initrd payload %d bytes < 4096 (IMAGE-FORMAT §2)" % i_size)
    k_sha = region_sha(kernel, 0, k_size) if kernel else None
    i_sha = region_sha(initrd, 0, i_size) if initrd else None

    try:
        raw = open(manifest_path, "rb").read()
    except OSError as e:
        die("cannot read manifest: %s" % e)
    if raw.startswith(b"\xef\xbb\xbf"):
        die("manifest must be UTF-8 without BOM")
    try:
        man = json.loads(raw.decode("utf-8"))
    except Exception as e:
        die("manifest is not valid UTF-8 JSON: %s" % e)
    validate_manifest(man)

    # derived fields: the footer is the binary truth, mirror it into the JSON
    derived = []
    man["checksums"] = dict(man.get("checksums") or {})
    man["checksums"]["rootfs_sha256"] = rootfs_sha
    derived.append("checksums.rootfs_sha256")
    if kernel or initrd:
        boot = dict(man.get("boot") or {})
        if kernel:
            boot["kernel_sha256"] = k_sha
            derived.append("boot.kernel_sha256")
        if initrd:
            boot["initrd_sha256"] = i_sha
            derived.append("boot.initrd_sha256")
        man["boot"] = boot
    if kernel and isinstance(man.get("contract"), dict):
        c = man["contract"]
        c["kernel"] = dict(c.get("kernel") or {})
        c["kernel"]["image_sha256"] = k_sha
        derived.append("contract.kernel.image_sha256")

    man_bytes = (json.dumps(man, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    M = len(man_bytes)
    if not (1 <= M <= MAX_MANIFEST):
        die("serialized manifest is %d bytes, must be 1..%d" % (M, MAX_MANIFEST))

    flags = (0x1 if kernel else 0) | (0x2 if initrd else 0)
    cur = R
    o_kernel = o_initrd = 0
    if kernel:
        o_kernel = align_up(cur, M1)
        cur = o_kernel + k_size
    if initrd:
        o_initrd = align_up(cur, M1)
        cur = o_initrd + i_size
    o_manifest = align_up(cur, M1)
    cur = o_manifest + M
    o_footer = align_up(cur, K4)
    file_size = o_footer + FOOTER_SIZE

    fields = dict(
        format_version=1, footer_size=FOOTER_SIZE, file_size=file_size,
        rootfs_offset=0, rootfs_size=R, rootfs_sha256=rootfs_sha,
        manifest_offset=o_manifest, manifest_size=M,
        manifest_sha256=hashlib.sha256(man_bytes).hexdigest(),
        flags=flags,
        kernel_offset=o_kernel, kernel_size=k_size if kernel else 0, kernel_sha256=k_sha,
        initrd_offset=o_initrd, initrd_size=i_size if initrd else 0, initrd_sha256=i_sha,
    )

    def zero(dst, n):
        while n > 0:
            chunk = b"\0" * min(n, 1 << 20)
            dst.write(chunk)
            n -= len(chunk)

    def pad_to(dst, target, cur_pos):
        zero(dst, target - cur_pos)
        return target

    def copy(dst, path, size):
        with open(path, "rb") as src:
            left = size
            while left:
                c = src.read(min(1 << 20, left))
                if not c:
                    die("%s: short read while writing" % path)
                dst.write(c)
                left -= len(c)

    try:
        dst = open(out, "wb")
    except OSError as e:
        die("cannot write %s: %s" % (out, e))
    try:
        with dst:
            copy(dst, rootfs, R)                              # rootfs @ 0
            pos = R
            if kernel:
                pos = pad_to(dst, o_kernel, pos)
                copy(dst, kernel, k_size)
                pos += k_size
            if initrd:
                pos = pad_to(dst, o_initrd, pos)
                copy(dst, initrd, i_size)
                pos += i_size
            pos = pad_to(dst, o_manifest, pos)                # 1 MiB alignment
            dst.write(man_bytes)
            pos += M
            pos = pad_to(dst, o_footer, pos)                  # 4 KiB alignment
            dst.write(dump_footer(fields))
            os.fsync(dst.fileno())
    except OSError as e:
        die("write failed: %s" % e)
    if pos != o_footer or o_footer + FOOTER_SIZE != file_size:
        die("internal layout error (pos=%d footer=%d file_size=%d)" % (pos, o_footer, file_size))

    print("== mkimg build: %s" % out)
    print("  rootfs   source=%s bytes_used=%d (4096-block padding tail dropped)" % (rootfs, R))
    print("  manifest source=%s bytes=%d" % (manifest_path, M))
    if derived:
        print("  derived manifest fields written: %s" % ", ".join(derived))
    print("-- segments")
    print("  rootfs   offset=%-12d size=%d" % (0, R))
    print("  kernel   offset=%-12d size=%d" % (o_kernel, k_size if kernel else 0))
    print("  initrd   offset=%-12d size=%d" % (o_initrd, i_size if initrd else 0))
    print("  manifest offset=%-12d size=%d" % (o_manifest, M))
    print("  footer   offset=%-12d size=%d" % (o_footer, FOOTER_SIZE))
    print("  file_size=%d  flags=0x%x" % (file_size, flags))
    print("has_payload=%d" % (1 if (kernel or initrd) else 0))
    print("file_size=%d" % file_size)
    print("file_sha256=%s" % region_sha(out, 0, file_size))


if len(sys.argv) != 7 or sys.argv[1] != "build":
    die("internal: bad build invocation")
cmd_build(sys.argv[2], sys.argv[3], sys.argv[4] or None, sys.argv[5] or None, sys.argv[6])
PY
)
BUILD_RC=$?
set -e
[ "$BUILD_RC" -eq 0 ] || die "build failed (rc=$BUILD_RC)"
printf '%s\n' "$BUILD_OUT"

HAS_PAYLOAD=$(printf '%s\n' "$BUILD_OUT" | sed -n 's/^has_payload=//p' | tail -1)
FULL_SIZE=$(printf '%s\n'   "$BUILD_OUT" | sed -n 's/^file_size=//p' | tail -1)
FULL_SHA=$(printf '%s\n'    "$BUILD_OUT" | sed -n 's/^file_sha256=//p' | tail -1)

echo "mkimg: self-check (IMAGE-FORMAT §6 step 6.① — same parser reads it back)"
verify_img "$OUT" >/dev/null || die "self-check failed"
echo "mkimg: self-check OK · size=$FULL_SIZE · sha256=$FULL_SHA"

# ------------------------------------------------- step 6.② boot smoke (auto)
run_smoke=$SMOKE
IMG_BOOT_LIB=${IMG_BOOT_LIB:-$REPO_ROOT/../vmdroid/tools/lib/imgboot.sh}
if [ "$SMOKE" = auto ]; then
    run_smoke=0
    if [ "${HAS_PAYLOAD:-0}" = 1 ]; then
        if [ -x "$TOOLS_DIR/pc-boot-smoke.sh" ] && command -v qemu-system-aarch64 >/dev/null 2>&1 \
           && [ -r "$IMG_BOOT_LIB" ]; then
            run_smoke=1
        else
            warn "boot smoke skipped: need tools/pc-boot-smoke.sh + qemu-system-aarch64 + readable IMG_BOOT_LIB ($IMG_BOOT_LIB)"
            warn "run it explicitly: tools/pc-boot-smoke.sh $OUT"
        fi
    fi
fi

if [ "$run_smoke" = 1 ]; then
    [ -x "$TOOLS_DIR/pc-boot-smoke.sh" ] || {
        [ "$SMOKE" = 1 ] && { echo "mkimg: ERROR: --smoke given but tools/pc-boot-smoke.sh is missing" >&2; exit 3; }
        warn "pc-boot-smoke.sh missing, skipping"
        run_smoke=0
    }
fi
if [ "$run_smoke" = 1 ]; then
    echo "mkimg: self-check (IMAGE-FORMAT §6 step 6.② pc-boot-smoke.sh)"
    set +e
    "$TOOLS_DIR/pc-boot-smoke.sh" "$OUT"
    SMOKE_RC=$?
    set -e
    if [ "$SMOKE_RC" -ne 0 ]; then
        if [ "$SMOKE" = 1 ]; then
            echo "mkimg: ERROR: boot smoke failed (rc=$SMOKE_RC)" >&2
            exit "$SMOKE_RC"
        fi
        die "boot smoke failed (rc=$SMOKE_RC)"
    fi
fi

exit 0
