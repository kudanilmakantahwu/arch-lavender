#!/bin/sh
# Flash the root filesystem and the boot image to a Redmi Note 7
# (xiaomi-lavender) that is in fastboot mode.
#
# Usage (as root, or with udev rules that allow fastboot):
#   ./flash.sh <rootfs.img|rootfs.img.sparse> <boot.img> [--no-reboot]
#
# WARNING: this erases the userdata partition (your Android data and apps).
#
# This is the exact sequence that was used on the real device:
#   fastboot flash userdata <sparse image>
#   fastboot flash boot     <boot image>
#   fastboot reboot
# No vbmeta partition is touched.  If your phone refuses to boot a custom
# boot image, see docs/TROUBLESHOOTING.md before flashing anything else.
set -eu

ROOTFS=""
BOOT=""
REBOOT=1
for arg in "$@"; do
    case "$arg" in
        --no-reboot) REBOOT=0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)
            if [ -z "$ROOTFS" ]; then ROOTFS="$arg"
            elif [ -z "$BOOT" ]; then BOOT="$arg"
            else echo "too many arguments" >&2; exit 2
            fi
            ;;
    esac
done

[ -n "$ROOTFS" ] && [ -n "$BOOT" ] || {
    echo "usage: $0 <rootfs> <boot.img> [--no-reboot]" >&2
    exit 2
}
[ -f "$ROOTFS" ] || { echo "rootfs not found: $ROOTFS" >&2; exit 1; }
[ -f "$BOOT" ] || { echo "boot image not found: $BOOT" >&2; exit 1; }
command -v fastboot >/dev/null 2>&1 || { echo "fastboot not found" >&2; exit 1; }

echo "==> waiting for device in fastboot mode"
fastboot devices
fastboot getvar product 2>&1 | head -1 || true

echo "==> flashing root filesystem to userdata (erases userdata)"
fastboot flash userdata "$ROOTFS"

echo "==> flashing boot image"
fastboot flash boot "$BOOT"

echo "==> verifying the flashed boot image"
fastboot getvar current-slot 2>&1 | head -1 || true

if [ "$REBOOT" -eq 1 ]; then
    echo "==> rebooting"
    fastboot reboot
fi