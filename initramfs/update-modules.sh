#!/bin/sh
# Replace the kernel modules inside an initramfs and/or a mounted rootfs with
# the modules from a kernel release zip.
#
# Usage:
#   ./update-modules.sh <linux-<ver>-sdm660.zip | modroot-dir | modules-dir> \
#                       <initramfs.cpio.gz> [rootfs-mountpoint]
#
# Examples:
#   ./update-modules.sh linux-7.2.3-sdm660.zip arch-initramfs-fsck.gz
#   ./update-modules.sh kernel/out/modroot arch-initramfs-fsck.gz
#   sudo ./update-modules.sh kernel/out/modroot arch-initramfs-fsck.gz /mnt
#
# The first argument may be:
#   * the zip produced by the kernel workflow, containing
#     modroot/usr/lib/modules/<ver>/..., or
#   * the modroot directory itself (kernel/out/modroot), or
#   * the modules directory itself (.../usr/lib/modules/<ver>).
set -eu

[ "$#" -ge 2 ] || {
    echo "usage: $0 <kernel.zip | modroot | modules-dir> <initramfs.cpio.gz> [rootfs-mountpoint]" >&2
    exit 2
}

SRC=$1
INITRD=$2
ROOTMP=${3:-}

# The script cd's into the unpacked initramfs below, so resolve everything to
# absolute paths first (MODSRC is derived from SRC and would otherwise break).
SRC=$(CDPATH= cd -- "$(dirname -- "$SRC")" && pwd)/$(basename -- "$SRC")
INITRD=$(CDPATH= cd -- "$(dirname -- "$INITRD")" && pwd)/$(basename -- "$INITRD")
if [ -n "$ROOTMP" ]; then
    ROOTMP=$(CDPATH= cd -- "$ROOTMP" && pwd)
fi

[ -e "$SRC" ] || { echo "kernel source not found: $SRC" >&2; exit 1; }
[ -f "$INITRD" ] || { echo "initramfs not found: $INITRD" >&2; exit 1; }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

if [ -d "$SRC" ]; then
    echo "==> using module tree from directory $SRC"
    MODSRC=$(find "$SRC" -type d -path '*/usr/lib/modules/*' -name '[0-9]*' -print -quit)
    [ -n "$MODSRC" ] || MODSRC=$(find "$SRC" -maxdepth 2 -type d -name '[0-9]*-*' -print -quit)
    [ -n "$MODSRC" ] || { echo "no modules directory under $SRC" >&2; exit 1; }
else
    echo "==> extracting $SRC"
    unzip -q "$SRC" -d "$TMP"
    MODSRC=$(find "$TMP" -type d -path '*/usr/lib/modules/*' -name '[0-9]*' | head -1)
    [ -n "$MODSRC" ] || { echo "no modules directory in archive" >&2; exit 1; }
fi
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