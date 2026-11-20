# userspace

`rootfs/build-rootfs.sh` installs the units, scripts, audio profile, and power
policy from this directory into the root filesystem. `mesa/` is different: it
holds source-build inputs and is not copied as-is; the built `libgallium` is
what gets installed.

| Directory | Contents |
| --- | --- |
| `base/` | Qualcomm modem/DIAG services, the UIM init script, USB networking debug fallback, zram, the ModemManager "no net port" patch, and the `sleep.conf.d` drop-in that refuses suspend (s2idle is broken on this kernel). |
| `audio/` | ALSA UCM2 profile for the SDM660 sound card (speaker + microphone routing), the WirePlumber rule that keeps the speaker at 16-bit, and the audio `modules-load.d` list. |
| `gui/` | The Phosh systemd unit and `lavender-session-defaults`, which disables the GNOME/Phosh idle-suspend timers at session start. |
| `mesa/` | The a5xx/FD512 2D-blit and GTK EGL ES-bit fixes: ABI-matched `libgallium` builds, Mesa backports, build script, and ABI notes. |

## base

### systemd units

| Unit | Why it is needed |
| --- | --- |
| `tqftpserv.service` | Serves firmware to the modem over QRTR TFTP. |
| `pd-mapper.service` | Maps protection domains; reads `/usr/lib/firmware/*.jsn`. |
| `diag-router.service` | QRTR diagnostics router; rmtfs depends on it. |
| `rmtfs.service` | Starts the modem and provides its EFS storage. |
| `modem-uim-init.service` | Brings the modem online **and opens the primary UIM session**. Without this, ModemManager sees no SIM. |
| `usb-net-debug.service` | Creates a USB RNDIS gadget at `172.16.42.1/24`, so SSH works over the USB cable before WiFi is configured. |
| `zram-swap.service` | Creates a zram swap device (`zstd`) sized at half of RAM. Without swap, one large program can freeze a 6 GB phone for minutes. |

`rmtfs.service` runs `/usr/local/sbin/qcom-mss-stop` first.  That script asks
the modem to shut down cleanly so `rmtfs` can start it from scratch.  This is
the sequence that makes the modem reliable across reboots.

### modem-uim-init

The modem firmware boots into `shutting-down`, then `low-power`, then
`online`.  Only after that can the UIM provisioning session be opened:

```
qrtr-lookup
qmic -d <MODEM> --uim-change-provisioning-session \
    --session-type primary --activate 1 \
    --aid A0000000871002FF82FF3089010000FF
```

`modem-uim-init` does this automatically and is ordered before
`ModemManager.service`.  If the SIM disappears after a reboot:

```
systemctl restart modem-uim-init ModemManager
```

Never restart `rmtfs` on a live system; stop the modem first with
`qcom-mss-stop`.

### ModemManager patch

`patches/modemmanager-1.24.2-no-net-port.patch` disables the check that
refuses to start a modem when no network port is found.  The sdm660 kernel in
this repo has no IPA driver, so the modem has no data port; without the patch
ModemManager never brings the modem up, and SMS/calls do not work.

The built binary is installed to `/usr/local/lib/patched/ModemManager` and
copied over `/usr/bin/ModemManager`.  `pacman/99-local-patches.hook` restores
it automatically after a package upgrade.

### Build the Qualcomm helpers

`base/bin/build-qcom.sh` builds `qrtr`, `tqftpserv`, `rmtfs`, `pd-mapper`, and
`diag-router` from <https://github.com/linux-msm>.  The released rootfs already
contains them; the script is here so the binaries are not a black box.

## mesa

`mesa/patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch` is the rebased
upstream fix for the Adreno 512 2D copy that silently writes nothing. It
breaks `glTexSubImage2D` uploads into busy textures, which appears as missing
glyphs and black texture tiles.

`mesa/libgallium-*.so` includes ABI-matched prebuilt libraries for supported
Mesa versions; `rootfs/build-rootfs.sh` selects the exact soname requested by
the rootfs `libEGL_mesa`. `mesa/build-libgallium.sh` rebuilds them with
`-Dplatforms=wayland,x11`, `-Dopengl=true`, and GLES1 disabled. The patches fix
the a5xx 2D-blit upload loss and restore GTK's expected EGL ES renderable bit.
See [`mesa/README.md`](mesa/README.md) for build steps, ABI checks, rollback,
and test results. These are userspace fixes; the kernel is not patched.

## audio

`audio/ucm2` is the ALSA UCM2 profile for the onboard sound card:

| File | Purpose |
| --- | --- |
| `conf.d/sdm660/Xiaomi Redmi Note 7.conf` | Card entry, matched on the ASoC driver name (`sdm660`) and long name |
| `conf.d/sdm660/sdm660.conf` | Same, matched on the driver name alone |
| `Qualcomm/lavender/HiFi.conf` | `HiFi` verb with the `Speaker` device |
| `Qualcomm/lavender/Mic.conf` | Separate `Mic` verb (ACP capture probe fails on 7.2.3; keeping it out of HiFi preserves the speaker profile) |
| `wireplumber/wireplumber.conf.d/50-lavender-s16.conf` | Forces the speaker sink to open the ALSA PCM at `S16LE` (fallback for kernels without the `qcom,force-s16-fe` quirk) |

The `Speaker` device routes `MultiMedia1` to Primary MI2S
(`PRI_MI2S_RX Audio Mixer MultiMedia1`) and sets the MAX98937 gains; the `Mic`
verb routes `MultiMedia2` to LPI MI2S TX3 and sets `ADC1 Volume`.  Without
this profile PipeWire uses a fallback profile and playback fails with
`ASoC: no backend DAIs enabled for MultiMedia1`.

`50-lavender-s16.conf` is not cosmetic.  PipeWire otherwise opens the
`MultiMedia1` front end at `S24_LE`, while the machine driver fixes the
Primary MI2S backend at `S16_LE`; the Q6 DSP then passes only the low 16 bits
of every sample to the MAX98937.  That produces clean audio about 48 dB too
quiet, independent of the ALSA and PipeWire volumes.  The rule matches the
speaker sink by name and sets `audio.format = "S16LE"`, which covers every
client on that sink, including Waydroid.  Headphone and microphone formats
are untouched.

`audio/modules-load.d/sdm660-audio.conf` loads the audio modules early so the
card exists before PipeWire starts.

## gui

`gui/systemd/phosh.service` starts Phosh on `tty1` as user `alarm`:

- `phoc` compositor with `WLR_BACKENDS=drm,libinput`,
- `LIBSEAT_BACKEND=seatd`,
- `GSK_RENDERER=gl`, GTK 4.24's GL renderer for GTK4 apps (~2.2x the
  text-scroll frame rate of cairo on the Adreno 512: 51 fps vs 23 fps); the
  patched Mesa libgallium fixes the a5xx glyph corruption. GTK 4.24 renamed
  `ngl` to `gl`. Phosh 0.57 itself is a GTK3 shell, so the variable applies to
  its GTK4 apps rather than to `phosh`,
- `FD_MESA_DEBUG=noubwc`, because UBWC compression corrupts Firefox/WebRender
  buffers (magenta blocks, blank pages).

The build enables this unit and sets `default.target` to `graphical.target`.
`getty@tty1` is disabled; `getty@tty2` remains available as a text-console
fallback. There is no separate experimental/headless mode.

## Console font

`rootfs/overlay/etc/vconsole.conf` sets `FONT=latarcyrheb-sun32` (16×32) so
the `tty2` fallback console is readable on the 1080×2340 panel. Override it
there, or at runtime with `setfont -C /dev/tty2 <font>`.
