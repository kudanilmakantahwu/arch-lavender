#!/bin/sh
# Replace the kernel modules inside an initramfs and/or a mounted rootfs with
# the modules from a kernel release zip.
#
# Usage:
#   ./update-modules.sh <linux-<ver>-sdm660.zip> <initramfs.cpio.gz> [rootfs-mountpoint]
#
# Examples:
#   ./update-modules.sh linux-7.2.3-sdm660.zip arch-initramfs-fsck.gz
#   sudo ./update-modules.sh linux-7.2.3-sdm660.zip arch-initramfs-fsck.gz /mnt
#
# The zip produced by the kernel workflow contains:
#   modroot/usr/lib/modules/<ver>/...
# which is exactly the layout Arch Linux uses.
set -eu

[ "$#" -ge 2 ] || {
    echo "usage: $0 <kernel.zip> <initramfs.cpio.gz> [rootfs-mountpoint]" >&2
    exit 2
}

ZIP=$1
INITRD=$2
ROOTMP=${3:-}

[ -f "$ZIP" ] || { echo "kernel zip not found: $ZIP" >&2; exit 1; }
[ -f "$INITRD" ] || { echo "initramfs not found: $INITRD" >&2; exit 1; }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

echo "==> extracting $ZIP"
unzip -q "$ZIP" -d "$TMP"

MODSRC=$(find "$TMP" -type d -path '*/usr/lib/modules/*' -name '[0-9]*' | head -1)
[ -n "$MODSRC" ] || { echo "no modules directory in zip" >&2; exit 1; }
KVER=$(basename "$MODSRC")
echo "==> kernel version: $KVER"

if [ -n "$ROOTMP" ]; then
    echo "==> installing modules into $ROOTMP/usr/lib/modules/$KVER"
    mkdir -p "$ROOTMP/usr/lib/modules"
    rm -rf "$ROOTMP/usr/lib/modules/$KVER"
    cp -a "$MODSRC" "$ROOTMP/usr/lib/modules/$KVER"
fi

echo "==> unpacking initramfs"
RD="$TMP/rd"
mkdir -p "$RD"
cd "$RD"
gzip -dc "$INITRD" | cpio -idmu --quiet 2>/dev/null || true

echo "==> replacing modules in initramfs"
rm -rf "$RD/usr/lib/modules/$KVER"
mkdir -p "$RD/usr/lib/modules"
cp -a "$MODSRC" "$RD/usr/lib/modules/$KVER"

# depmod needs the same layout; use the host depmod if available.
if command -v depmod >/dev/null 2>&1; then
    depmod -b "$RD/usr" "$KVER" 2>/dev/null || true
fi

echo "==> repacking initramfs"
OUT="$TMP/initramfs-new.gz"
find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUT"

# Replace the original only after the new one is complete.
cp "$OUT" "$INITRD"
echo "==> wrote $INITRD"
ls -lh "$INITRD"