#!/usr/bin/env bash
#
# tools/catalog.sh — generate + sign the VMDroid image catalog (catalog.json)
#
# Spec (frozen v1.0): DESIGN.md §6.1 (schema + ECDSA P-256/SHA-256 detached
#                     signature), §11.2 (CLI), §13.1 (signature test vectors),
#                     IMAGE-FORMAT.md §4 (manifest → catalog field mapping).
#
#   tools/catalog.sh --release-dir out \
#                    --base-url  https://github.com/ltbkq/Podroid-Debian/releases/download/<tag> \
#                    --sign-key  keys/catalog_ecdsa_p256.pem \
#                    -o catalog.json -o catalog.json.sig
#
# Signature (DESIGN §6.1, verbatim):
#   openssl dgst -sha256 -sign <key> catalog.json | openssl base64 -A > catalog.json.sig
# The private key is a CI secret and must never enter VCS.
#
set -euo pipefail

die() { echo "catalog: ERROR: $*" >&2; exit 1; }
warn() { echo "catalog: warn: $*" >&2; }

usage() {
    cat <<'EOF'
usage:
  tools/catalog.sh --release-dir <dir-with-.img> --base-url <url>
                   [--sign-key <ec-p256-pem> | --no-sign]
                   [--channel stable] [--notes <text>]
                   -o catalog.json [-o catalog.json.sig]

  --release-dir  directory containing the .img assets to index (all *.img)
  --base-url     prefix for each entry's url; url = base-url + "/" + <file>.img
  --sign-key     ECDSA P-256 private key (PEM) for catalog.json.sig
  --no-sign      skip signing (prints a loud warning; CI must not use this)
  --channel      channel field, default "stable"
  --notes        default notes text (manifest "notes" wins when present)
  -o             output path; repeat for the .sig path. With one -o the
                 signature defaults to "<json>.sig".

exit codes: 0 ok · 1 invalid input / signing failure · 2 usage
EOF
}

RELEASE_DIR=
BASE_URL=
SIGN_KEY=
CHANNEL=stable
NOTES=
NO_SIGN=0
OUTS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --release-dir) [ $# -ge 2 ] || die "--release-dir needs a value"; RELEASE_DIR=$2; shift 2 ;;
        --base-url)    [ $# -ge 2 ] || die "--base-url needs a value";    BASE_URL=$2;    shift 2 ;;
        --sign-key)    [ $# -ge 2 ] || die "--sign-key needs a value";    SIGN_KEY=$2;    shift 2 ;;
        --channel)     [ $# -ge 2 ] || die "--channel needs a value";     CHANNEL=$2;     shift 2 ;;
        --notes)       [ $# -ge 2 ] || die "--notes needs a value";       NOTES=$2;       shift 2 ;;
        -o|--output)   [ $# -ge 2 ] || die "-o needs a value";            OUTS+=("$2");   shift 2 ;;
        --no-sign)     NO_SIGN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        -*)            echo "catalog: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)             die "unexpected argument: $1" ;;
    esac
done

[ -n "$RELEASE_DIR" ] || { echo "catalog: --release-dir is required" >&2; usage >&2; exit 2; }
[ -n "$BASE_URL"    ] || { echo "catalog: --base-url is required"    >&2; usage >&2; exit 2; }
[ ${#OUTS[@]} -ge 1 ] || { echo "catalog: -o catalog.json is required" >&2; usage >&2; exit 2; }
[ -d "$RELEASE_DIR" ] || die "not a directory: $RELEASE_DIR"
if [ -n "$SIGN_KEY" ] && [ "$NO_SIGN" -eq 1 ]; then
    die "--sign-key and --no-sign are mutually exclusive"
fi

OUT_JSON=${OUTS[0]}
OUT_SIG=${OUTS[1]:-}
if [ "$NO_SIGN" -eq 1 ]; then
    if [ ${#OUTS[@]} -gt 1 ]; then
        warn "--no-sign given, ignoring the second -o ($OUT_SIG)"
    fi
    OUT_SIG=
elif [ -z "$OUT_SIG" ]; then
    OUT_SIG="${OUT_JSON}.sig"
fi
if [ "$NO_SIGN" -eq 0 ]; then
    [ -r "$SIGN_KEY" ] || die "cannot read --sign-key: $SIGN_KEY"
fi

# ------------------------------------------------------------- catalog JSON
set +e
GEN_OUT=$(python3 - gen "$RELEASE_DIR" "$BASE_URL" "$CHANNEL" "$NOTES" "$OUT_JSON" <<'PY'
import hashlib, json, os, re, struct, sys

MAGIC = b"VMDIMG01"
FOOTER_SIZE = 4096
IMG_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


def die(msg):
    print("catalog: ERROR: %s" % msg, file=sys.stderr)
    raise SystemExit(1)


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


def read_footer(path):
    size = os.path.getsize(path)
    if size < FOOTER_SIZE:
        die("%s: smaller than a footer" % path)
    with open(path, "rb") as f:
        f.seek(size - FOOTER_SIZE)
        ft = f.read(FOOTER_SIZE)
    if ft[0:8] != MAGIC or ft[4088:4096] != MAGIC:
        die("%s: no VMDIMG01 footer (bare squashfs? wrap it with tools/mkimg.sh)" % path)
    file_size = struct.unpack_from("<Q", ft, 16)[0]
    if file_size != size:
        die("%s: footer.file_size %d != %d" % (path, file_size, size))
    if struct.unpack_from("<I", ft, 8)[0] > 1:
        die("%s: format_version too new" % path)
    if struct.unpack_from("<I", ft, 12)[0] != FOOTER_SIZE:
        die("%s: bad footer_size" % path)
    return size, ft


def gen(release_dir, base_url, channel, default_notes, out_json):
    imgs = sorted(f for f in os.listdir(release_dir)
                  if f.endswith(".img") and os.path.isfile(os.path.join(release_dir, f)))
    if not imgs:
        die("no *.img found in %s" % release_dir)
    entries = []
    for name in imgs:
        path = os.path.join(release_dir, name)
        size, ft = read_footer(path)
        m_off, m_size = struct.unpack_from("<QQ", ft, 72)
        m_sha = ft[88:120]
        if m_off + m_size > size - FOOTER_SIZE:
            die("%s: manifest out of range" % path)
        with open(path, "rb") as f:
            f.seek(m_off)
            m_bytes = f.read(m_size)
        if hashlib.sha256(m_bytes).hexdigest() != m_sha.hex():
            die("%s: manifest sha256 mismatch (corrupt image?)" % path)
        try:
            man = json.loads(m_bytes.decode("utf-8"))
        except Exception as e:
            die("%s: manifest is not UTF-8 JSON: %s" % (path, e))
        if man.get("format") != "vmdroid-system-image":
            die("%s: not a VMDroid manifest" % path)
        img = man.get("image") or {}
        image_id = img.get("id")
        if not isinstance(image_id, str) or not IMG_ID_RE.match(image_id):
            die("%s: bad image.id %r" % (path, image_id))
        arch = img.get("arch")
        if arch != "arm64":
            die("%s: image.arch %r != arm64" % (path, arch))
        for k in ("display_name", "identity", "variant", "version"):
            if not isinstance(img.get(k), str) or not img[k]:
                die("%s: manifest.image.%s missing" % (path, k))
        if not isinstance(img.get("system_version"), int):
            die("%s: manifest.image.system_version missing" % path)
        app = man.get("app") or {}
        min_vc = app.get("min_version_code")
        if not isinstance(min_vc, int):
            die("%s: manifest.app.min_version_code missing" % path)
        caps = man.get("capabilities") or {"ssh": True}
        if caps.get("ssh") is not True:
            die("%s: capabilities.ssh must be true" % path)
        acc = man.get("accounts") or {}
        if acc.get("ssh_port", 22) != 22:
            die("%s: accounts.ssh_port must be 22" % path)
        full_sha = region_sha(path, 0, size)
        entries.append({
            "image_id": image_id,
            "display_name": img["display_name"],
            "identity": img["identity"],
            "variant": img["variant"],
            "version": img["version"],
            "system_version": img["system_version"],
            "arch": arch,
            "channel": channel,
            "url": base_url.rstrip("/") + "/" + name,
            "size": size,
            "sha256": full_sha,
            "app_min_version_code": min_vc,
            "notes": man.get("notes") or default_notes,
        })

    catalog = {
        "schema": 1,
        "generated_at": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "images": entries,
    }
    blob = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    try:
        with open(out_json, "wb") as f:
            f.write(blob.encode("utf-8"))
            f.flush()
            os.fsync(f.fileno())
    except OSError as e:
        die("cannot write %s: %s" % (out_json, e))
    print("entries=%d" % len(entries))
    for e in entries:
        print("  %s  size=%d  sha256=%s" % (e["image_id"], e["size"], e["sha256"]))
    print("wrote=%s" % out_json)


if len(sys.argv) != 7 or sys.argv[1] != "gen":
    die("internal: bad invocation")
gen(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
PY
)
GEN_RC=$?
set -e
[ "$GEN_RC" -eq 0 ] || exit "$GEN_RC"
printf '%s\n' "$GEN_OUT"

# ---------------------------------------------------------------- signing
if [ "$NO_SIGN" -eq 1 ]; then
    cat >&2 <<'EOF'
catalog: ****************************************************************
catalog: WARNING: --no-sign was used: catalog.json has NO detached signature.
catalog:          The app will REFUSE to load an unsigned catalog (DESIGN §6.1).
catalog:          Never publish --no-sign output to a release.
catalog: ****************************************************************
EOF
    exit 0
fi

echo "catalog: signing with ECDSA P-256 + SHA-256 (DESIGN §6.1)"
openssl dgst -sha256 -sign "$SIGN_KEY" "$OUT_JSON" | openssl base64 -A > "$OUT_SIG"
[ -s "$OUT_SIG" ] || die "empty signature written to $OUT_SIG"

# self-check: derive the public key and verify what we just produced
# (the .sig is base64(DER); decode before `openssl dgst -verify`, exactly what
#  the Android side does with Base64.getDecoder() — DESIGN §6.1)
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
openssl pkey -in "$SIGN_KEY" -pubout -out "$TMPD/pub.pem" 2>/dev/null \
    || die "cannot derive a public key from $SIGN_KEY (EC P-256 expected)"
openssl base64 -d -A -in "$OUT_SIG" -out "$TMPD/sig.der" 2>/dev/null \
    || die "signature is not valid base64: $OUT_SIG"
if openssl dgst -sha256 -verify "$TMPD/pub.pem" -signature "$TMPD/sig.der" "$OUT_JSON" >/dev/null 2>&1; then
    echo "catalog: signature self-verify OK -> $OUT_SIG"
else
    die "signature self-verify failed for $OUT_SIG"
fi

echo "catalog: json sha256=$(sha256sum "$OUT_JSON" | cut -d' ' -f1)"
echo "catalog: sig  bytes=$(wc -c < "$OUT_SIG") -> $OUT_SIG"
exit 0
