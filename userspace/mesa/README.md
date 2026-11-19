# Mesa a5xx 2D-blit fix

This directory carries the userspace Mesa fix for the Adreno 512 (a512 /
FD512) glyph and texture loss. The GPU, the kernel driver (`msm`), and the
firmware are fine; the bug is in Mesa's a5xx 2D blitter, so it must be fixed
in `libgallium`, not in the kernel tree.

Mesa 26.2.7's Vulkan path exposed a **separate** kernel oops in the a5xx
VM_BIND handling (`adreno_get_param+0x12c`, then a GPU hangcheck).  That is
fixed by `kernel/patches/local/0002-drm-msm-reject-vm-bind-without-private-vm.patch`;
see [`docs/BUILD-KERNEL.md`](../../docs/BUILD-KERNEL.md).  It does not fix the
glyph loss, and this Mesa backport does not fix the VM_BIND crash: both are
needed on 26.2.7.

## What is broken

On a512/FD512, `CP_BLIT(BLIT_OP_COPY)` silently performs no memory write and
reports no fault. Mesa's staging upload path uses that copy for
`glTexSubImage2D` when the destination texture is still referenced by an
unflushed batch. The upload is lost, which shows up as missing glyphs and
black texture tiles (the About logo, browser text, atlas pages).

The upstream fix is MR !45483:

| Commit | Subject |
| --- | --- |
| `ba27232` | freedreno/registers: make the 2D blit ifmt enums common |
| `a5c42c0` | freedreno/a5xx: convert 2D blits through the right intermediate format |
| `c0235ef` | freedreno/a5xx: program the 2D source and use BLIT_OP_SCALE |

`c0235ef` describes the a512 no-op and switches the copy sites to
`BLIT_OP_SCALE`. Mesa 26.2.6 and 26.2.7 do not contain it; 26.3 will.

The backport also carries two highest-bank-bit commits
(`d4b6701`, `4fa3294`). They are a separate fix, but the tested lab
`libgallium` was built with them, so they are kept in the same patch to make
the binary reproducible.

`patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch` is a rebase of those five
commits against Mesa 26.2.6; it also applies cleanly to 26.2.7.  Use
`patch -p1` or `git apply`.

Two prebuilt, ABI-matched libraries are carried: `libgallium-26.2.6-arch1.1.so`
for the v1.1 release image and `libgallium-26.2.7-arch1.1.so` for images
upgraded to Arch's Mesa `1:26.2.7-1`. Both hashes are in `SHA256SUMS` and both
passed the system-wide 3x50 stress in `docs/FINDINGS.md`. Install the one the
distro `libEGL_mesa.so.0` asks for. The patch and build script are the source
of truth; rebuild when the rootfs Mesa soname changes.

## Build the patched libgallium

The build must match the distro ABI exactly. The v1.1 release image needs
`libgallium-26.2.6-arch1.1.so`; a phone that ran `pacman -Syu` may need
`26.2.7-arch1.1` (Arch `mesa 1:26.2.7-1`). The script reads the needed soname
from `libEGL_mesa` and uses the matching source version. Three details are
easy to get wrong:

- without setting Mesa's `VERSION` file to the distro ABI version the soname
  is wrong and the compositor keeps the old library; the script does this
  automatically;
- without `-Dplatforms=wayland,x11` the library lacks `loader_dri3_*` and
  phoc dies with `EGL_EXT_platform_base not supported`;
- without `-Dopengl=true` the library exposes only OpenGL ES and Qt apps
  (Angelfish) abort in `QSGRenderLoop::handleContextCreationFailure`.

The script sets all of them:

```sh
sudo pacman -S --needed base-devel meson ninja python-yaml
curl -LO https://archive.mesa3d.org/mesa-26.2.7.tar.xz
tar -xf mesa-26.2.7.tar.xz

cd arch-lavender
./userspace/mesa/build-libgallium.sh --src ~/mesa-26.2.7 --check
sudo ./userspace/mesa/build-libgallium.sh --src ~/mesa-26.2.7 --install
```

`--install` writes the result to both
`/usr/local/lib/patched/libgallium-26.2.7-arch1.1.so` and
`/usr/lib/libgallium-26.2.7-arch1.1.so`, then restarts the active Phosh or
Plasma Mobile unit. Without `--install` the script only writes
`./libgallium-26.2.7-arch1.1.so`.

Verify the ABI before rebooting or handing the image to someone:

```sh
readelf -d /usr/lib/libEGL_mesa.so.0 | grep libgallium
ldd -r /usr/lib/libEGL_mesa.so.0   | grep undefined
ldd -r /usr/lib/dri/msm_dri.so     | grep undefined
eglinfo | grep -E 'OpenGL core profile version|OpenGL ES profile version'
```

Expect `OpenGL core profile version: 3.1 Mesa 26.2.6-arch1.1` and
`OpenGL ES profile version: OpenGL ES 3.1 Mesa 26.2.6-arch1.1`.

## Rootfs integration

`rootfs/build-rootfs.sh` auto-detects the prebuilt
`userspace/mesa/libgallium-*.so` and installs it into the image. To override
it with another build:

```sh
sudo MESA_GALLIUM=$PWD/libgallium-26.2.6-arch1.1.so \
    ./rootfs/build-rootfs.sh ~/lavender-assets/rootfs-arch.tar.zst ./rootfs.img
```

The script checks that the file is AArch64, that its embedded soname matches
its filename, and that the image's `libEGL_mesa` actually needs that soname.
It then copies the library to both `/usr/lib` and
`/usr/local/lib/patched`. Without a library the build prints a warning and
the image keeps the distro Mesa, which is missing the a512 fix.

`/etc/pacman.d/hooks/99-local-patches.hook` runs
`/usr/local/sbin/reinstall-patched-libs` after a `mesa` upgrade, restoring the
patched library as long as the soname is still the one the upgraded
`libEGL_mesa` expects. An Arch `mesa` upgrade that changes the soname (for
example to `26.3.x`) needs this patch rebased and the library rebuilt; the
old file is then ignored by `libEGL_mesa`.

## Rollback

`--install` saves the first distro library it replaces as
`/usr/local/lib/patched/libgallium-26.2.6-arch1.1.so.distro` (and does not
overwrite that backup on later runs). To roll back:

```sh
cp /usr/local/lib/patched/libgallium-26.2.6-arch1.1.so.distro \
   /usr/lib/libgallium-26.2.6-arch1.1.so
systemctl restart phosh.service
```

The lab phone also has
`/root/lab/backup/libgallium-26.2.6-arch1.1.so.system` from before the first
install.

## Evidence

`docs/FINDINGS.md` contains the A/B stress results, screenshots, and the
system-wide validation. The short version: the unpatched distro library fails
150/150 stress cycles, while this backport is clean 150/150, and Firefox
(WebRender/FD512), glmark2, GSK glyph stress, and Angelfish render correctly.

The committed prebuilt is sha256
`2e66f90e955f745a98c8fa180e83a4f912f0873e48898d42f325a9200a47808c`. A
second build from a pristine 26.2.6 tarball with the repo patch produced a
different BuildID but the same ABI; that artifact also passed 3x50
(`3771d039…`). See A12 in `docs/FINDINGS.md`.
