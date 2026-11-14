#!/bin/sh
# Build the sdm660-mainline kernel inside an Alpine container.
# Runs as root inside `alpine:edge`, with the repo mounted at /work.
#
# The running kernel is 7.2.3 from the `qcom-sdm660-7.2.y` branch.  The six
# patches in kernel/patches/ are already upstream in this tree, so they are
# skipped by default.  Set APPLY_PATCHES=1 when building an older tag that
# still needs them.
set -eu

KVER="7.2.3"
KCOMMIT="e9b7cc51f7944f3be7ac69dcf5caabc2429510dc"
FLAVOR="postmarketos-qcom-sdm660"
TARBALL="linux-${KVER}-sdm660.tar.gz"
URL="https://github.com/sdm660-mainline/linux/archive/${KCOMMIT}.tar.gz"
SHA256="73564840ad5c0904aa65fdc9ba05e807c34406337c42da8f3983155f354b333f"
APPLY_PATCHES="${APPLY_PATCHES:-0}"

WORK=/work
SRC="$WORK/src"
OUT="$WORK/out"

echo "== toolchain =="
apk add --no-cache \
	bash bc bison build-base ccache \
	clang lld llvm \
	curl dtc elfutils-dev findutils flex kmod linux-headers \
	openssl openssl-dev pahole patch perl python3 tar xz zstd
clang --version | head -1
ld.lld --version | head -1

mkdir -p "$SRC" "$OUT"
cd "$SRC"

if [ ! -f "$TARBALL" ]; then
	echo "== download $KCOMMIT =="
	curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$URL"
fi
echo "$SHA256  $TARBALL" | sha256sum -c -

echo "== extract =="
tar -xzf "$TARBALL"
BUILD="$SRC/linux-${KCOMMIT}"
[ -d "$BUILD" ] || BUILD="$(find "$SRC" -maxdepth 1 -type d -name 'linux-*' | head -1)"
echo "builddir: $BUILD"
cd "$BUILD"

if [ "$APPLY_PATCHES" -eq 1 ]; then
	echo "== apply patches =="
	NPATCH=0
	for PATCH in $(find "$WORK/patches" -maxdepth 1 -name '*.patch' | sort); do
		echo "applying: $PATCH"
		patch -p1 --batch --forward --silent < "$PATCH" || true
		NPATCH=$((NPATCH + 1))
	done
	[ "$NPATCH" -gt 0 ] || { echo "no patch found" >&2; exit 1; }
	if find . -name '*.rej' | grep -q .; then
		echo "ERROR: patch(es) rejected:" >&2
		find . -name '*.rej' >&2
		exit 1
	fi
	echo "applied $NPATCH patch(es)"
else
	echo "== patches: skipped (kernel ${KVER} already contains the a5xx/wifi fixes) =="
fi

# Local patches are always applied: they carry device support that is not
# upstream in this kernel tree (currently the MAX98937 speaker amplifier and
# the lavender audio device-tree nodes).
echo "== apply local patches =="
for PATCH in $(find "$WORK/patches/local" -maxdepth 1 -name '*.patch' | sort); do
	echo "applying: $PATCH"
	patch -p1 --batch --forward --silent < "$PATCH"
done
if find . -name '*.rej' | grep -q .; then
	echo "ERROR: local patch(es) rejected:" >&2
	find . -name '*.rej' >&2
	exit 1
fi

echo "== config =="
cp -v "$WORK/config/config-${FLAVOR}.aarch64" .config
make ARCH=arm64 LLVM=1 olddefconfig

echo "== build =="
make -j"$(nproc)" ARCH=arm64 LLVM=1 \
	KBUILD_BUILD_VERSION=1 all Image.gz modules

echo "== install modules =="
make ARCH=arm64 LLVM=1 \
	INSTALL_MOD_PATH="$OUT/modroot/usr" \
	INSTALL_MOD_STRIP=1 \
	modules_install

echo "== install dtbs =="
make ARCH=arm64 LLVM=1 INSTALL_DTBS_PATH="$OUT/dtbs" dtbs_install

echo "== depmod (guard against empty dependency lists) =="
MODDIR="$OUT/modroot/usr/lib/modules/${KVER}-sdm660"
depmod -b "$OUT/modroot/usr" "${KVER}-sdm660"
grep -E 'ath10k_snoc\.ko[^:]*: .*ath10k_core\.ko' "$MODDIR/modules.dep" \
	&& echo "depmod OK" \
	|| { echo "ERROR: modules.dep incomplete (empty deps)" >&2; exit 1; }

echo "== collect =="
cp -v arch/arm64/boot/Image.gz "$OUT/vmlinuz"
cp -v arch/arm64/boot/vmlinuz.efi "$OUT/vmlinuz.efi"
cp -v System.map "$OUT/System.map"

MSM="$OUT/modroot/usr/lib/modules/${KVER}-sdm660/kernel/drivers/gpu/drm/msm/msm.ko.zst"
if [ ! -f "$MSM" ]; then
	MSM="$(find "$OUT/modroot" -name 'msm.ko*' | head -1)"
fi
echo "== msm module =="
ls -l "$MSM"
sha256sum "$MSM"

echo "== version =="
cat include/config/kernel.release
strings "$OUT/vmlinuz" | grep -m1 -E "^${KVER}-sdm660" || true

echo "== done =="
du -sh "$OUT"
