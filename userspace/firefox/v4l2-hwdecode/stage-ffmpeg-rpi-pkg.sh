#!/bin/sh
# Stage the prebuilt Arch Linux ARM `ffmpeg-rpi` package into the isolated
# prefix used by the Firefox venus wrapper.
#
# Usage:
#   ./stage-ffmpeg-rpi-pkg.sh --pkg ffmpeg-rpi-7.1.5-4-aarch64.pkg.tar.xz
#   sudo ./stage-ffmpeg-rpi-pkg.sh --pkg ffmpeg-rpi-....pkg.tar.xz --rootfs DIR
#
# `ffmpeg-rpi` is built from the same jc-kynesim/rpi-ffmpeg 7.1.5 source as
# build-rpi-ffmpeg.sh, already compiled for aarch64 (libavcodec.so.61 with the
# DRM-PRIME v4l2m2m output).  This is the offline path: use it when the fork
# cannot be cloned or built (no network, no cross toolchain).
#
# The package installs its libraries under usr/lib and its bare runtime links
# under usr/lib/ffmpeg-rpi.  This script collects the versioned libraries into
# <dest>/lib, recreates the <major> symlinks, and adds the libavcodec.so.62 /
# libavcodec.so.63 shadows that Firefox 159 looks for first.  Like
# build-rpi-ffmpeg.sh it never writes to /usr/lib, so the distro ffmpeg 9.x
# keeps working for every other program.
#
# Only `ffmpeg-rpi` ships the versioned libraries under usr/lib; the split
# `ffmpeg-rpi-bin` package only carries the command-line programs.
#
# See README.md and docs/FINDINGS.md section I.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

DEST="${RPI_FFMPEG_PREFIX:-/opt/rpi-ffmpeg}"
PKG=""
ROOTFS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --pkg)    PKG="$2"; shift 2 ;;
        --dest)   DEST="$2"; shift 2 ;;
        --rootfs) ROOTFS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$PKG" ] || { echo "error: --pkg <ffmpeg-rpi-*.pkg.tar.xz> is required" >&2; exit 2; }
[ -f "$PKG" ] || { echo "error: package not found: $PKG" >&2; exit 2; }

if [ -n "$ROOTFS" ]; then
    [ -d "$ROOTFS" ] || { echo "error: rootfs not found: $ROOTFS" >&2; exit 2; }
    TARGET="$ROOTFS$DEST"
else
    TARGET="$DEST"
fi

command -v bsdtar >/dev/null 2>&1 || command -v tar >/dev/null 2>&1 || {
    echo "error: bsdtar or tar is required" >&2; exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "==> extracting $PKG"
if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$PKG" -C "$TMP"
else
    tar -xf "$PKG" -C "$TMP"
fi
[ -d "$TMP/usr/lib" ] || { echo "error: no usr/lib in $PKG" >&2; exit 1; }

echo "==> staging libraries into $TARGET/lib"
mkdir -p "$TARGET/lib"
# Versioned payload and its <major> links, straight from usr/lib.  The bare
# `lib*.so` linker links under usr/lib/ffmpeg-rpi point outside the package
# root, so they are intentionally not copied.
for f in "$TMP"/usr/lib/libav*.so* "$TMP"/usr/lib/libsw*.so* \
         "$TMP"/usr/lib/libpostproc*.so*; do
    [ -e "$f" ] || continue
    cp -a "$f" "$TARGET/lib/"
done

AVCODEC_MAJOR=$(ls -1 "$TARGET/lib"/libavcodec.so.*.* 2>/dev/null | head -n1 |
    sed -n 's/^.*libavcodec\.so\.\([0-9][0-9]*\)\..*$/\1/p')
[ -n "$AVCODEC_MAJOR" ] || { echo "error: no libavcodec.so.<major> staged" >&2; exit 1; }
echo "    libavcodec major = $AVCODEC_MAJOR"

for shadow in 62 63; do
    [ "$shadow" -gt "$AVCODEC_MAJOR" ] || continue
    ln -sf "libavcodec.so.$AVCODEC_MAJOR" "$TARGET/lib/libavcodec.so.$shadow"
done

echo "==> staged"
ls -1 "$TARGET/lib" | grep -E '^lib' | head -30

echo "==> DRM-PRIME check"
REAL=$(readlink -f "$TARGET/lib/libavcodec.so.$AVCODEC_MAJOR" 2>/dev/null ||
       echo "$TARGET/lib/libavcodec.so.$AVCODEC_MAJOR")
if command -v strings >/dev/null 2>&1; then
    if strings -a "$REAL" | grep -q 'requesting formats: output='; then
        echo "    v4l2m2m DRM-PRIME code present"
    else
        echo "warning: could not find the DRM-PRIME v4l2m2m strings in $REAL" >&2
    fi
fi

echo "==> dependency check"
if command -v ldd >/dev/null 2>&1; then
    if LD_LIBRARY_PATH="$TARGET/lib" ldd "$REAL" 2>/dev/null | grep -q 'not found'; then
        echo "warning: unresolved dependencies (host may lack Arch ARM packages):" >&2
        LD_LIBRARY_PATH="$TARGET/lib" ldd "$REAL" 2>/dev/null | grep 'not found' >&2 || true
    else
        echo "    all libavcodec dependencies resolve"
    fi
fi

echo "==> done: $TARGET/lib"
