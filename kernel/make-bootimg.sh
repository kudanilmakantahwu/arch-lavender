#!/bin/sh
# Rebuild the Android boot image from a kernel + appended DTB + initramfs.
#
# Usage:
#   ./make-bootimg.sh <Image.gz> <board.dtb> <initramfs.cpio.gz> <out.img>
#
# The Redmi Note 7 bootloader (ABL) needs the DTB appended to the kernel
# image and mangles the command line, so the initramfs is responsible for
# finding the root filesystem.  The addresses and page size below are the
# ones that boot on this device.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ "$#" -eq 4 ] || {
    echo "usage: $0 <Image.gz> <board.dtb> <initramfs.cpio.gz> <out.img>" >&2
    exit 2
}

exec python3 "$HERE/mkboot.py" \
    --kernel "$1" \
    --dtb "$2" \
    --ramdisk "$3" \
    --out "$4" \
    --cmdline "console=tty0 loglevel=7 rootwait rw"