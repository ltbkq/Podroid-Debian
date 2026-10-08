#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tests/independent_check.py — 独立复核一个 VMDroid .img（不复用 mkimg 代码）。

与 tools/mkimg.sh 的内嵌解析器刻意相互独立：本脚本把 IMAGE-FORMAT.md §2/§3/§4/§5
的每个约束重新硬编码实现一遍，用来交叉验证生成器（"不要只信自己的脚本"）。

用法：
    tests/independent_check.py <img> [--expect-sha256 HEX] [--quiet]

断言（全部通过 exit 0，否则 exit 1）：
  1. footer 双 magic / format_version<=1 / footer_size==4096 / reserved 全零
  2. footer.file_size == 实际文件大小
  3. flags 合法掩码 0x3，且与 kernel/initrd 段一致性
  4. 段边界（每段 [off,off+size) ⊆ [0, file_size-4096)）、段序 rootfs→kernel→initrd→manifest→footer
  5. 对齐：kernel/initrd/manifest 1 MiB，footer 4 KiB，file_size = footer_offset+4096
  6. 逐段 sha256 重算 == footer 值
  7. rootfs_size == squashfs superblock.bytes_used（偏移 0x28），且 rootfs[0:4]=="hsqs"
  8. manifest 语义（IMAGE-FORMAT §4）与派生字段（checksums/boot/contract.kernel）== footer
  9. 全文件 sha256（可与 --expect-sha256 比对）
"""
import hashlib
import json
import os
import re
import struct
import sys

MAGIC = b"VMDIMG01"
FOOTER = 4096
MIB = 1 << 20
KIB = 4 << 10
MASK = 0x3

# IMAGE-FORMAT §3（v1，seed 已移除，R3 冻结值）——与生成器无关的第二份实现
FIELDS = {
    "magic": (0, 8, "bytes"),
    "format_version": (8, 4, "u32"),
    "footer_size": (12, 4, "u32"),
    "file_size": (16, 8, "u64"),
    "rootfs_offset": (24, 8, "u64"),
    "rootfs_size": (32, 8, "u64"),
    "rootfs_sha256": (40, 32, "bytes"),
    "manifest_offset": (72, 8, "u64"),
    "manifest_size": (80, 8, "u64"),
    "manifest_sha256": (88, 32, "bytes"),
    "flags": (120, 4, "u32"),
    "kernel_offset": (124, 8, "u64"),
    "kernel_size": (132, 8, "u64"),
    "kernel_sha256": (140, 32, "bytes"),
    "initrd_offset": (172, 8, "u64"),
    "initrd_size": (180, 8, "u64"),
    "initrd_sha256": (188, 32, "bytes"),
    "reserved": (220, 3868, "zero"),
    "magic_tail": (4088, 8, "bytes"),
}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")

FAILS = []
CHECKS = []


def ok(msg):
    CHECKS.append("OK   " + msg)


def bad(msg):
    FAILS.append(msg)
    CHECKS.append("FAIL " + msg)


def eq(label, got, want):
    if got == want:
        ok("%s = %s" % (label, got))
    else:
        bad("%s: got %r, want %r" % (label, got, want))


def region_sha(f, off, size, buf=None):
    if buf is not None:
        return hashlib.sha256(buf[off:off + size]).hexdigest()
    if isinstance(f, str):
        with open(f, "rb") as fh:
            return region_sha(fh, off, size)
    f.seek(off)
    h = hashlib.sha256()
    left = size
    while left:
        c = f.read(min(1 << 20, left))
        if not c:
            return None
        h.update(c)
        left -= len(c)
    return h.hexdigest()


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    expect_sha = None
    if "--expect-sha256" in argv:
        expect_sha = argv[argv.index("--expect-sha256") + 1].lower()
    quiet = "--quiet" in argv

    size = os.path.getsize(path)
    if size < FOOTER:
        bad("file size %d < 4096" % size)
        report(path, quiet)
        return 1

    with open(path, "rb") as f:
        f.seek(size - FOOTER)
        ft = f.read(FOOTER)
        if len(ft) != FOOTER:
            bad("short footer read")
            report(path, quiet)
            return 1

        g = {}
        for name, (off, ln, typ) in FIELDS.items():
            raw = ft[off:off + ln]
            if typ == "u32":
                g[name] = struct.unpack("<I", raw)[0]
            elif typ == "u64":
                g[name] = struct.unpack("<Q", raw)[0]
            elif typ == "zero":
                g[name] = raw
            else:
                g[name] = raw

        # 1) magic / version / footer_size / reserved
        eq("footer.magic", g["magic"], MAGIC)
        eq("footer.magic_tail", g["magic_tail"], MAGIC)
        eq("footer.format_version", g["format_version"], 1)
        eq("footer.footer_size", g["footer_size"], FOOTER)
        if g["reserved"] == b"\0" * 3868:
            ok("footer.reserved all-zero (3868 B)")
        else:
            bad("footer.reserved not all zero")

        # 2) file_size
        eq("footer.file_size", g["file_size"], size)

        # 3) flags
        flags = g["flags"]
        if flags & ~MASK:
            bad("flags 0x%x has bits outside mask 0x3" % flags)
        else:
            ok("flags = 0x%x within mask 0x3" % flags)
        eq("flags bit0 == (kernel_size>0)", bool(flags & 1), g["kernel_size"] > 0)
        eq("flags bit1 == (initrd_size>0)", bool(flags & 2), g["initrd_size"] > 0)
        if not (flags & 1):
            eq("no kernel → offset/size 0", (g["kernel_offset"], g["kernel_size"]), (0, 0))
        if not (flags & 2):
            eq("no initrd → offset/size 0", (g["initrd_offset"], g["initrd_size"]), (0, 0))

        # 4/5) segment table, bounds, order, alignment
        limit = size - FOOTER
        footer_off = size - FOOTER
        segs = [("rootfs", g["rootfs_offset"], g["rootfs_size"])]
        if flags & 1:
            segs.append(("kernel", g["kernel_offset"], g["kernel_size"]))
        if flags & 2:
            segs.append(("initrd", g["initrd_offset"], g["initrd_size"]))
        segs.append(("manifest", g["manifest_offset"], g["manifest_size"]))

        eq("rootfs_offset == 0", g["rootfs_offset"], 0)
        if g["rootfs_size"] <= 0:
            bad("rootfs_size == 0")
        if not (1 <= g["manifest_size"] <= 65536):
            bad("manifest_size %d outside [1,65536]" % g["manifest_size"])
        prev = None
        for name, off, ln in segs:
            if off > 0xFFFFFFFFFFFFFFFF - ln or off + ln > limit:
                bad("%s [%d,%d) out of range (limit=%d)" % (name, off, off + ln, limit))
                continue
            if prev is None:
                prev = off + ln
            else:
                if off < prev:
                    bad("%s offset %d < prev end %d (overlap/order)" % (name, off, prev))
                prev = off + ln
        if prev is not None and prev > footer_off:
            bad("last segment end %d > footer_offset %d" % (prev, footer_off))

        if g["manifest_offset"] % MIB:
            bad("manifest_offset %d not 1 MiB aligned" % g["manifest_offset"])
        else:
            ok("manifest_offset %d is 1 MiB aligned" % g["manifest_offset"])
        if (flags & 1) and g["kernel_offset"] % MIB:
            bad("kernel_offset %d not 1 MiB aligned" % g["kernel_offset"])
        elif flags & 1:
            ok("kernel_offset %d is 1 MiB aligned" % g["kernel_offset"])
        if (flags & 2) and g["initrd_offset"] % MIB:
            bad("initrd_offset %d not 1 MiB aligned" % g["initrd_offset"])
        elif flags & 2:
            ok("initrd_offset %d is 1 MiB aligned" % g["initrd_offset"])
        eq("footer_offset 4 KiB aligned", footer_off % KIB, 0)
        eq("file_size == footer_offset + 4096", g["file_size"], footer_off + FOOTER)

        # 6) payload sha256
        for name, off, ln, key in (
            ("rootfs", g["rootfs_offset"], g["rootfs_size"], "rootfs_sha256"),
            ("manifest", g["manifest_offset"], g["manifest_size"], "manifest_sha256"),
        ):
            got = region_sha(f, off, ln)
            eq("%s sha256" % name, got, g[key].hex())
        if flags & 1:
            eq("kernel sha256", region_sha(f, g["kernel_offset"], g["kernel_size"]),
               g["kernel_sha256"].hex())
        if flags & 2:
            eq("initrd sha256", region_sha(f, g["initrd_offset"], g["initrd_size"]),
               g["initrd_sha256"].hex())

        # 7) squashfs superblock cross-check
        f.seek(0)
        sb = f.read(96)
        eq("rootfs superblock magic", sb[0:4], b"hsqs")
        bytes_used = struct.unpack("<Q", sb[40:48])[0]
        eq("rootfs_size == superblock.bytes_used", g["rootfs_size"], bytes_used)

        # 8) manifest semantics + derived fields
        f.seek(g["manifest_offset"])
        mblob = f.read(g["manifest_size"])
        try:
            man = json.loads(mblob.decode("utf-8"))
        except Exception as e:  # noqa: BLE001
            bad("manifest JSON parse: %s" % e)
            man = None
        if isinstance(man, dict):
            eq("manifest.format", man.get("format"), "vmdroid-system-image")
            eq("manifest.format_version", man.get("format_version"), 1)
            img = man.get("image") or {}
            if not ID_RE.match(str(img.get("id") or "")):
                bad("image.id invalid: %r" % img.get("id"))
            else:
                ok("image.id = %s" % img["id"])
            eq("image.arch", img.get("arch"), "arm64")
            caps = man.get("capabilities") or {"ssh": True}
            eq("capabilities.ssh", caps.get("ssh"), True)
            acc = man.get("accounts") or {}
            eq("accounts.ssh_port", acc.get("ssh_port", 22), 22)
            ck = (man.get("checksums") or {}).get("rootfs_sha256")
            eq("manifest.checksums.rootfs_sha256 == footer", ck, g["rootfs_sha256"].hex())
            boot = man.get("boot") or {}
            if flags & 1:
                eq("manifest.boot.kernel_sha256 == footer", boot.get("kernel_sha256"),
                   g["kernel_sha256"].hex())
                ck2 = ((man.get("contract") or {}).get("kernel") or {}).get("image_sha256")
                eq("manifest.contract.kernel.image_sha256 == footer", ck2,
                   g["kernel_sha256"].hex())
            if flags & 2:
                eq("manifest.boot.initrd_sha256 == footer", boot.get("initrd_sha256"),
                   g["initrd_sha256"].hex())

    # 9) whole-file sha256
    fsha = region_sha(path, 0, size)
    if expect_sha:
        eq("whole-file sha256", fsha, expect_sha)
    else:
        ok("whole-file sha256 = %s" % fsha)

    report(path, quiet, file_sha=fsha, flags=flags, segs=segs, footer_off=footer_off)
    return 1 if FAILS else 0


def report(path, quiet, file_sha=None, flags=None, segs=None, footer_off=None):
    if quiet and not FAILS:
        return
    print("== independent_check: %s" % path)
    if segs is not None:
        print("  footer@%d  flags=0x%x  file_size=%d" % (footer_off, flags,
                                                        os.path.getsize(path)))
        for name, off, ln in segs:
            print("    %-8s offset=%-12d size=%d" % (name, off, ln))
    if file_sha:
        print("  file sha256 = %s" % file_sha)
    for line in CHECKS:
        print("  " + line)
    print("  ---> %d checks, %d failed" % (len(CHECKS), len(FAILS)))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
