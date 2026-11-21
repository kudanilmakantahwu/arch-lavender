# Firefox hardware video decode on qcom-venus

This directory makes Firefox decode H.264 in hardware on lavender's
`qcom-venus` decoder (V4L2 stateful memory-to-memory) instead of on the CPU.
It is a **userspace-only** change: no kernel patch, no GPU/Mesa change, and no
audio change. The distro ffmpeg is left untouched.

## Why this is needed

Firefox's Linux media stack will only accept the stateful `h264_v4l2m2m`
wrapper when the decoder hands back **DRM-PRIME (dmabuf)** frames. Upstream
ffmpeg's `v4l2_m2m` only ever produces memory-mapped frames, so Firefox logs

```
Got non-DRM-PRIME frame from FFmpeg V4L2
```

and falls back to software (Mozilla bug **1852765**). The Raspberry Pi fork
[`jc-kynesim/rpi-ffmpeg`](https://github.com/jc-kynesim/rpi-ffmpeg) implements
the DRM-PRIME output that Firefox needs; venus on this SDM660 supports it
already (`VIDIOC_EXPBUF` and `V4L2_MEMORY_DMABUF` both work on `/dev/video0`).

Two further Firefox details are handled by the config here:

* `media.hardware-video-decoding.force-enabled=true` skips the gfxInfo
  blocklist so the V4L2 probe result is actually used;
* the RDD (media) child needs the V4L2 ioctls, so the wrapper sets
  `MOZ_DISABLE_RDD_SANDBOX=1` (the Linux RDD sandbox otherwise denies them).

## What is in here

| Path | Purpose |
| --- | --- |
| `pref/99-v4l2-hwdecode-prefs.js` | system-wide default prefs (`defaults/pref/`), installed for every profile |
| `bin/firefox` | wrapper: exports `LD_LIBRARY_PATH=/opt/rpi-ffmpeg/lib` and `MOZ_DISABLE_RDD_SANDBOX=1`, then execs the real binary |
| `install.sh` | installs the pref, the wrapper, and a per-user desktop override into a root filesystem |
| `build-rpi-ffmpeg.sh` | builds the fork from source into `/opt/rpi-ffmpeg` |
| `stage-ffmpeg-rpi-pkg.sh` | offline path: stages the prebuilt Arch Linux ARM `ffmpeg-rpi` package into `/opt/rpi-ffmpeg` |

### How the pieces fit

The patched ffmpeg lives in an isolated prefix so that **the distro ffmpeg is
never replaced**:

```
/opt/rpi-ffmpeg/lib/libavcodec.so.61.19.101   <- rpi-ffmpeg 7.1.5 (DRM-PRIME)
/opt/rpi-ffmpeg/lib/libavcodec.so.61 -> libavcodec.so.61.19.101
/opt/rpi-ffmpeg/lib/libavcodec.so.62 -> libavcodec.so.61   <- Firefox shadow
/opt/rpi-ffmpeg/lib/libavcodec.so.63 -> libavcodec.so.61   <- Firefox shadow
/opt/rpi-ffmpeg/lib/libavutil.so.59.39.100
```

Firefox 159's `FFmpegRuntimeLinker` dlopens the **newest** soname first
(`libavcodec.so.63`, then `.62`, then `.61`). Since `LD_LIBRARY_PATH` takes
precedence over the ld.so cache, the prefix needs `.62`/`.63` symlinks to the
built `libavcodec.so.61` so Firefox picks the patched library; without them it
would find the distro `libavcodec.so.63` (ffmpeg 9.x) and decode in software.
The shadows only exist inside the prefix, so only processes the wrapper starts
can see them.

Firefox is started through `/usr/local/bin/firefox`. The per-user desktop
override (`~/.local/share/applications/firefox.desktop`) rewrites the packaged
`Exec=/usr/lib/firefox/firefox` lines to the wrapper, so launching Firefox from
the Phosh app grid uses it. The override is user-scoped and therefore survives
a `firefox` package upgrade; editing the packaged desktop file would not.

## Build the fork (preferred)

```sh
git clone --depth 1 --branch test/7.1.5/main \
    https://github.com/jc-kynesim/rpi-ffmpeg.git
cd arch-lavender
./userspace/firefox/v4l2-hwdecode/build-rpi-ffmpeg.sh \
    --src ~/rpi-ffmpeg --check
sudo ./userspace/firefox/v4l2-hwdecode/build-rpi-ffmpeg.sh \
    --src ~/rpi-ffmpeg --install
```

The fork's default branch is an old ffmpeg 4.4 tree; the 7.1.5 code that Arch
Linux ARM's `ffmpeg-rpi` package builds from is the branch
`test/7.1.5/main` (there is no `release/7.1` branch). The script configures with

```
--prefix=/opt/rpi-ffmpeg --enable-shared --disable-static --disable-programs
--disable-doc --enable-libdrm --enable-v4l2-m2m
```

installs there, and creates the `.62`/`.63` shadows. `--check` only validates
the source (it refuses an upstream ffmpeg tree, which has no
`AV_PIX_FMT_DRM_PRIME` in `libavcodec/v4l2_buffers.c`).

## Offline path: stage the ALARM package

When the fork cannot be cloned or built, the Arch Linux ARM `ffmpeg-rpi`
package is the same jc-kynesim/rpi-ffmpeg 7.1.5 source already built for
aarch64:

```sh
sudo pacman -Sw ffmpeg-rpi            # or download it from an ALARM mirror
sudo ./userspace/firefox/v4l2-hwdecode/stage-ffmpeg-rpi-pkg.sh \
    --pkg /var/cache/pacman/pkg/ffmpeg-rpi-7.1.5-4-aarch64.pkg.tar.xz
```

The script collects the versioned libraries into `/opt/rpi-ffmpeg/lib`,
recreates the `<major>` links, adds the `.62`/`.63` shadows, and sanity-checks
that the DRM-PRIME v4l2m2m strings are present and that the libraries' `NEEDED`
entries resolve.

## Rootfs integration

`install.sh` installs the Firefox-side config; the ffmpeg libraries are staged
separately. `rootfs/build-rootfs.sh` accepts either input and always runs
`install.sh`:

```sh
# build/staged directory of libs:
sudo RPI_FFMPEG_LIBDIR=$HOME/rpi-ffmpeg-prefix/lib \
    ./rootfs/build-rootfs.sh rootfs-arch.tar.zst rootfs.img

# or an ALARM package:
sudo RPI_FFMPEG_PKG=/var/cache/pacman/pkg/ffmpeg-rpi-7.1.5-4-aarch64.pkg.tar.xz \
    ./rootfs/build-rootfs.sh rootfs-arch.tar.zst rootfs.img
```

If neither is given the build prints a warning and the image ships software
decode (the wrapper becomes a no-op because `/opt/rpi-ffmpeg/lib` does not
exist). This mirrors how `MESA_GALLIUM` is handled.

## Verify on the device

With a 1080p H.264 file or a YouTube stream playing through the wrapper:

```sh
# the RDD (media) process holds the venus decoder
fuser -v /dev/video0
# -> /dev/video0: alarm <pid> F...m RDD Process

# venus is actually doing work (counter increases while playing)
grep -i venus /proc/interrupts

# which libavcodec the RDD loaded
pid=$(fuser /dev/video0 2>/dev/null | tr -d ' ')
grep libav /proc/$pid/maps
# -> /opt/rpi-ffmpeg/lib/libavcodec.so.61.19.101
#    /opt/rpi-ffmpeg/lib/libavutil.so.59.39.100
```

`MOZ_LOG` proves the DRM path. Firefox writes child-process logs to
`<MOZ_LOG_FILE>.child-<n>.moz_log` (not to the base name), so grep those:

```sh
sudo -u alarm env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
    MOZ_LOG="FFmpegVideo:5,PlatformDecoderModule:5" \
    MOZ_LOG_FILE=/tmp/moz.log \
    /usr/local/bin/firefox -no-remote -profile /tmp/fftest <url>

grep -c 'Initialising V4L2-DRM FFmpeg decoder' /tmp/moz.log.child-*.moz_log   # >= 1
grep -c 'non-DRM-PRIME'                      /tmp/moz.log.child-*.moz_log   # == 0
```

Expected RDD CPU while a 1080p H.264 video plays is single-digit percent
(~3%), versus ~70% with software decode.

## Rollback

Remove `/usr/local/bin/firefox`, `/usr/lib/firefox/defaults/pref/99-v4l2-hwdecode-prefs.js`,
and `~/.local/share/applications/firefox.desktop`; Firefox falls back to the
distro binary and ffmpeg 9.x. `/opt/rpi-ffmpeg` can be deleted independently.

## Evidence

Verified on the released image (2026-11-21): a 1080p H.264 YouTube stream
(`aqz-KE-bpKQ`, VP9/AV1 disabled to force H.264) decoded on venus with

* venus IRQ delta ≈ 800 over ~70 s of playback,
* the RDD process holding `/dev/video0`,
* RDD CPU ≈ 3%,
* `Initialising V4L2-DRM FFmpeg decoder` present and `Got non-DRM-PRIME frame`
  absent in `MOZ_LOG`.

Details, the device node numbering, and the upstream-ffmpeg investigation are
in [`docs/FINDINGS.md`](../../../docs/FINDINGS.md) section I.
