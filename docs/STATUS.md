# Status

## Tested configuration

| | |
| --- | --- |
| Device | Redmi Note 7 (`lavender`, `shenchao` panel) |
| Kernel | `7.2.3-sdm660` (commit `e9b7cc51`, a5xx/wifi fixes included) |
| Distro | Arch Linux ARM aarch64 |
| Root filesystem | ext4, label `pmOS_root`, grown to 50 GiB |
| Modem | Telkomsel, MCC/MNC `510/10`, LTE |
| Boot | `fastboot flash userdata` + `fastboot flash boot` |
| Default UI | Phosh on `graphical.target` (`tty1`), `getty@tty2` fallback |

Package versions from the tested image:

| Package | Version |
| --- | --- |
| `modemmanager` | `1.24.2-2` (patched, see below) |
| `phosh` | `0.57.0-2` |
| `phoc` | `0.57.0-2` |
| `squeekboard` | `1.43.1-6` |
| `chatty` | `0.8.9-9` |

## Feature matrix

This is the same table as the README. Anything not listed as working is either
broken or untested, and is described in the sections below.

| Feature | Status | Notes |
| --- | --- | --- |
| Boot / Reboot | Working | Stable system boot |
| Wi-Fi | Working | WCN3990 / `ath10k` (2.4 GHz & 5 GHz) |
| Display & Touchscreen | Working | Shenchao panel only |
| GPU (Adreno 512, a5xx) | Partial | 7.2.3 includes the upstream a5xx fixes; UBWC disabled for app compatibility |
| Charging & Battery | Working | Standard charging and battery reporting work |
| Offline Charging | Broken | System does not boot into offline charging mode |
| Audio – Earpiece | Broken | Currently reported broken |
| Audio – Microphone | Broken | Currently reported broken |
| Audio – Speaker | Broken | Main speaker is non-functional |
| Modem & SIM Detection | Working | SIM **must** be in slot 1 |
| LTE Registration | Working | Network registration succeeds |
| SMS | Working | Via ModemManager / `mmcli` |
| Cellular Data | Broken | Kernel lacks the SDM660 IPA driver (no data port) |
| Phone Calls | Partial | Call setup works; audio is broken |
| Package Management | Working | `pacman` and package updates work |
| Bluetooth | Broken | `hci0` probes, but the stack does not work |
| Vibration | Broken | No working vibrator device |
| Flashlight / Torch | Broken | No working LED device |
| Cameras | Broken | — |
| Sensors | Broken | `qcom_sns_reg` fails to load firmware |
| Video Decoding | Untested | Hardware acceleration untested |
| GPS | Broken | — |
| Suspend / Deep Sleep | Untested | — |
| Fingerprint Sensor | Broken | — |
| Phosh / GUI Session | Working | Default UI; cairo renderer and `FD_MESA_DEBUG=noubwc` work around Adreno 512 glyph/UBWC bugs |

## Default session

The image boots into Phosh:

- `default.target` → `graphical.target`
- `phosh.service` enabled: phoc + Phosh on `tty1` as user `alarm`
- `seatd`, `systemd-networkd`, `NetworkManager`, and `sshd` enabled
- `getty@tty1` disabled so it cannot fight the compositor
- `getty@tty2` enabled as a text-console fallback (Ctrl+Alt+F2)
- `GSK_RENDERER=cairo` in both `/etc/environment` and the Phosh unit
- `FD_MESA_DEBUG=noubwc` in both `/etc/environment` and the Phosh unit

There is no separate text-only build and no opt-in flag. The kernel, rootfs, USB
network, and modem path are identical regardless of how the session is used.

## Works

- Boot, reboot, and shutdown
- Phosh desktop on `tty1`, with squeekboard on-screen keyboard
- Cairo renderer workaround for the GTK4/Adreno glyph bug
- UBWC disabled for the session, so Firefox/WebRender and other GPU apps render correctly
- Console on `tty2` with a readable 16×32 font
- SSH over USB RNDIS (`172.16.42.1`)
- SSH over WiFi
- zram compressed swap (`/dev/zram0`, half of RAM, `zstd`)
- PC internet over USB (`scripts/nat.sh`)
- WiFi 2.4 GHz and 5 GHz (`ath10k`, WCN3990)
- Display and touchscreen (Shenchao panel)
- GPU acceleration (Adreno 512) with the a5xx fixes — partial
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

Call setup works (GNOME Calls / ModemManager). Audio (earpiece, microphone,
and speaker) is currently reported broken, so calls are incomplete.

### Cameras, sensors, GPS, fingerprint

These are present in the device tree but do not work yet. `qcom_sns_reg`
fails to load `qcom/sensors/sns.reg*`, and there is no working camera, GNSS, or
fingerprint path in this kernel/rootfs combination.

### Main speaker

The main loudspeaker is non-functional, along with the earpiece and microphone
in the current build.

### Bluetooth

`hci0` is present and the QCA UART setup completes in `dmesg`, but the
`bluetooth` service stays inactive and the stack is not usable.

### Vibration and flashlight

The device exposes only `mmc1::`, `mmc2::`, and `white:status` LEDs. There is
no vibrator or flashlight device under `/sys/class/leds`, so both are broken.

### Offline charging

Powering off and plugging in USB does not enter a dedicated offline charging
mode. Charge the phone while the system is booted.

## Not tested

- Video decoding / hardware acceleration
- Suspend and deep sleep
- USB host / OTG
- IR blaster
- Dual-SIM operation (only slot 1 was reliable)
- Panels other than Shenchao (Tianma, BOE)

## Known workarounds

| Issue | Workaround |
| --- | --- |
| SIM not detected | Put the SIM in slot 1; `systemctl restart modem-uim-init ModemManager` |
| Modem stuck after a failed restart | `qcom-mss-stop`, then restart `rmtfs` (never restart `rmtfs` on a live modem) |
| WiFi dead after a disconnect | reboot; the `0006` patch prevents the firmware crash, but a wedged device still needs a reboot |
| ModemManager patched binary lost after upgrade | `pacman` hook restores it from `/usr/local/lib/patched/ModemManager`; if the ABI changed, rebuild it |
| Root filesystem needs repair | the initramfs runs `e2fsck -p`, then `e2fsck -f -y` |
| GTK4 text loses random glyphs | `GSK_RENDERER=cairo` (already the default); restart `phosh` after changing it |
| Firefox shows magenta blocks or blank pages | `FD_MESA_DEBUG=noubwc` (already the default); restart `phosh` after changing it |

## Reporting a problem

Include:

```sh
uname -a
cat /proc/cmdline
mmcli -L
systemctl --no-pager status modem-uim-init ModemManager rmtfs
dmesg | tail -100
```

and whether the session starts (check `systemctl status phosh` and
`tr '\0' '\n' < /proc/$(pgrep -n phosh)/environ | grep -E 'GSK_RENDERER|FD_MESA_DEBUG'`).