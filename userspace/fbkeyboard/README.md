# fbkeyboard (vendored)

`fbkeyboard` is a small on-screen keyboard for the Linux framebuffer console.
It lets you log in on the phone's own screen and type on the touchscreen when
USB networking, SSH or an OTG keyboard are not available.

It is a **separate, GPL-3.0 program** and is not part of this project's
GPL-2.0 code. See `COPYING` in this directory.

- Upstream: <https://github.com/julianwi/fbkeyboard>
- Vendored commit: `8659f65b08f2b239358384b296cc02a31c073654` (2017-08-20)

## Why a prebuilt binary is committed

The sanitized rootfs tarball does not contain the freetype2 development
headers, so the program cannot be compiled on the phone as shipped. Building
it on the host and committing the small (~71 KB) aarch64 binary keeps the
1.2 GB rootfs tarball unchanged: users only pull this file from git instead of
re-downloading the whole rootfs.

`rootfs/build-rootfs.sh` installs the binary as `/usr/local/bin/fbkeyboard`
and enables `fbkeyboard.service` on `tty1` (headless builds only).

At runtime it needs only `libfreetype.so.6` and `libc`, plus the kernel options
`CONFIG_FB`, `CONFIG_FRAMEBUFFER_CONSOLE` and `CONFIG_INPUT_UINPUT`. All three
are enabled in `kernel/config/config-postmarketos-qcom-sdm660.aarch64`.

## Local fixes in this copy

Three changes were needed to make the upstream source usable on this device:

1. **`int c`, not `char c`, for `getopt()`.** On AArch64 `char` is unsigned,
   so `(c = getopt(...)) != -1` is always true. The upstream binary (and the
   first cross-build) spun at 100 % CPU without opening `/dev/fb0`.
2. **Smaller glyphs.** `FT_Set_Pixel_Sizes` uses `hight*2/5` instead of
   `hight*3/4`, and the baseline uses `hight*5/8`. At 1080 px wide, key cells
   are only 108–162 px, so the old size made labels such as `shift`, `bksp`
   and `enter` overflow into neighbouring cells.
3. **Redraw on a timeout.** The input read now uses `poll()` with a 500 ms
   timeout and loops to redraw. `fbcon` repaints the whole screen when console
   output scrolls, which otherwise erases the keyboard until the next touch.

`../base/profile.d/fbkeyboard-rows.sh` is the companion login hook that shrinks
the tty to the rows above the keyboard.

## Rebuild

```sh
sudo dpkg --add-architecture arm64
sudo apt update
sudo apt install gcc-aarch64-linux-gnu libfreetype-dev:arm64
./build-aarch64.sh
```