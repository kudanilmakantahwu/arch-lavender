# Status

## Tested configuration

| | |
| --- | --- |
| Device | Redmi Note 7 (`lavender`, `shenchao`) |
| Kernel | `7.0.14-sdm660` (tag `v7.0.14-sdm660` + patches 0001–0006) |
| Distro | Arch Linux ARM aarch64 |
| Root filesystem | ext4, label `pmOS_root`, grown to 50 GiB |
| Modem | Telkomsel, MCC/MNC `510/10`, LTE |
| Boot | `fastboot flash userdata` + `fastboot flash boot` |

Package versions from the tested image:

| Package | Version |
| --- | --- |
| `modemmanager` | `1.24.2-2` (patched, see below) |
| `wlroots0.20` | `0.20.2-1` (patched for the experimental GUI) |
| `phosh` | `0.57.0-2` |
| `phoc` | `0.57.0-2` |
| `squeekboard` | `1.43.1-6` |
| `chatty` | `0.8.9-9` |
| `gnome-calls` | `51.1-1` |

## Headless vs GUI

The **headless** configuration is the default:

- `default.target` → `multi-user.target`
- `getty@tty1` enabled, not masked
- Phosh and `touch-zoom` are not started
- SSH over USB and WiFi, `NetworkManager`, and the modem stack are enabled

The system underneath is the same one that was tested on hardware. The only
difference from the tested GUI session is the boot target and the two GUI
units, so nothing in the kernel, rootfs, or modem path changes.

The **GUI** configuration is opt-in (`--with-gui`) and experimental. Phosh
starts and is usable, but it is not reliable enough to be the default. See
[`GUI-EXPERIMENTAL.md`](GUI-EXPERIMENTAL.md).

## Works

- Boot, reboot, and shutdown
- Console on `tty1`
- SSH over USB RNDIS (`172.16.42.1`)
- SSH over WiFi
- WiFi 2.4 GHz and 5 GHz (`ath10k`, WCN3990)
- Display and touchscreen
- GPU acceleration (Adreno 512) with the a5xx patches
- Charging and battery reporting
- Modem bring-up, SIM detection, LTE registration
- SMS via ModemManager (`mmcli`)
- `pacman` package management
- 50 GiB root filesystem grown online

## Does not work

### Cellular data

The kernel has no SDM660 IPA driver. The modem has no data port, and
ModemManager reports:

```
No valid data port found to launch connection
```

This is the main functional gap. Registration, SMS, and calls do not need the
IPA path.

### Phone call audio

Call setup works (GNOME Calls / ModemManager), but audio routing to the
speaker/earpiece/microphone was not verified. Treat calls as incomplete.

## Not tested

- Camera (front and back)
- Bluetooth
- GPS / GNSS
- Suspend and deep sleep
- Fingerprint sensor
- USB host / OTG
- IR blaster
- Dual-SIM operation (only slot 1 was reliable)

## Known workarounds

| Issue | Workaround |
| --- | --- |
| SIM not detected | Put the SIM in slot 1; `systemctl restart modem-uim-init ModemManager` |
| Modem stuck after a failed restart | `qcom-mss-stop`, then restart `rmtfs` (never restart `rmtfs` on a live modem) |
| WiFi dead after a disconnect | reboot; the `0006` patch prevents the firmware crash, but a wedged device still needs a reboot |
| ModemManager patched binary lost after upgrade | `pacman` hook restores it from `/usr/local/lib/patched/ModemManager`; if the ABI changed, rebuild it |
| Root filesystem needs repair | the initramfs runs `e2fsck -p`, then `e2fsck -f -y` |

## Reporting a problem

Include:

```sh
uname -a
cat /proc/cmdline
mmcli -L
systemctl --no-pager status modem-uim-init ModemManager rmtfs
dmesg | tail -100
```

and whether the phone is on the headless or experimental GUI target.