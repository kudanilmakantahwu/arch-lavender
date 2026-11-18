#!/bin/sh
# Build an ABI-matched patched libgallium for the Adreno 512 (a5xx).
#
# Usage:
#   ./build-libgallium.sh --src /path/to/mesa-26.2.6 [--out FILE] [--check]
#   sudo ./build-libgallium.sh --src /path/to/mesa-26.2.6 --install
#
# The source tree must be Mesa 26.2.6. The script applies
# patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch unless it is already
# applied, builds only src/gallium/targets/dri/libgallium-<ABI>.so, and
# copies it out. --install also stores it in /usr/local/lib/patched and
# replaces the system libgallium, then restarts phosh.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH="$HERE/patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

# The soname must match what the distro libEGL_mesa links against. Arch
# currently uses libgallium-26.2.6-arch1.1.so.
ABI="${ABI_VERSION:-}"
if [ -z "$ABI" ] && [ -r /usr/lib/libEGL_mesa.so.0 ] && command -v readelf >/dev/null 2>&1; then
    ABI=$(readelf -d /usr/lib/libEGL_mesa.so.0 2>/dev/null |
          sed -n 's/.*\[libgallium-\(.*\)\.so\]/\1/p' | head -n 1)
fi
ABI="${ABI:-26.2.6-arch1.1}"

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

[ -n "$SRC" ] || { echo "error: --src /path/to/mesa-26.2.6 is required" >&2; exit 2; }
[ -d "$SRC" ] || { echo "error: source tree not found: $SRC" >&2; exit 2; }
SRC=$(CDPATH= cd -- "$SRC" && pwd)
[ -f "$SRC/VERSION" ] || { echo "error: $SRC does not look like a Mesa tree" >&2; exit 2; }
MESA_VERSION=$(cat "$SRC/VERSION")
case "$MESA_VERSION" in
    26.2.6|26.2.6-*) ;;
    *) echo "error: expected Mesa 26.2.6, found $MESA_VERSION" >&2; exit 2 ;;
esac
[ -f "$PATCH" ] || { echo "error: missing patch $PATCH" >&2; exit 2; }

# Apply the backport unless it is already in the tree. The reverse dry-run
# succeeds exactly when all hunks are already present.
if patch -p1 -R --dry-run -s -f -d "$SRC" < "$PATCH" >/dev/null 2>&1; then
    echo "==> patch already applied"
else
    patch -p1 --dry-run -s -f -d "$SRC" < "$PATCH" >/dev/null || {
        echo "error: the backport does not apply to $SRC" >&2
        exit 1
    }
    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "==> backport applies cleanly"
        exit 0
    fi
    echo "==> applying a5xx 2D-blit/hbb backport"
    patch -p1 -s -f -d "$SRC" < "$PATCH"
fi

[ "$CHECK_ONLY" -eq 1 ] && { echo "==> backport is present"; exit 0; }

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
(
    cd "$SRC"
    meson setup $RECONFIGURE "$BUILD_DIR" \
        --buildtype=release \
        -Dplatforms=wayland,x11 \
        -Dopengl=true \
        -Dgbm=enabled \
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
