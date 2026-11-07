# Status

## Tested configuration

| | |
| --- | --- |
| Device | Redmi Note 7 (`lavender`, `shenchao` panel) |
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

## Feature matrix

This is the same table as the README. Anything not listed as working is either
broken or untested, and is described in the sections below.

| Feature | Status | Notes |
| --- | --- | --- |
| Boot / Reboot | Working | Stable system boot |
| Wi-Fi | Working | WCN3990 / `ath10k` (2.4 GHz & 5 GHz) |
| Display & Touchscreen | Working | Shenchao panel only |
| GPU (Adreno 512, a5xx) | Partial | Works with patches 0001–0005 |
| Charging & Battery | Working | Standard charging and battery reporting work |
| Offline Charging | Broken | System does not boot into offline charging mode |
| Audio – Earpiece | Working | Can be used as phone speaker |
| Audio – Microphone | Working | Works out of the box |
| Audio – Speaker | Broken | Main speaker is non-functional |
| Modem & SIM Detection | Working | SIM **must** be in slot 1 |
| LTE Registration | Working | Network registration succeeds |
| SMS | Working | Via ModemManager / `mmcli` |
| Cellular Data | Broken | Kernel lacks the SDM660 IPA driver (no data port) |
| Phone Calls | Partial | Call setup works; audio routing is untested |
| Package Management | Working | `pacman` and package updates work |
| Bluetooth | Broken | `hci0` probes, but the stack does not work |
| Vibration | Broken | No working vibrator device |
| Flashlight / Torch | Broken | No working LED device |
| Cameras | Untested | — |
| Sensors | Untested | `qcom_sns_reg` fails to load firmware |
| Video Decoding | Untested | Hardware acceleration untested |
| GPS | Untested | — |
| Suspend / Deep Sleep | Untested | — |
| Fingerprint Sensor | Untested | — |
| Phosh / GUI Session | Experimental | Opt-in; see [`GUI-EXPERIMENTAL.md`](GUI-EXPERIMENTAL.md) |

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
starts and is usable, but it is not reliable enough to be the default. In the
tested GUI install it would occasionally hard-lock and reboot. See
[`GUI-EXPERIMENTAL.md`](GUI-EXPERIMENTAL.md).

## Works

- Boot, reboot, and shutdown
- Console on `tty1` with a readable 16×32 font
- `fbkeyboard` touch keyboard on `tty1` (headless build)
- SSH over USB RNDIS (`172.16.42.1`)
- SSH over WiFi
- zram compressed swap (`/dev/zram0`, half of RAM, `zstd`)
- PC internet over USB (`scripts/nat.sh`)
- WiFi 2.4 GHz and 5 GHz (`ath10k`, WCN3990)
- Display and touchscreen (Shenchao panel)
- GPU acceleration (Adreno 512) with the a5xx patches — partial
- Charging and battery reporting
- Earpiece audio output and microphone input
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

Call setup works (GNOME Calls / ModemManager). The earpiece and microphone work
on their own, but audio routing during a live call was not verified. Treat
calls as incomplete.

### Main speaker

The earpiece works; the main loudspeaker does not. There is no working
speaker path in this kernel/rootfs combination yet.

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

- Camera (front and back)
- Sensors (`qcom_sns_reg` fails: missing `qcom/sensors/sns.reg*`)
- Video decoding / hardware acceleration
- GPS / GNSS
- Suspend and deep sleep
- Fingerprint sensor
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