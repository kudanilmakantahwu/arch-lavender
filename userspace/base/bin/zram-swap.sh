#!/bin/sh
# Create a zram swap device sized to half of RAM and turn it on.
#
# zram-generator is not installed in the shipped rootfs, so do directly what
# it would do.  The kernel has CONFIG_ZRAM=y and zstd is the default
# compression algorithm on this build.
#
# Swap in RAM is compressed, so a 2.8 GB swap device on a 6 GB phone uses far
# less than 2.8 GB of actual memory.  Without any swap, one program filling
# RAM freezes the phone for minutes.
set -u

modprobe zram 2>/dev/null || true

if grep -q '^/dev/zram0' /proc/swaps 2>/dev/null; then
    exit 0
fi

ram_mb=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
size_mb=$(( ram_mb / 2 ))
[ "$size_mb" -lt 512 ] && size_mb=512

dev=$(zramctl --find --size "${size_mb}M" --algorithm zstd 2>/dev/null) ||
dev=$(zramctl --find --size "${size_mb}M" 2>/dev/null) || dev=""
if [ -z "$dev" ] || [ ! -b "$dev" ]; then
    echo "zram: could not create a zram device" >&2
    exit 1
fi

mkswap "$dev" >/dev/null 2>&1 || { echo "zram: mkswap failed on $dev" >&2; exit 1; }
swapon --priority 100 "$dev" || { echo "zram: swapon failed on $dev" >&2; exit 1; }

# The kernel's own guidance for zram-backed swap.
sysctl -q -w vm.swappiness=100 2>/dev/null || true
sysctl -q -w vm.page-cluster=0 2>/dev/null || true

echo "zram: ${dev} ${size_mb}M (zstd) enabled"
