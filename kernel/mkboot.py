#!/usr/bin/env python3
"""Create a legacy (header v0) Android boot image for xiaomi-lavender.

The Redmi Note 7 bootloader (ABL) expects the device tree concatenated after
the kernel image (the `Image.gz-dtb` convention).  The bootloader finds the
FDT by scanning for its magic, so no kernel option is involved; this script
appends the DTB and builds a mkbootimg-compatible v0 header from scratch, so
it does not depend on a reference boot.img or on the Android tools being
installed.

Layout produced:

    [header page(s)][kernel + dtb][ramdisk][second]

The defaults below are the values that actually boot on this device and were
read back from a working boot image.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys

PAGE = 4096
MAGIC = b"ANDROID!"

# Defaults proven on the device.
DEF_KERNEL_ADDR = 0x00008000
DEF_RAMDISK_ADDR = 0x01000000
DEF_SECOND_ADDR = 0x00F00000
DEF_TAGS_ADDR = 0x00000100
DEF_CMDLINE = "console=tty0 loglevel=7 rootwait rw"


def _pad(data: bytes, page: int = PAGE) -> bytes:
    if not data:
        return b""
    n = (len(data) + page - 1) // page * page
    return data + b"\x00" * (n - len(data))


def _read(path: str) -> bytes:
    with open(path, "rb") as fh:
        return fh.read()


def _sha1(data: bytes) -> bytes:
    return hashlib.sha1(data).digest()


def build_header(
    kernel_size: int,
    ramdisk_size: int,
    second_size: int,
    kernel_addr: int,
    ramdisk_addr: int,
    second_addr: int,
    tags_addr: int,
    page_size: int,
    cmdline: str,
    name: str,
    image_id: bytes,
) -> bytes:
    header = bytearray(page_size)
    header[0:8] = MAGIC
    struct.pack_into("<I", header, 8, kernel_size)
    struct.pack_into("<I", header, 12, kernel_addr)
    struct.pack_into("<I", header, 16, ramdisk_size)
    struct.pack_into("<I", header, 20, ramdisk_addr)
    struct.pack_into("<I", header, 24, second_size)
    struct.pack_into("<I", header, 28, second_addr)
    struct.pack_into("<I", header, 32, tags_addr)
    struct.pack_into("<I", header, 36, page_size)
    struct.pack_into("<I", header, 40, 0)  # header_version
    struct.pack_into("<I", header, 44, 0)  # os_version

    header[48:48 + 16] = name.encode("ascii", "strict")[:15].ljust(16, b"\x00")
    header[64:64 + 512] = cmdline.encode("ascii", "strict")[:511].ljust(512, b"\x00")
    header[576:608] = image_id.ljust(32, b"\x00")
    return bytes(header)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kernel", required=True, help="Image.gz (compressed kernel)")
    ap.add_argument("--dtb", required=True, help="board .dtb to append")
    ap.add_argument("--ramdisk", required=True, help="initramfs cpio.gz")
    ap.add_argument("--out", required=True, help="output boot image")
    ap.add_argument("--cmdline", default=DEF_CMDLINE)
    ap.add_argument("--name", default="")
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0)
    ap.add_argument("--kernel-offset", type=lambda x: int(x, 0), default=DEF_KERNEL_ADDR)
    ap.add_argument("--ramdisk-offset", type=lambda x: int(x, 0), default=DEF_RAMDISK_ADDR)
    ap.add_argument("--second-offset", type=lambda x: int(x, 0), default=DEF_SECOND_ADDR)
    ap.add_argument("--tags-offset", type=lambda x: int(x, 0), default=DEF_TAGS_ADDR)
    ap.add_argument("--pagesize", type=int, default=PAGE)
    ap.add_argument("--second", default=None, help="optional second stage")
    args = ap.parse_args(argv)

    kernel = _read(args.kernel)
    dtb = _read(args.dtb)
    ramdisk = _read(args.ramdisk)
    second = _read(args.second) if args.second else b""

    # The bootloader passes the appended DTB to the kernel.
    kernel_dtb = kernel + dtb

    # Same ID algorithm as AOSP mkbootimg for header v0.
    sha = hashlib.sha1()
    sha.update(_sha1(kernel_dtb))
    sha.update(_sha1(ramdisk))
    sha.update(_sha1(second))
    image_id = sha.digest()

    header = build_header(
        kernel_size=len(kernel_dtb),
        ramdisk_size=len(ramdisk),
        second_size=len(second),
        kernel_addr=args.base + args.kernel_offset,
        ramdisk_addr=args.base + args.ramdisk_offset,
        second_addr=(args.base + args.second_offset) if second else 0,
        tags_addr=args.base + args.tags_offset,
        page_size=args.pagesize,
        cmdline=args.cmdline,
        name=args.name,
        image_id=image_id,
    )

    out = header + _pad(kernel_dtb, args.pagesize) + _pad(ramdisk, args.pagesize) + _pad(second, args.pagesize)
    with open(args.out, "wb") as fh:
        fh.write(out)

    print(f"kernel:  {len(kernel):>10} bytes + dtb {len(dtb)} = {len(kernel_dtb)}")
    print(f"ramdisk: {len(ramdisk):>10} bytes")
    print(f"second:  {len(second):>10} bytes")
    print(f"total:   {len(out):>10} bytes -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))