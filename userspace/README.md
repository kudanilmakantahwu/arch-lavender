# userspace

Everything in this directory is copied into the root filesystem by
`rootfs/build-rootfs.sh`:

| Directory | Contents |
| --- | --- |
| `base/` | Qualcomm modem/DIAG services, the UIM init script, USB networking debug fallback, zram, and the ModemManager "no net port" patch. |
| `audio/` | ALSA UCM2 profile for the SDM660 sound card (speaker + microphone routing) and the audio `modules-load.d` list. |
| `gui/` | The Phosh systemd unit used by the default graphical session. |

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

## audio

`audio/ucm2` is the ALSA UCM2 profile for the onboard sound card:

| File | Purpose |
| --- | --- |
| `conf.d/sdm660/Xiaomi Redmi Note 7.conf` | Card entry, matched on the ASoC driver name (`sdm660`) and long name |
| `conf.d/sdm660/sdm660.conf` | Same, matched on the driver name alone |
| `Qualcomm/lavender/HiFi.conf` | `HiFi` verb with `Speaker` and `Mic` devices |

The `Speaker` device routes `MultiMedia1` to Primary MI2S
(`PRI_MI2S_RX Audio Mixer MultiMedia1`) and sets the MAX98937 gains; the `Mic`
device routes `MultiMedia2` to LPI MI2S TX3 and sets `ADC1 Volume`.  Without
this profile PipeWire uses a fallback profile and playback fails with
`ASoC: no backend DAIs enabled for MultiMedia1`.

`audio/modules-load.d/sdm660-audio.conf` loads the audio modules early so the
card exists before PipeWire starts.

## gui

`gui/systemd/phosh.service` starts Phosh on `tty1` as user `alarm`:

- `phoc` compositor with `WLR_BACKENDS=drm,libinput`,
- `LIBSEAT_BACKEND=seatd`,
- `GSK_RENDERER=cairo`, because GTK4's NGL renderer loses glyphs at random on
  the Adreno 512 (the same workaround postmarketOS uses on Adreno 5xx),
- `FD_MESA_DEBUG=noubwc`, because UBWC compression corrupts Firefox/WebRender
  buffers (magenta blocks, blank pages).

The build enables this unit and sets `default.target` to `graphical.target`.
`getty@tty1` is disabled; `getty@tty2` remains available as a text-console
fallback. There is no separate experimental/headless mode.

## Console font

`rootfs/overlay/etc/vconsole.conf` sets `FONT=latarcyrheb-sun32` (16×32) so
the `tty2` fallback console is readable on the 1080×2340 panel. Override it
there, or at runtime with `setfont -C /dev/tty2 <font>`.
