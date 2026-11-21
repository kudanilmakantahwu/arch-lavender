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
| `stevia` | `0.59.0-1` (on-screen keyboard; replaces `squeekboard`) |
| `chatty` | `0.8.9-9` |
| `gnome-keyring` | `1:51.1-1` (needed for Wi-Fi password prompts) |
| `mesa` | `1:26.2.6-1` (ABI for the patched `libgallium-26.2.6-arch1.1.so`) |
| `gtk4` | `1:4.24.1-1` (GTK4 GL renderer is `gl`) |
| `firefox` | `159.0.1-1` |
| `ffmpeg-rpi` | `7.1.5-4` (staged in `/opt/rpi-ffmpeg` for Firefox venus decode; the distro `ffmpeg` `2:9.0.2-2` is untouched) |

## Feature matrix

This is the same table as the README. Anything not listed as working is either
broken or untested, and is described in the sections below.

| Feature | Status | Notes |
| --- | --- | --- |
| Boot / Reboot | Working | Stable system boot |
| Wi-Fi | Working | WCN3990 / `ath10k` (2.4 GHz & 5 GHz) |
| Display & Touchscreen | Working | Shenchao panel only |
| GPU (Adreno 512, a5xx) | Partial | Kernel 7.2.3 carries the upstream a5xx fixes; Mesa's a5xx 2D-blit glyph bug is fixed in userspace by the patched `libgallium`; UBWC disabled for app compatibility |
| Charging & Battery | Working | Standard charging and battery reporting work |
| Offline Charging | Broken | System does not boot into offline charging mode |
| Audio – Earpiece | Working | PM660L (PM8916-compatible) analog codec on internal MI2S |
| Audio – Microphone | Partial | PM660L ADC1 in a separate UCM verb; `hw:X7,1` capture open currently fails with `EINVAL` on 7.2.3 |
| Audio – Speaker | Working | MAX98937 smart amp on Primary MI2S (`max98937` driver); needs `CONFIG_SND_SOC_SM8250=m`; kernel pins the front end to `S16_LE` (`qcom,force-s16-fe`) |
| Modem & SIM Detection | Working | SIM **must** be in slot 1 |
| LTE Registration | Working | Network registration succeeds |
| SMS | Working | Via ModemManager / `mmcli` |
| Cellular Data | Broken | Kernel lacks the SDM660 IPA driver (no data port) |
| Phone Calls | Partial | Call setup works; in-call audio is unsupported (no voice-call DSP driver) |
| Package Management | Working | `pacman` and package updates work |
| Bluetooth | Broken | `hci0` probes, but the stack does not work |
| Vibration | Working | PM660L `pm660_haptics` (`qcom,pmi8998-haptics`, ERM); `/dev/input/event4` |
| Flashlight / Torch | Broken | No working LED device |
| Cameras | Broken | — |
| Sensors | Partial | ADSP SMGR stack enumerates accelerometer + gyro (ICM20607), magnetometer (AK09918), light/proximity (STK3x3x); `monitor-sensor` reads the accelerometer (orientation). No light/proximity yet (kernel/iio-sensor-proxy limitation, see [`userspace/sensors/README.md`](../userspace/sensors/README.md)). Needs the shipped registry `sns.reg` |
| Video Decoding | Working | `qcom-venus` H.264 decode drains to end of stream (GStreamer `v4l2h264dec` and ffmpeg `h264_v4l2m2m`), fixed by [`kernel/patches/local/0003`/`0004`](../kernel/patches/local/) (FINDINGS.md section H); **Firefox decodes 1080p H.264 on venus** with the patched `rpi-ffmpeg` staged in `/opt/rpi-ffmpeg` plus a launcher wrapper (FINDINGS.md section I, [`userspace/firefox/v4l2-hwdecode`](../userspace/firefox/v4l2-hwdecode/README.md)); VP8/VP9 software decode works |
| GPS | Broken | — |
| Suspend / Deep Sleep | Broken | s2idle enters and resumes, but the RTC wake is intermittent and every resume forces an `ath10k` firmware reload; `ath10k` and the modem share the MSS remoteproc, so the modem re-enumerates and the SIM can go missing.  The shipped sleep policy keeps it disabled (see FINDINGS.md section D) |
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
- `GSK_RENDERER=gl` in both `/etc/environment` and the Phosh unit (GTK 4.24; old `ngl` name is ignored). This controls GTK4 apps; phosh 0.57 itself is a GTK3 shell and `phoc` renders with GLES directly.
- `FD_MESA_DEBUG=noubwc` in both `/etc/environment` and the Phosh unit

There is no separate text-only build and no opt-in flag. The kernel, rootfs, USB
network, and modem path are identical regardless of how the session is used.

## Works

- Boot, reboot, and shutdown
- Phosh desktop on `tty1`, with the stevia on-screen keyboard
- Plasma Mobile 6.8.3 on `tty1` (tested 2026-11-19: KWin Wayland, plasmashell and
  the mobile shell start, SSH stays reachable; startup QML warnings are
  non-fatal). See [`DESKTOP.md`](DESKTOP.md)
- GTK4 GL renderer (`GSK_RENDERER=gl`) for ~2x faster scrolling in GTK4 apps;
  patched a5xx `libgallium` fixes both glyph uploads and GTK's missing EGL
  config bit (`userspace/mesa/`); `cairo` is only a temporary fallback. Phosh
  0.57 itself is GTK3, and `phoc` uses FD512 GLES for the compositor.
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

### Cameras, GPS, fingerprint

These are present in the device tree but do not work yet: there is no working
camera, GNSS, or fingerprint path in this kernel/rootfs combination.

Sensors are handled separately; the accelerometer, gyroscope and magnetometer
enumerate and `monitor-sensor` reports live orientation, but the light and
proximity channels are not exposed yet.  See
[`../userspace/sensors/README.md`](../userspace/sensors/README.md).

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
- The MultiMedia1 front end must run at `S16_LE` to match the Primary MI2S
  backend.  When it runs at `S24_LE`, the Q6 DSP behaves as if only the low 16
  bits reach the MAX98937, so playback is clean but ~48 dB too quiet.  The
  kernel enforces this for the sound card when the device tree sets
  `qcom,force-s16-fe` (`kernel/patches/local/0002-...`); the constraint is
  opt-in and only touches `MultiMedia1` playback.  This means any distribution
  gets the loud path from the kernel alone, with no userspace rule.
- `userspace/audio/wireplumber` installs a rule that forces the speaker sink
  to `S16LE` as well.  It is kept for kernels that predate the kernel quirk and
  is harmless with it: it only matches the speaker sink and leaves the
  headphone and microphone formats alone.

In-call audio is a separate problem; see "Phone call audio" above.

### Bluetooth

`hci0` is present and the QCA UART setup completes in `dmesg`, but the
`bluetooth` service stays inactive and the stack is not usable.

### Vibration and flashlight

The vibrator is the PM660L haptics block, driven by `qcom_spmi_haptics`
(`qcom,pmi8998-haptics`).  `sdm660-xiaomi-lavender-common.dtsi` overrides the
generic node for an ERM actuator in direct-play mode; it appears as
`/dev/input/event4` (`spmi_haptics`) and responds to `FF_RUMBLE`.  Test it with
a force-feedback tool (`fftest`, `fbcli`, or the Phosh vibration setting).

The flashlight still does not work: the device exposes only `mmc1::`,
`mmc2::`, and `white:status` LEDs, and there is no flash LED node, so there is
no torch device under `/sys/class/leds`.

### Offline charging

Powering off and plugging in USB does not enter a dedicated offline charging
mode. Charge the phone while the system is booted.

## Not tested

- Deep sleep / hibernation (`disk` state)
- USB host / OTG
- IR blaster
- Dual-SIM operation (only slot 1 was reliable)
- Panels other than Shenchao (Tianma, BOE)

## Known workarounds

| Issue | Workaround |
| --- | --- |
| SIM not detected | Put the SIM in slot 1; `systemctl restart modem-uim-init ModemManager` |
| Modem stuck after a failed restart | `qcom-mss-stop`, then restart `rmtfs` (never restart `rmtfs` on a live modem) |
| WiFi and modem vanish together (after resume or a radio toggle) | they share the MSS remoteproc; the modem re-enumerates under a new `mmcli -L` index. `nmcli radio wifi off; nmcli radio wifi on; systemctl restart ModemManager` |
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
`tr '\0' '\n' < /proc/$(pgrep -x phosh)/environ | grep -E 'GSK_RENDERER|FD_MESA_DEBUG'`).
For glyph/texture loss also record the Mesa ABI actually in use:

```sh
readelf -d /usr/lib/libEGL_mesa.so.0 | grep libgallium
sha256sum /usr/lib/libgallium-*.so
```