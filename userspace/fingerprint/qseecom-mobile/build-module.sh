#!/bin/sh
# Build the out-of-tree qcom_qseecom_mobile.ko (/dev/qseecom_mobile) for the
# lavender kernel (7.2.3-sdm660, built with Clang/LLVM + kCFI).
#
# Upstream driver: nyl/linux-qseecom-mobile, by Nitescu Ion Laurentiu
# <contact@nyl.ro>, GPL-2.0-or-later (per the source-file SPDX headers; the repo
# has no top-level LICENSE file). This script only clones it at a pinned commit,
# applies the local Clang-23 fix, and builds it. All driver credit is upstream's.
#
# The upstream driver talks to Qualcomm QSEE Trusted Applications over SMCCC
# and qcom_tzmem. Two things are needed to build it here:
#   * the exact kernel toolchain (Clang 23.1.5), which ships in the same
#     container image the kernel itself is built with (kernel/build.sh);
#   * one one-line source fix, because Clang 23 rejects passing the driver's
#     layout-identical mirror structs to the kernel's function pointer.
#
# Usage:
#   ./build-module.sh [--kdir DIR] [--src DIR] [--out FILE] [--image IMG]
#
# Defaults:
#   --kdir  the prebuilt kernel tree under kernel/src/linux-* (kernel/src is
#           gitignored; run kernel/build.sh first)
#   --src   /tmp/qcom-qseecom-mobile-src  (cloned from upstream, pinned commit)
#   --out   prebuilt/qcom_qseecom_mobile.ko
#   --image kbuild-edge:7.2.3  (the Clang 23.1.5 build image)
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)

# Upstream: https://github.com/nyl/linux-qseecom-mobile
UPSTREAM="https://github.com/nyl/linux-qseecom-mobile.git"
COMMIT="fa3b0702a77e2a808fe53c0b108279dba434f9d5"

KDIR=""
SRC="/tmp/qcom-qseecom-mobile-src"
OUT="$HERE/prebuilt/qcom_qseecom_mobile.ko"
IMAGE="kbuild-edge:7.2.3"

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kdir)  KDIR="$2"; shift 2 ;;
        --src)   SRC="$2"; shift 2 ;;
        --out)   OUT="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Locate the kernel build tree if not given.
if [ -z "$KDIR" ]; then
    KDIR=$(find "$ROOT/kernel/src" -maxdepth 1 -type d -name 'linux-*' 2>/dev/null | head -1)
fi
[ -n "$KDIR" ] && [ -f "$KDIR/Module.symvers" ] || {
    echo "ERROR: kernel tree not found or not built (need Module.symvers)." >&2
    echo "       Build it first with kernel/build.sh, or pass --kdir." >&2
    exit 1
}
echo "kernel tree: $KDIR"

# Clone the upstream driver at the pinned commit and apply the local patch.
if [ ! -d "$SRC/.git" ]; then
    echo "cloning $UPSTREAM -> $SRC"
    git clone "$UPSTREAM" "$SRC"
fi
git -C "$SRC" fetch --all --quiet || true
git -C "$SRC" checkout --quiet "$COMMIT"
for P in "$HERE"/patches/*.patch; do
    echo "applying $(basename "$P")"
    git -C "$SRC" apply "$P"
done

MODDIR="$SRC/qcom-qseecom-mobile"
mkdir -p "$(dirname "$OUT")"

echo "building with $IMAGE (Clang 23.1.5) ..."
docker run --rm \
    -v "$KDIR":/kbuild \
    -v "$MODDIR":/mod \
    -v "$(dirname "$OUT")":/out \
    "$IMAGE" sh -c '
        set -e
        clang --version | head -1
        make -C /kbuild M=/mod ARCH=arm64 LLVM=1 -j"$(nproc)" modules
        cp /mod/qcom_qseecom_mobile.ko /out/
    '

echo "built: $OUT"
sha256sum "$OUT"
