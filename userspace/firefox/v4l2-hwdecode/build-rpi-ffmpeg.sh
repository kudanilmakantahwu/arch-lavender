#!/bin/sh
# Build jc-kynesim/rpi-ffmpeg (the Raspberry Pi fork that adds DRM-PRIME
# output to the stateful v4l2m2m decoder) into an isolated prefix, so it never
# shadows the distro ffmpeg.
#
# Usage:
#   ./build-rpi-ffmpeg.sh --src /path/to/rpi-ffmpeg --check
#   ./build-rpi-ffmpeg.sh --src /path/to/rpi-ffmpeg [--prefix /opt/rpi-ffmpeg]
#   sudo ./build-rpi-ffmpeg.sh --src /path/to/rpi-ffmpeg --install [--rootfs DIR]
#
# Why a fork: Firefox's Linux media stack only accepts the stateful
# `h264_v4l2m2m` wrapper when the decoder hands back DRM-PRIME (dmabuf)
# frames.  Upstream ffmpeg returns plain memory-mapped frames, so Firefox logs
# "Got non-DRM-PRIME frame from FFmpeg V4L2" and silently falls back to
# software (Mozilla bug 1852765).  The Raspberry Pi fork implements the
# DRM-PRIME output that the qcom-venus stateful decoder and Firefox both need.
#
# The result is installed to a private prefix (default /opt/rpi-ffmpeg):
#
#   * /usr/lib/libavcodec.so.63 is never touched, so every other program keeps
#     using the distro ffmpeg;
#   * Firefox 159's FFmpegRuntimeLinker dlopens the newest soname first
#     (libavcodec.so.63), so the prefix also carries libavcodec.so.62 and
#     libavcodec.so.63 symlinks to the built libavcodec.so.61.  Only processes
#     that put the prefix on LD_LIBRARY_PATH (the /usr/local/bin/firefox
#     wrapper) can see them.
#
# Obtaining the source:
#   git clone --depth 1 --branch test/7.1.5/main \
#       https://github.com/jc-kynesim/rpi-ffmpeg.git
#   (the fork's default branch `master` is old ffmpeg 4.4; the 7.1.5 code that
#    Arch Linux ARM's `ffmpeg-rpi` package builds from is `test/7.1.5/main`.)
#
# See README.md and docs/FINDINGS.md section I.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

PREFIX="${RPI_FFMPEG_PREFIX:-/opt/rpi-ffmpeg}"
SRC=""
ROOTFS=""
DO_INSTALL=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --src)    SRC="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --install) DO_INSTALL=1; shift ;;
        --check)  CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$SRC" ] || { echo "error: --src /path/to/rpi-ffmpeg is required" >&2; exit 2; }
[ -d "$SRC" ] || { echo "error: source tree not found: $SRC" >&2; exit 2; }
SRC=$(CDPATH= cd -- "$SRC" && pwd)
[ -f "$SRC/configure" ] && [ -f "$SRC/libavcodec/v4l2_buffers.c" ] || {
    echo "error: $SRC does not look like an ffmpeg tree" >&2; exit 2
}

echo "==> checking $SRC for the DRM-PRIME v4l2m2m patches"
if grep -q 'AV_PIX_FMT_DRM_PRIME' "$SRC/libavcodec/v4l2_buffers.c"; then
    echo "    libavcodec/v4l2_buffers.c: AV_PIX_FMT_DRM_PRIME present"
else
    echo "error: $SRC is upstream ffmpeg, not the rpi-ffmpeg fork" >&2
    echo "       (no AV_PIX_FMT_DRM_PRIME in libavcodec/v4l2_buffers.c)" >&2
    exit 1
fi
if grep -q 'V4L2_MEMORY_DMABUF' "$SRC/libavcodec/v4l2_buffers.c" 2>/dev/null; then
    echo "    libavcodec/v4l2_buffers.c: V4L2_MEMORY_DMABUF present"
fi

AVCODEC_MAJOR=$(sed -n 's/^#define LIBAVCODEC_VERSION_MAJOR[[:space:]]*//p' \
    "$SRC/libavcodec/version_major.h" 2>/dev/null | head -n1)
echo "    LIBAVCODEC_VERSION_MAJOR=${AVCODEC_MAJOR:-unknown}"

[ "$CHECK_ONLY" -eq 1 ] && { echo "==> source looks usable"; exit 0; }

for tool in cc make pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool is not installed" >&2; exit 1
    }
done
if [ ! -f /usr/include/libdrm/drm_fourcc.h ] &&
   [ ! -f /usr/include/drm/drm_fourcc.h ]; then
    echo "warning: libdrm headers not found; --enable-libdrm may disable itself" >&2
    echo "         (install the distro libdrm package)" >&2
fi

if [ "$DO_INSTALL" -eq 1 ]; then
    [ "$(id -u)" -eq 0 ] || { echo "error: --install needs root" >&2; exit 1; }
fi

if [ -n "$ROOTFS" ]; then
    [ -d "$ROOTFS" ] || { echo "error: rootfs not found: $ROOTFS" >&2; exit 2; }
    DESTDIR="$ROOTFS"
    DEST="$ROOTFS$PREFIX"
else
    DESTDIR=""
    DEST="$PREFIX"
fi

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

echo "==> configuring (prefix=$PREFIX)"
cd "$SRC"
./configure \
    --prefix="$PREFIX" \
    --enable-shared --disable-static --disable-programs --disable-doc \
    --enable-libdrm --enable-v4l2-m2m

echo "==> config check (v4l2/drm)"
grep -iE 'CONFIG_(V4L2_M2M|LIBDRM)' config.h 2>/dev/null || true

echo "==> building (-j$JOBS)"
make -j"$JOBS"

echo "==> installing to $DEST"
if [ -n "$DESTDIR" ]; then
    make install DESTDIR="$DESTDIR"
else
    make install
fi

# Firefox tries libavcodec.so.63, then .62, then .61.  Shadow the two newer
# sonames with the library we just built; the shadows live only in this
# prefix and are only visible with LD_LIBRARY_PATH set.
if [ -n "$AVCODEC_MAJOR" ]; then
    mkdir -p "$DEST/lib"
    for shadow in 62 63; do
        [ "$shadow" -gt "$AVCODEC_MAJOR" ] 2>/dev/null || continue
        ln -sf "libavcodec.so.$AVCODEC_MAJOR" "$DEST/lib/libavcodec.so.$shadow"
    done
fi

echo "==> installed libraries"
ls -1 "$DEST/lib" 2>/dev/null | grep -E '^lib' | head -30

echo "==> dependency check"
if command -v ldd >/dev/null 2>&1 && [ -n "$AVCODEC_MAJOR" ]; then
    if LD_LIBRARY_PATH="$DEST/lib" ldd "$DEST/lib/libavcodec.so.$AVCODEC_MAJOR" 2>/dev/null |
       grep -q 'not found'; then
        echo "warning: some dependencies of libavcodec do not resolve on this host" >&2
        LD_LIBRARY_PATH="$DEST/lib" ldd "$DEST/lib/libavcodec.so.$AVCODEC_MAJOR" 2>/dev/null |
            grep 'not found' >&2 || true
    else
        echo "    all libavcodec dependencies resolve"
    fi
fi

echo "==> done: $DEST/lib"
echo "    Firefox wrapper: userspace/firefox/v4l2-hwdecode/bin/firefox (FFMPEG_LIBDIR=$PREFIX/lib)"
