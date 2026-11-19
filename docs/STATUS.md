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
| Default UI | Phosh on `graphical.target` (`tty1`); SSH recovery, `getty@tty2` with a USB keyboard |

Package versions from the tested image:

| Package | Version |
| --- | --- |
| `modemmanager` | `1.24.2-2` (patched, see below) |
| `phosh` | `0.57.0-2` |
| `phoc` | `0.57.0-2` |
| `squeekboard` | `1.43.1-6` |
| `chatty` | `0.8.9-9` |
| `gnome-keyring` | `1:51.1-1` (needed for Wi-Fi password prompts) |

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
| Audio – Earpiece | Working | PM660L (PM8916-compatible) analog codec on internal MI2S |
| Audio – Microphone | Partial | PM660L ADC1 in a separate UCM verb; `hw:X7,1` capture open currently fails with `EINVAL` on 7.2.3 |
| Audio – Speaker | Working | MAX98937 smart amp on Primary MI2S (`max98937` driver); needs `CONFIG_SND_SOC_SM8250=m`; sink forced to `S16LE` |
| Modem & SIM Detection | Working | SIM **must** be in slot 1 |
| LTE Registration | Working | Network registration succeeds |
| SMS | Working | Via ModemManager / `mmcli` |
| Cellular Data | Broken | Kernel lacks the SDM660 IPA driver (no data port) |
| Phone Calls | Partial | Call setup works; in-call audio is unsupported (no voice-call DSP driver) |
| Package Management | Working | `pacman` and package updates work |
| Bluetooth | Broken | `hci0` probes, but the stack does not work |
| Vibration | Broken | No working vibrator device |
| Flashlight / Torch | Broken | No working LED device |
| Cameras | Broken | — |
| Sensors | Broken | `qcom_sns_reg` fails to load firmware |
| Video Decoding | Partial | VP8/VP9 software decode works; H.264 via `qcom-venus` is broken |
| GPS | Broken | — |
| Suspend / Deep Sleep | Untested | s2idle is disabled by the shipped sleep policy |
| Fingerprint Sensor | Broken | — |
| Waydroid (optional) | Working | Not enabled by default; occasional font glitches, otherwise stable |
| Phosh / GUI Session | Working | Default UI; GL renderer (~50 fps scroll vs 23 with cairo), patched a5xx `libgallium` for the 2D-blit glyph bug, and `FD_MESA_DEBUG=noubwc` for the Adreno 512 UBWC bug |

Measured defaults and the A/B tests behind them (renderer, zram, GPU
governor, speaker level, 3x retest) are in
[PERFORMANCE.md](PERFORMANCE.md).

## Default session

The image boots into Phosh:

- `default.target` → `graphical.target`
- `phosh.service` enabled: phoc + Phosh on `tty1` as user `alarm`
- `seatd`, `systemd-networkd`, `NetworkManager`, and `sshd` enabled
- `getty@tty1` disabled so it cannot fight the compositor
- `getty@tty2` enabled for a USB-keyboard text console (SSH is the normal
  recovery path; the phone has no built-in keyboard)
- `GSK_RENDERER=ngl` in both `/etc/environment` and the Phosh unit
- `FD_MESA_DEBUG=noubwc` in both `/etc/environment` and the Phosh unit

There is no separate text-only build and no opt-in flag. The kernel, rootfs, USB
network, and modem path are identical regardless of how the session is used.

## Works

- Boot, reboot, and shutdown
- Phosh desktop on `tty1`, with squeekboard on-screen keyboard
- Plasma Mobile 6.8.3 on `tty1` (tested 2026-11-19: KWin Wayland, plasmashell and
  the mobile shell start, SSH stays reachable; startup QML warnings are
  non-fatal). See [`DESKTOP.md`](DESKTOP.md)
- GL renderer (`ngl`) for ~2x faster scrolling; the patched a5xx `libgallium`
  fixes the 2D-blit glyph/texture loss (`userspace/mesa/`), while `cairo`
  remains a temporary fallback if a program still misrenders
- UBWC disabled for the session, so Firefox/WebRender and other GPU apps render correctly
- Console on `tty2` with a readable 16×32 font (USB keyboard required)
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

Call setup works (GNOME Calls / ModemManager), but audio inside a call is
still unsupported.  The kernel is the SDM660 mainline tree at 7.2.3, which has
no voice-call DSP driver (`q6voice`) and no `Voice Call` frontend DAI.  The
DSP voice service is never opened, so the modem has no audio path even though
music playback and microphone capture work.

Supporting calls would require porting the `q6voice`/CVS driver and adding a
`Voice Call` DAI link to the machine driver; an ALSA UCM `Voice Call` verb on
its own does not help, because there is no PCM behind it.

### Cameras, sensors, GPS, fingerprint

These are present in the device tree but do not work yet. `qcom_sns_reg`
fails to load `qcom/sensors/sns.reg*`, and there is no working camera, GNSS, or
fingerprint path in this kernel/rootfs combination.

### Audio

Speaker and earpiece work; the microphone path is exposed separately and
currently fails to open (see below):

- The main speaker is driven by a **MAX98937** smart amplifier on Primary
  MI2S.  It shares the MAX98927 bit layouts but has a different register
  address map, so the mainline `max98927` driver silently programs the wrong
  registers.  `kernel/patches/local/0001-...` adds a dedicated `max98937`
  driver.  The MAX98937 also needs `GLOBAL_EN` (`0x0500`, bit 0) set on
  unmute in addition to `SPK_EN` (`0x0039`, bit 0); without it the part stays
  in global shutdown and the speaker is silent.
- The earpiece and internal microphone are handled by the PM660L
  (PM8916-compatible) analog codec on internal/LPI MI2S.
- `userspace/audio/ucm2` installs an ALSA UCM2 profile that gives
  PipeWire/WirePlumber the `Speaker playback` sink.  Without it PipeWire
  falls back to a broken profile and logs `no backend DAIs enabled for
  MultiMedia1`.  The microphone is in a separate `Mic` verb: ACP probes every
  device in a verb, and `hw:X7,1` currently fails to open with `EINVAL`, which
  would otherwise mark the whole HiFi profile unsupported and leave only
  `Dummy Output`.
- `userspace/audio/wireplumber` forces the speaker sink to `S16LE`.  PipeWire
  otherwise opens the `MultiMedia1` front end at `S24_LE` while the machine
  driver fixes Primary MI2S at `S16_LE`; the Q6 DSP then behaves as if only
  the low 16 bits reach the MAX98937, so playback is clean but ~48 dB too
  quiet.  The rule covers every client on the speaker sink, including
  Waydroid, and leaves the headphone and microphone formats alone.

In-call audio is a separate problem; see "Phone call audio" above.

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
| GTK4 text loses random glyphs | install the patched `libgallium` from `userspace/mesa/` and restart `phosh`; that fixes the a512 2D-blit bug. `GSK_RENDERER=cairo` is only a temporary fallback |
| Firefox shows magenta blocks or blank pages | `FD_MESA_DEBUG=noubwc` (already the default); restart `phosh` after changing it |
| No sound, PipeWire shows `stereo-fallback` | install the UCM2 profile from `userspace/audio`, then `systemctl --user restart wireplumber` |
| In-call audio is silent | not supported yet: the kernel has no `q6voice` voice-call DSP driver |

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
For glyph/texture loss also record the Mesa ABI actually in use:

```sh
readelf -d /usr/lib/libEGL_mesa.so.0 | grep libgallium
sha256sum /usr/lib/libgallium-*.so
```