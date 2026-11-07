# userspace

Everything in this directory is copied into the root filesystem by
`rootfs/build-rootfs.sh`.  Two sets exist:

| Directory | Default? | Contents |
| --- | --- | --- |
| `base/` | always | Qualcomm modem/DIAG services, the UIM init script, USB networking debug fallback, and the ModemManager "no net port" patch. |
| `gui-experimental/` | only with `--with-gui` | Phosh session unit, touch-zoom helper, and the wlroots layer-shell patch. |

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
| `fbkeyboard.service` | Draws an on-screen keyboard over the `tty1` framebuffer console, so you can log in on the phone itself without USB or an OTG keyboard. |

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

## fbkeyboard

`base/bin/fbkeyboard` is the GPL-3.0 on-screen keyboard from
<https://github.com/julianwi/fbkeyboard>, cross-compiled for aarch64.  The
source and build script live in [`fbkeyboard/`](fbkeyboard/).  It is only
enabled by the headless build; `--with-gui` leaves the keyboard to Phosh.

The vendored source carries three fixes that upstream does not:

- `int c` instead of `char c` for `getopt()`. On AArch64 `char` is unsigned,
  so `(c = getopt(...)) != -1` is always true: the binary spins at 100 % CPU
  and never opens `/dev/fb0`.
- Glyphs are drawn at `hight*2/5` instead of `hight*3/4`, so labels such as
  `shift`, `bksp` and `enter` stay inside their key cells.
- The input read uses `poll()` with a 500 ms timeout and redraws on timeout.
  `fbcon` repaints the whole screen whenever output scrolls, which otherwise
  erases the keyboard until the next touch.

`base/profile.d/fbkeyboard-rows.sh` is installed as
`/etc/profile.d/fbkeyboard-rows.sh`. It measures the visible framebuffer height
and the current tty row count, derives the console font height (the image uses
a 16×32 font), and shrinks the tty rows so the shell prompt stays above the
keyboard instead of scrolling underneath it.

## Console font

`rootfs/overlay/etc/vconsole.conf` sets `FONT=latarcyrheb-sun32` (16×32) so
boot messages and logs are readable on the 1080×2340 panel. Override it there,
or at runtime with `setfont -C /dev/tty1 <font>`.

## gui-experimental

See [`../docs/GUI-EXPERIMENTAL.md`](../docs/GUI-EXPERIMENTAL.md).  The GUI is
opt-in and still buggy; the default install is headless.