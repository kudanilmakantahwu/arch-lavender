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
| `usb-net-debug.service` | Creates a USB RNDIS gadget at `172.16.42.1/24` and starts busybox telnetd, so the phone is reachable over USB before WiFi/SSH is configured. |

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

## gui-experimental

See [`../docs/GUI-EXPERIMENTAL.md`](../docs/GUI-EXPERIMENTAL.md).  The GUI is
opt-in and still buggy; the default install is headless.