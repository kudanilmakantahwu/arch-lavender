# Mesa fixes for Adreno 512 and GTK EGL

This directory carries two userspace Mesa fixes needed on lavender. The a5xx
2D blitter silently drops texture uploads, corrupting glyphs; separately,
Mesa 26.3 stopped advertising `EGL_OPENGL_ES_BIT` when GLES1 is disabled, so
GTK 4.24 could not select an EGL config and fell back to cairo. Both are fixed
in ABI-matched `libgallium` builds. **There is no kernel change**: the GPU,
`msm` driver, and firmware are not the cause.

## Which version does the release use?

The v1.2 rootfs ships `mesa 1:26.2.6-1`, whose `libEGL_mesa.so.0` needs
`libgallium-26.2.6-arch1.1.so`. On 26.2.6 only patch `0001` is applied: that
Mesa still advertises `EGL_OPENGL_ES_BIT` with GLES1 enabled, so `0002` is not
needed. The 26.3.1 prebuilt and patch `0002` exist for systems that upgrade to
Mesa 26.3.x; the examples below use 26.3.1 to document that newer path.

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
`BLIT_OP_SCALE`. Mesa 26.3.1 still reproduces the bug; the fix is backported
in `patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch`.

The backport also carries two highest-bank-bit commits
(`d4b6701`, `4fa3294`). They are a separate fix, but the tested lab
`libgallium` was built with them, so they are kept in the same patch to make
the binary reproducible.

`patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch` carries the a5xx blitter
and highest-bank-bit fixes. `patches/0002-gallium-dri-advertise-egl-es-bit.patch`
restores the `__DRI_API_GLES` renderable bit whenever ES2 is present. It does
not enable GLES1 contexts: it only makes EGL expose `EGL_OPENGL_ES_BIT` configs
so GTK's default `eglChooseConfig` request succeeds.

ABI-matched prebuilt libraries are named `libgallium-<mesa ABI>.so`. The
rootfs builder selects the exact soname its `libEGL_mesa` needs. Hashes are in
`SHA256SUMS`; rebuild when the rootfs Mesa soname changes.

## Build the patched libgallium

The build must match the distro ABI exactly. The script reads the soname
required by `/usr/lib/libEGL_mesa.so.0` (or derives `<Mesa VERSION>-arch1.1`
when cross-building). Three details are easy to get wrong:

- Mesa's `VERSION` file must include the Arch ABI suffix, e.g.
  `26.3.1-arch1.1`, or the library soname is wrong;
- without `-Dplatforms=wayland,x11` the library lacks `loader_dri3_*` and
  phoc dies with `EGL_EXT_platform_base not supported`;
- without `-Dopengl=true` the library exposes only OpenGL ES and Qt apps
  (Angelfish) abort in `QSGRenderLoop::handleContextCreationFailure`;
- GLES1 stays disabled as in the Arch build; `0002` fixes GTK's EGL config
  selection without turning the obsolete GLES1 API back on.

The script sets all of them:

```sh
sudo pacman -S --needed base-devel meson ninja python-yaml
curl -LO https://archive.mesa3d.org/mesa-26.3.1.tar.xz
tar -xf mesa-26.3.1.tar.xz

cd arch-lavender
./userspace/mesa/build-libgallium.sh --src ~/mesa-26.3.1 --check
sudo ./userspace/mesa/build-libgallium.sh --src ~/mesa-26.3.1 --install
```

`--install` writes the result to both `/usr/local/lib/patched/` and `/usr/lib/`
using the ABI-matched soname, then restarts `phosh.service`. Without
`--install` the script only writes the output library in the current directory.

Verify the ABI before rebooting or handing the image to someone:

```sh
readelf -d /usr/lib/libEGL_mesa.so.0 | grep libgallium
ldd -r /usr/lib/libEGL_mesa.so.0   | grep undefined
ldd -r /usr/lib/dri/msm_dri.so     | grep undefined
eglinfo | grep -E 'OpenGL core profile version|OpenGL ES profile version'
```

Expect OpenGL core and OpenGL ES 3.1 version strings with the ABI version you built.

## Rootfs integration

`rootfs/build-rootfs.sh` reads the image's `libEGL_mesa.so.0` and selects the
matching prebuilt `userspace/mesa/libgallium-*.so`. `MESA_GALLIUM` can override
that selection with another ABI-matched build:

```sh
sudo MESA_GALLIUM=$PWD/libgallium-26.3.1-arch1.1.so \
    ./rootfs/build-rootfs.sh ~/lavender-assets/rootfs-arch.tar.zst ./rootfs.img
```

The script checks that the file is AArch64, that its embedded soname matches
its filename, and that the image's `libEGL_mesa` actually needs that soname.
It then copies the library to both `/usr/lib` and
`/usr/local/lib/patched`. If no ABI match is included, the build prints a
warning and the image keeps distro Mesa (glyph corruption / GTK cairo fallback).

`/etc/pacman.d/hooks/99-local-patches.hook` runs
`/usr/local/sbin/reinstall-patched-libs` after a `mesa` upgrade, restoring the
patched library as long as the soname is still the one the upgraded
`libEGL_mesa` expects. An Arch `mesa` upgrade that changes the soname needs the library rebuilt for
the new ABI; stale libraries are ignored by `libEGL_mesa`.

## Rollback

`--install` saves the first distro library it replaces as
`/usr/local/lib/patched/<ABI library>.distro` (and never overwrites that
backup). To roll back, restore the matching backup and restart Phosh:

```sh
cp /usr/local/lib/patched/libgallium-<ABI>.so.distro \
   /usr/lib/libgallium-<ABI>.so
systemctl restart phosh.service
```

## Evidence

The original Mesa 26.2.6 backport passed 150/150 atlas stress cycles. On
Mesa 26.3.1 the unpatched library failed all 30 test cycles. The patched 26.3.1
build passed 30/30 with `FD512`, both through `LD_LIBRARY_PATH` and after
installation into `/usr/lib`, without the shim. GTK's EGL probe changed from
zero to 15 configs for its exact attribute list. A GTK4 test process using
`GSK_RENDERER=gl` mapped `libEGL`, `libGLESv2`, and patched `libgallium` without
renderer warnings. `ldd -r` reports no unresolved dependencies, and
`driDestroyConfigs` is exported.

The 26.3.1 prebuilt sha256 is
`37a2bd628c39486638e1b141f4de00f409de8bd3e2c07e138bf201ac36815ceb`; the
26.2.6 sha256 remains in `SHA256SUMS`. Detailed logs and the ABI investigation
are recorded in `docs/FINDINGS.md` section E.
