#!/bin/sh
# Build an ABI-matched patched libgallium for the Adreno 512 (a5xx).
#
# Usage:
#   ./build-libgallium.sh --src /path/to/mesa-<ver> [--out FILE] [--check]
#   sudo ./build-libgallium.sh --src /path/to/mesa-<ver> --install
#
# The source tree must be Mesa 26.2.6 or 26.3.1. The script applies every
# patch in patches/ unless it is already applied, builds only
# src/gallium/targets/dri/libgallium-<ABI>.so, and copies it out. --install
# also stores it in /usr/local/lib/patched and replaces the system
# libgallium, then restarts phosh.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

# ABI_VERSION overrides the source-version-derived Arch ABI when needed.
ABI="${ABI_VERSION:-}"
SRC=""
OUT=""
DO_INSTALL=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --src)    SRC="$2"; shift 2 ;;
        --out)    OUT="$2"; shift 2 ;;
        --install) DO_INSTALL=1; shift ;;
        --check)  CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$SRC" ] || { echo "error: --src /path/to/mesa-<ver> is required" >&2; exit 2; }
[ -d "$SRC" ] || { echo "error: source tree not found: $SRC" >&2; exit 2; }
SRC=$(CDPATH= cd -- "$SRC" && pwd)
[ -f "$SRC/VERSION" ] || { echo "error: $SRC does not look like a Mesa tree" >&2; exit 2; }
MESA_VERSION=$(cat "$SRC/VERSION")
case "$MESA_VERSION" in
    26.2.6|26.2.6-*|26.3.1|26.3.1-*) ;;
    *) echo "error: expected Mesa 26.2.6 or 26.3.1, found $MESA_VERSION" >&2; exit 2 ;;
esac
if [ -z "$ABI" ]; then
    case "$MESA_VERSION" in
        26.2.6*) ABI=26.2.6-arch1.1 ;;
        26.3.1*) ABI=26.3.1-arch1.1 ;;
    esac
fi

# Apply every backport unless it is already in the tree.  For each patch the
# reverse dry-run succeeds exactly when all of its hunks are already present.
PATCH_FAILED=0
for p in "$HERE"/patches/*.patch; do
    [ -f "$p" ] || continue
    case "$MESA_VERSION:$(basename "$p")" in
        26.2.6*:0002-gallium-dri-advertise-egl-es-bit.patch)
            echo "==> $(basename "$p") is only needed on Mesa 26.3.1; skipping"
            continue
            ;;
    esac
    if patch -p1 -R --dry-run -s -f -d "$SRC" < "$p" >/dev/null 2>&1; then
        echo "==> $(basename "$p") already applied"
        continue
    fi
    if ! patch -p1 --dry-run -s -f -d "$SRC" < "$p" >/dev/null 2>&1; then
        echo "error: $(basename "$p") does not apply to $SRC" >&2
        PATCH_FAILED=1
        continue
    fi
    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "==> $(basename "$p") applies cleanly"
        continue
    fi
    echo "==> applying $(basename "$p")"
    patch -p1 -s -f -d "$SRC" < "$p"
done
[ "$PATCH_FAILED" -eq 0 ] || exit 1

[ "$CHECK_ONLY" -eq 1 ] && { echo "==> all backports applied or applicable"; exit 0; }

# Mesa takes its project version from the VERSION file, not from the
# environment. Set it to the distro ABI version so the soname matches what
# libEGL_mesa links against.
if [ "$(cat "$SRC/VERSION")" != "$ABI" ]; then
    echo "==> setting $SRC/VERSION to $ABI"
    printf '%s\n' "$ABI" > "$SRC/VERSION"
fi

for tool in meson ninja python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool is not installed" >&2
        exit 1
    }
done
python3 -c 'import yaml' 2>/dev/null || {
    echo "error: python-yaml is required (pacman -S python-yaml)" >&2
    exit 1
}

BUILD_DIR="${BUILD_DIR:-$SRC/build-lavender}"
case "$BUILD_DIR" in
    /*) ;;
    *) BUILD_DIR="$(pwd)/$BUILD_DIR" ;;
esac
OUT="${OUT:-$PWD/libgallium-$ABI.so}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

echo "==> configuring Mesa $ABI in $BUILD_DIR"
if [ -d "$BUILD_DIR" ]; then
    RECONFIGURE=--reconfigure
else
    RECONFIGURE=""
fi
# Mesa 26.3's Arch build disables GLES1, which exposes the missing EGL bit
# fixed by patch 0002. Keep that API disabled for 26.3.1. Mesa 26.2.6 keeps
# its historical default, matching the already-tested 26.2.6 prebuilt.
GLES1_ARGS=""
case "$MESA_VERSION" in
    26.3.1*) GLES1_ARGS=-Dgles1=disabled ;;
esac
(
    cd "$SRC"
    meson setup $RECONFIGURE "$BUILD_DIR" \
        --buildtype=release \
        -Dplatforms=wayland,x11 \
        -Dopengl=true \
        $GLES1_ARGS \
        -Dgbm=enabled \\
        -Dgallium-drivers=freedreno \
        -Dvulkan-drivers= \
        -Dglvnd=disabled \
        -Dllvm=disabled \
        -Dbuild-tests=false \
        -Dfreedreno-kmds=msm >/dev/null
)

echo "==> building libgallium-$ABI.so"
ninja -C "$BUILD_DIR" -j "$JOBS" \
    "src/gallium/targets/dri/libgallium-$ABI.so"

mkdir -p "$(dirname "$OUT")"
install -m755 "$BUILD_DIR/src/gallium/targets/dri/libgallium-$ABI.so" "$OUT"
echo "==> wrote $OUT"

if command -v readelf >/dev/null 2>&1; then
    readelf -d "$OUT" | grep -q "SONAME.*libgallium-$ABI.so" || {
        echo "error: $OUT has the wrong soname" >&2
        exit 1
    }
fi

if [ "$DO_INSTALL" -eq 1 ]; then
    [ "$(id -u)" -eq 0 ] || { echo "error: --install needs root" >&2; exit 1; }
    LIB="/usr/lib/libgallium-$ABI.so"
    BACKUP="/usr/local/lib/patched/libgallium-$ABI.so.distro"
    mkdir -p /usr/local/lib/patched
    # Keep the first distro library we replace. Never overwrite it with an
    # already-patched library on a later run.
    if [ -f "$LIB" ] && [ ! -f "$BACKUP" ]; then
        install -m755 "$LIB" "$BACKUP"
        echo "==> saved distro library as $BACKUP"
    fi
    install -m755 "$OUT" "/usr/local/lib/patched/libgallium-$ABI.so"
    install -m755 "$OUT" "$LIB"
    echo "==> installed $LIB"
    systemctl restart phosh.service
    echo "==> restarted phosh.service"
fi
