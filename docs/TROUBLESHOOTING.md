# Troubleshooting

Start with the boot log. On the phone:

```sh
dmesg -T | tail -200
journalctl -b -p warning --no-pager
```

From the PC, over USB:

```sh
ssh root@172.16.42.1
```

If SSH is not reachable, see [No USB network](#no-usb-network).

---

## Boot problems

### The phone boots into Android instead of Arch

The boot image was not written, or the bootloader rejected it.

```sh
fastboot devices
fastboot getvar unlocked          # must say yes
fastboot flash boot ~/lavender-assets/arch-lavender-boot.img
fastboot reboot
```

You can also test without writing:

```sh
fastboot boot ~/lavender-assets/arch-lavender-boot.img
```

If `fastboot boot` works but `fastboot flash boot` does not, the boot
partition is the wrong slot or the image is too large. The tested boot image
is 38 MiB and the `boot` partition is 64 MiB.

### Boot loop / black screen

1. Enter fastboot (Volume Down + Power).
2. Re-flash the proven boot image.
3. Re-flash `userdata` only if the root filesystem is damaged. This erases
   data.

Do not flash `vbmeta`, `dtbo`, `system`, or `vendor` from another guide. The
install does not touch them.

### `fastboot: not enough space to download`

You are flashing a raw 8 GiB image. Build the sparse image:

```sh
img2simg rootfs.img rootfs.img.sparse
fastboot flash userdata rootfs.img.sparse
```

If `img2simg` is missing, install `android-sdk-libsparse-tools` (Debian) or
`android-tools` (Arch).

### `fastboot: Device not found`

- Use a data cable, not a charge-only cable.
- Try another USB port (prefer a direct port, not a hub).
- On Linux, check `lsusb` for `18d1:d00d` (fastboot) or the Xiaomi ID.
- Add udev rules if permission is denied; or run `fastboot` as root.

---

## Initramfs problems

### `ARCH-INIT: !!! rootfs not found -> emergency shell`

The initramfs mounted no root filesystem. In the emergency shell:

```sh
ls -l /dev/mmcblk* /dev/disk/by-partlabel/*
blkid
```

You should see `mmcblk1p66` with `LABEL="pmOS_root"`. If it is missing, the
`userdata` flash failed or the partition table was changed.

If the device exists but the label is wrong:

```sh
e2label /dev/mmcblk1p66 pmOS_root
```

Then reboot.

### `ARCH-INIT: preen failed (rc=4), forcing full repair`

This is normal after an unclean shutdown. The initramfs runs a full
`e2fsck -f -y`. Let it finish; it can take a minute on a 50 GiB filesystem.

If it repeats every boot, the flash is failing or the eMMC is worn. Back up
what you can and re-flash.

### `ARCH-INIT: repairing /lib symlink`

A previous extraction produced `/lib` as a real directory instead of a
symlink to `usr/lib`. The initramfs moves the firmware and repairs the
symlink. This is a self-heal, not an error.

### Systemd drops to `emergency.target`

Mount the root filesystem from the initramfs shell and inspect:

```sh
mount -o rw /dev/mmcblk1p66 /newroot
ls /newroot/etc/systemd/system
cat /newroot/etc/fstab
```

The usual cause is a broken `/etc/fstab` or a missing `default.target`.
`/etc/fstab` must contain:

```
LABEL=pmOS_root / ext4 defaults,noatime 0 1
```

---

## No USB network

The phone should create `usb0` with `172.16.42.1/24` and run a DHCP server.

On the PC:

```sh
ip -brief link
dmesg | tail -30
```

Look for a new `usb0` / `enp0s20u*` interface. If it exists:

```sh
sudo dhclient usb0
ip addr show usb0
ping -c3 172.16.42.1
```

If DHCP does not work, set the address manually:

```sh
sudo ip addr add 172.16.42.2/24 dev usb0
sudo ip link set usb0 up
```

If no interface appears, the RNDIS gadget did not start. On the phone, log in
over Wi-Fi SSH (the USB link is what you are debugging), or use `getty@tty2`
with a USB keyboard:

```sh
systemctl status usb-net-debug
journalctl -u usb-net-debug -b
cat /var/log/usb-net-debug.log
```

Common causes:

- **Every file in the image is owned by uid/gid 1000.** The released tarball
  was repacked by an unprivileged user, so a naive extraction leaves the whole
  tree owned by `1000:1000`. Setuid helpers then run as euid 1000, and
  `systemd` cannot create `/sys/kernel/config`; the journal shows
  `sys-kernel-config.mount` failing and the gadget never appears. The same bug
  makes `sshd` refuse to start with
  `/usr/share/empty.sshd must be owned by root and not group or world-writable`.
  Fix by rebuilding with the current `build-rootfs.sh` (it runs
  `chown -R 0:0` and restores the setuid bits), or, on a live system:

  ```sh
  chown -R 0:0 /
  chmod 600 /etc/shadow /etc/gshadow
  chmod 440 /etc/sudoers
  for f in /usr/bin/{mount,umount,su,sudo,passwd,newgrp,chsh,chfn,gpasswd}; do
      chmod u+s "$f"
  done
  ```

  `chown -R` also resets `/home`; restore the user directories afterwards.
- `/var/log` does not exist, so `usb-net-debug.sh` exits at
  `exec >>/var/log/usb-net-debug.log` before creating the gadget. This
  affected images built from the first sanitized tarball; current
  `build-rootfs.sh` recreates `/var/log`, and the script also makes it itself.
- The kernel module `usb_f_rndis` is missing (it is in the shipped kernel).
- The UDC is already bound to another gadget; unbind it first.
- The host does not support RNDIS (rare on Linux; Windows needs the RNDIS
  driver).

To rule the ownership bug in or out from a USB-keyboard console
(`getty@tty2`), or over Wi-Fi SSH if `sshd` still starts:

```sh
ls -ln /usr/bin/mount /usr/bin/sudo /usr/share/empty.sshd
stat -c '%u:%g' /
```

All three must be `0 0`. If they are `1000 1000`, rebuild the image.

### SSH refuses the connection

```sh
systemctl status sshd
ss -lntp | grep :22
```

If `systemctl status sshd` reports

```
/usr/share/empty.sshd must be owned by root and not group or world-writable
```

the image has the ownership bug described under [No USB
network](#no-usb-network); `chown -R 0:0 /` fixes it.

The shipped config allows root login with a password
(`/etc/ssh/sshd_config.d/99-root-login.conf`). Change it after you set a real
password:

```
PermitRootLogin prohibit-password
PasswordAuthentication no
```

Use SSH keys instead.

### `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`

You are talking to a different phone, or the host keys were regenerated.
Remove the old entry:

```sh
ssh-keygen -R 172.16.42.1
```

The shipped rootfs has no host keys; they are generated on first boot.

---

## Internet over USB

If WiFi is not configured yet and the PC has internet, share it:

```sh
sudo ./scripts/nat.sh
```

The script:

1. auto-detects the USB interface (`enx*` or `usb*`),
2. sets `172.16.42.2/24` on it,
3. enables IPv4 forwarding and NAT from `172.16.42.0/24` to the PC's default
   interface.

Then on the phone:

```sh
ip route replace default via 172.16.42.2 dev usb0
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
ping -c3 172.16.42.2
ping -c3 1.1.1.1
```

If `ping 172.16.42.2` works but `ping 1.1.1.1` does not, the PC is not
forwarding. Check `sysctl net.ipv4.ip_forward` (must be `1`) and the
`iptables -t nat -L POSTROUTING -n` rules. On a PC using `nftables` directly,
`iptables` may be `iptables-nft`; install the `iptables` compatibility package
if the command is missing.

---

## Console and graphical session

### The console font is too small

The default kernel font on a 1080×2340 panel is 8×16. The image sets a 16×32
font (`latarcyrheb-sun32`) in `/etc/vconsole.conf`. The graphical session runs
on `tty1`; the font applies to the `getty@tty2` console, which needs a USB/OTG
keyboard on this phone. Check and change it live:

```sh
stty -F /dev/tty2 size          # 73 67 with the big font, 146 135 with 8x16
cat /etc/vconsole.conf
setfont -C /dev/tty2 latarcyrheb-sun32
setfont -C /dev/tty2 -R         # default 8x16
```

If the font reverts after a reboot, `systemd-vconsole-setup` did not read the
file: check `systemctl status systemd-vconsole-setup` and try running
`systemctl restart systemd-vconsole-setup`.

### No text console at all

Phosh owns `tty1`, so `getty@tty1` is intentionally disabled. `getty@tty2` is
enabled, but this phone has no built-in keyboard, so reaching it needs a
USB/OTG keyboard and **Ctrl+Alt+F2**. Without one, log in over SSH (USB or
Wi-Fi) instead. Check:

```sh
systemctl is-enabled getty@tty2
systemctl status getty@tty2
```

If `getty@tty2` is missing, enable it:

```sh
systemctl enable --now getty@tty2
```

### Text loses random letters (glyph glitches)

The default renderer is `GSK_RENDERER=ngl` (GL), which scrolls text about twice
as fast as cairo on the Adreno 512. If headers or buttons start losing letters,
switch back to the cairo renderer, which is slower but has never corrupted
glyphs:

```sh
sed -i '/^GSK_RENDERER=/d' /etc/environment
echo 'GSK_RENDERER=cairo' >> /etc/environment
sed -i 's/GSK_RENDERER=ngl/GSK_RENDERER=cairo/' /etc/systemd/system/phosh.service.d/*.conf 2>/dev/null
systemctl daemon-reload
systemctl restart phosh
tr '\0' '\n' < /proc/$(pgrep -n phosh)/environ | grep GSK_RENDERER
# GSK_RENDERER=cairo
```

### Compositor dies while touching the screen (`phoc` SIGSEGV)

`phoc` can crash in `handle_touch_up` → `wlr_surface_get_root_surface` when the
surface under the finger disappears (app closed, keyboard dismissed, job
finished) between touch-down and touch-up:

```
#0 wlr_subsurface_try_from_wlr_surface (libwlroots-0.20.so)
#1 wlr_surface_get_root_surface (libwlroots-0.20.so)
#3 handle_touch_up (libwlroots-0.20.so)
```

The session dies with it; `systemctl` restarts `phosh.service` and everything
reopens. It is a wlroots 0.20/phoc bug, not a kernel or renderer problem, and
it happens with both cairo and ngl. Confirm with:

```sh
coredumpctl list --since '-1 hour'
coredumpctl info $(coredumpctl list --since '-1 hour' -F PID | tail -1)
```

Avoid closing apps with an active touch, and keep the touchscreen still while
an app exits.

### Firefox and other GPU apps show magenta blocks or blank pages

On Adreno 512, Mesa's UBWC (bandwidth compression) corrupts buffers shared
between WebRender/EGL clients and the compositor. Firefox pages appear as
magenta/red rectangles, shifted surfaces, or plain white/black windows. The
same corruption can hit other GPU-accelerated third-party apps.

Disable UBWC for the session; the image already does this in
`/etc/environment` and in `phosh.service`:

```sh
export FD_MESA_DEBUG=noubwc
```

Verify it reached the session and the app:

```sh
tr '\0' '\n' < /proc/$(pgrep -n phosh)/environ | grep FD_MESA_DEBUG
# FD_MESA_DEBUG=noubwc
tr '\0' '\n' < /proc/$(pgrep -n firefox)/environ | grep FD_MESA_DEBUG
```

With the variable set, a test page with solid red, blue, and green blocks must
render cleanly. To confirm the cause without a reboot, launch Firefox once with
`FD_MESA_DEBUG=noubwc firefox`.

### Phosh does not start / black screen

```sh
systemctl status phosh
journalctl -b -u phosh -n 50 --no-pager
dmesg | grep -iE 'msm|dpu|adreno|a5xx'
```

Common causes:

- `seatd` is not running: `systemctl status seatd`, `systemctl enable --now seatd`.
- The session user cannot log in: `passwd -S alarm` must say `P` (password set).
- The compositor crashed after a GPU hang: reboot and check `dmesg | grep -i a5xx`.
- On-screen keyboard missing: check `pgrep -x phosh-osk-stevia`.

To fall back to a text-only boot:

```sh
systemctl set-default multi-user.target
systemctl disable phosh
reboot
```

Restore the default UI later with `systemctl set-default graphical.target` and
`systemctl enable phosh`.

---

## WiFi

### No password prompt when selecting a new network

Phosh's NetworkManager agent checks the keyring before it creates the
authentication dialog. Without a Secret Service provider the lookup fails and
the dialog is never shown; NetworkManager then reports that no secrets were
provided.

Make sure `gnome-keyring` is installed and `org.freedesktop.secrets` is
activatable:

```sh
pacman -Q gnome-keyring
sudo pacman -S --needed gnome-keyring
busctl --user list | grep org.freedesktop.secrets
secret-tool search test test
```

`secret-tool` should not print `The name is not activatable`. After installing
gnome-keyring, try the network again; no phosh or NetworkManager configuration
change is needed. The user socket is enabled by the package.

### WiFi interface missing

```sh
ip -brief link
dmesg | grep -i ath10k
```

The WCN3990 firmware is in `/usr/lib/firmware/ath10k/WCN3990/hw1.0/`. If it
is missing, the rootfs extraction was incomplete.

### WiFi disappears after disconnect

The `0006` patch prevents the `ath10k` firmware crash on disassociation. If
the device is already wedged, reboot:

```sh
reboot
```

If it still happens, check that the running kernel is the patched one:

```sh
uname -r
dmesg | grep -i 'ath10k.*firmware'
```

### Connected but no internet

```sh
nmcli connection show
ip route
cat /etc/resolv.conf
ping -c3 1.1.1.1
ping -c3 archlinux.org
```

If IP works but DNS does not, fix the resolver. NetworkManager usually writes
`/etc/resolv.conf`; make sure it is not a stale symlink.

### Cannot reach the phone from another WiFi client

Some access points enable client isolation. The phone is reachable over USB
regardless. Use the USB link, or put the phone and PC on the same non-isolated
network.

---

## Audio

### No sound from the speaker

Check that the amplifier driver bound and that the MAX98937 was detected:

```sh
dmesg | grep -i max98937
ls /sys/bus/i2c/drivers/max98937/1-003a
cat /proc/asound/cards
```

`dmesg` should show `MAX98937 revisionID: 0x43` and no `max98927` lines.  The
phone's amplifier is a MAX98937, not a MAX98927; the mainline `max98927`
driver binds but programs the wrong register addresses and the speaker stays
silent.

Check the routing and the amplifier state:

```sh
amixer -c 0 cset name='PRI_MI2S_RX Audio Mixer MultiMedia1' on
# "Speaker Volume": 0 = +3 dB, 5 = +18 dB (vendor default), 6 = +21 dB
# (the shipped profile uses 6).
# "Digital Volume": 0 = -16 dB, 56 = -2 dB (vendor default), 64 = 0 dB.
# Do not raise Digital Volume above 56; use PipeWire's per-stream volume.
amixer -c 0 cset name='Digital Volume' 56
amixer -c 0 cset name='Speaker Volume' 6
speaker-test -D hw:0,0 -c 2 -t sine -f 800 -l 1
```

`speaker-test -D hw:0,0` bypasses PipeWire's software volume and plays at the
hardware gain.  Turn the phone's volume down first and do not hold the speaker
to your ear.

### Speaker crackles, or is loud on a test tone but quiet in apps

An older version of the UCM profile set `Digital Volume` to 127.  That is
**+15.75 dB** of digital gain, not "a bit over 100": anything near full scale
clips the DAC, which is the crackle.  A direct `aplay` or `speaker-test` also
bypasses PipeWire's software volume, so it was ~20 dB louder than the same
file played from an app.

Keep `Digital Volume` at 56 (-2 dB, the vendor value) and let PipeWire's
per-stream volume do the attenuation.  The shipped profile uses `Speaker
Volume 6` (+21 dB); the vendor default is 5 (+18 dB).  Check them:

```sh
amixer -c 0 cget name='Digital Volume'
amixer -c 0 cget name='Speaker Volume'
amixer -c 0 cget name='Amp DSP Switch'   # must be off
```

`Amp DSP Switch=on` enables the brownout DSP, which this profile does not use.
Turning it on by hand can leave the amp enabled but silent; the UCM keeps it
off, matching the driver's init sequence.

### Speaker sink is missing (only "Dummy Output")

Check that the kernel bound the machine driver:

```sh
ls /proc/asound/cards          # must list "Xiaomi Redmi Note 7"
lsmod | grep sm8250            # snd_soc_sm8250 must be loaded
```

If the card list is empty, the kernel was built with
`# CONFIG_SND_SOC_SM8250 is not set`.  That option must be `=m`; the card
cannot appear without it, and no userspace rule can fix it.

If the card is present but `wpctl status` only shows `Dummy Output`, the UCM
verb failed to activate.  PipeWire's ACP probes every device in the verb; a
capture device that cannot be opened makes the whole profile unsupported.  The
shipped profile keeps `Mic` in a separate verb so this cannot disable the
speaker.  Verify the files and restart the session manager:

```sh
ls /usr/share/alsa/ucm2/Qualcomm/lavender/{HiFi,Mic}.conf
systemctl --user restart wireplumber
wpctl status | sed -n '/Sinks:/,/Sources:/p'
```

### Speaker is clean but extremely quiet in apps

Symptom: the speaker works, the audio is clean, but even at 100% it is only
just audible.  A direct `aplay -f S16_LE` on `hw:0,0` can be loud because it
opens the PCM at the backend's 16-bit format; PipeWire's default is different.

This is the 24-bit front end / 16-bit backend mismatch.  While audio is
playing, check the live format:

```sh
cat /proc/asound/card0/pcm0p/sub0/hw_params
```

`format: S24_LE` is wrong for the speaker path.  The machine driver fixes
Primary MI2S at 48 kHz/S16_LE, and the Q6 DSP behaves as if only the low 16
bits of every 24-bit sample reach the MAX98937: about 48 dB (a factor of 256)
of loss.  The vendor kernel never hits this because its
`mi2s_rx_cfg[PRIM_MI2S]` is already `S16_LE`.

Since 7.2.3-sdm660 build `v1.2`, the machine driver itself pins the front end
to `S16_LE` whenever the device tree sets `qcom,force-s16-fe`, so the format
is already correct for every client and every distribution:

```sh
ls /proc/device-tree/sound/qcom,force-s16-fe
cat /proc/asound/card0/pcm0p/sub0/hw_params    # format: S16_LE
```

If the property is missing, the running kernel/boot image predates the quirk.
Install the WirePlumber rule shipped in `userspace/audio` as a userspace
fallback:

```sh
sudo install -Dm644 \
    userspace/audio/wireplumber/wireplumber.conf.d/50-lavender-s16.conf \
    /etc/wireplumber/wireplumber.conf.d/50-lavender-s16.conf
systemctl --user restart wireplumber
```

Confirm the node property and play something:

```sh
wpctl inspect @DEFAULT_AUDIO_SINK@ | grep audio.format   # audio.format = "S16LE"
cat /proc/asound/card0/pcm0p/sub0/hw_params              # format: S16_LE
```

The rule matches the speaker sink only, so headphone playback keeps its
native format.  Do not "fix" this by raising `Digital Volume`; that only adds
clipping gain and cannot recover the missing bits.

### Audio is silent after a suspend/resume or a reboot

WirePlumber remembers a volume and mute flag per card name.  When a failed
suspend/resume re-registers the card it gets a `.2`/`.24` suffix, and an old
muted/0% entry can be restored for the new name.  Check the live sink and the
saved routes:

```sh
pactl get-sink-volume @DEFAULT_SINK@
pactl get-sink-mute @DEFAULT_SINK@
cat ~/.local/state/wireplumber/default-routes
```

If the live sink is muted or at 0%, restore it:

```sh
pactl set-sink-mute @DEFAULT_SINK@ 0
pactl set-sink-volume @DEFAULT_SINK@ 100%
```

The shipped image disables automatic suspend (`sleep.conf.d` and
`lavender-session-defaults`).  s2idle does enter and resume, but the RTC wake
is intermittent (see [FINDINGS.md](FINDINGS.md) section D) and `ath10k`/the
USB gadget do not always recover, so the phone can end up unreachable while it
is still running.  Do not re-enable it just to save power; power the phone off
instead.

### WiFi and the modem disappear together (after resume or a radio toggle)

`ath10k`/WCN3990 runs on the modem DSP (`4080000.remoteproc`), so a WiFi
firmware crash also restarts the MSS and re-enumerates — or drops — the modem.
Symptoms: `nmcli` shows `wlan0` gone, `mmcli -L` prints "No modems were found",
and the SIM looks unreadable.  Confirm it in the kernel log:

```sh
dmesg | grep -iE 'EX:wlan_process|crash detected|ath10k.*crashed'
```

If the MSS recovered, the modem comes back under a **new index** within
seconds; always take the index from `mmcli -L` (do not hard-code `mmcli -m 0`).
If it did not come back, nudge the radio and the modem stack:

```sh
nmcli radio wifi off; sleep 1; nmcli radio wifi on
systemctl restart ModemManager
```

Turning the radio off can itself trigger the crash, so use it only as a
recovery step.  See [FINDINGS.md](FINDINGS.md) section D1.

While a tone is playing, the amp registers should read (via `/dev/i2c-1`,
`i2cset`/`i2cget` or a small script):

| Register | Meaning | Value |
| --- | --- | --- |
| `0x0039` | `AMP_ENABLES` | `0x81` (bit 0 `SPK_EN`) |
| `0x0500` | `GLOBAL_EN` | `0x01` |
| `0x0023` | `PCM_MODE_CFG` | `0x40` (I2S, 16-bit) |
| `0x0026` / `0x0027` | sample rate | `0x08` / `0x88` (48 kHz) |

If `0x0039` is set but `0x0500` is `0x00`, the amp is in global shutdown and
will not produce sound.  A driver derived only from `max98927.c` misses this
register because it lives in the extended (`0x05xx`) address space.

### PipeWire shows `stereo-fallback` and logs `no backend DAIs enabled`

The UCM2 profile is missing or does not match the card.  The card driver is
`sdm660` (from the machine driver match data), and the long name is
`Xiaomi Redmi Note 7`:

```sh
alsaucm -c hw:0 dump text | head -20
```

It must list the `HiFi` verb with `Speaker` and `Mic` devices.  Install the
files from `userspace/audio/ucm2` into `/usr/share/alsa/ucm2/`, then:

```sh
systemctl --user restart wireplumber
wpctl status
```

The sink `Built-in Audio Speaker playback` and source `Built-in Audio Internal
microphone` appear when UCM is used.  `alsa_output.platform-sound.*.fallback`
means UCM was not picked up.

### The microphone is silent

The internal mic is on the PM660L analog codec, ADC1:

```sh
amixer -c 0 cset name='MultiMedia2 Mixer LPI_MI2S_TX_3' on
amixer -c 0 cset name='ADC1 Volume' 8
arecord -D hw:0,1 -f S16_LE -c 1 -r 48000 -d 3 /tmp/mic.wav
```

Play something through the speaker while recording if you want a quick
self-test; the 48 kHz capture should pick it up clearly.

### No audio during a phone call

Expected with this kernel.  Playback and microphone capture use the multimedia
DSP paths (q6asm/q6afe), but call audio needs the separate voice-call DSP
service (`q6voice`) and a `Voice Call` frontend DAI, neither of which exists in
Linux 7.2.3.  Adding a `Voice Call` UCM verb does not help because there is no
PCM behind it.  Call setup and SMS still work.

---

## Modem
### `mmcli -L` shows no modem

Check the service chain:

```sh
systemctl --no-pager status tqftpserv pd-mapper diag-router rmtfs modem-uim-init
ls /sys/class/remoteproc/
for r in /sys/class/remoteproc/remoteproc*; do
    echo "$r $(cat $r/name) $(cat $r/state)"
done
```

`remoteproc` for the modem should eventually be `running`. The firmware boots
in this order:

```
shutting-down -> low-power -> online
```

If it is stuck in `shutting-down`, the previous modem instance did not stop
cleanly:

```sh
systemctl stop ModemManager
/usr/local/sbin/qcom-mss-stop
sleep 2
systemctl restart rmtfs
sleep 5
systemctl restart modem-uim-init ModemManager
```

> **Never** restart `rmtfs` while the modem is running. Stop the modem first.

### Modem is online but there is no SIM

The UIM provisioning session was not opened. Run:

```sh
/usr/local/sbin/modem-uim-init
mmcli -L
```

Or restart the unit:

```sh
systemctl restart modem-uim-init ModemManager
```

The QMI call needs the AID:

```
A0000000871002FF82FF3089010000FF
```

If you run it by hand, use exactly that value.

### SIM is detected but registration fails

- Confirm the SIM is in **slot 1**.
- Check the operator:

  ```sh
  mmcli -m 0 | grep -E 'operator|state|access'
  ```

- Check the modem firmware and QRTR services:

  ```sh
  qrtr-lookup
  ```

- Reboot. The modem stack is sensitive to the order in which `rmtfs` and
  `diag-router` start; the shipped units encode the correct order.

### `No valid data port found to launch connection`

This is expected. There is no IPA driver, so cellular data cannot work. SMS,
registration, and calls do not need a data port. The ModemManager patch stops
ModemManager from refusing to start the modem because of the missing port.

### SMS fails to send

```sh
mmcli -m 0 --messaging-list-sms
mmcli -m 0 --messaging-create-sms="text='test',number='+62xxxxxxxxxx'"
mmcli -s 0 --send
```

Check the SMSC is provisioned by the operator. The tested device worked on
Telkomsel LTE after `modem-uim-init` had run.

---

## Time, TLS, and pacman

### `pacman` fails with signature or TLS errors

The clock is probably wrong. The phone has no useful RTC.

```sh
timedatectl status
timedatectl set-ntp true
timedatectl set-timezone Asia/Jakarta
```

If NTP cannot reach the network, set the time manually:

```sh
date -s "2026-11-06 12:00:00"
```

### `pacman` keyring errors

```sh
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy archlinuxarm-keyring
```

Then retry the upgrade.

### `pacman -Syu` wants to replace the kernel

`linux-aarch64` and `linux-aarch64-headers` are in `IgnorePkg`. If they are
not, edit `/etc/pacman.conf`. The kernel is not managed by `pacman` on this
install.

### ModemManager fails after an upgrade

The patched binary is restored by
`/etc/pacman.d/hooks/99-local-patches.hook` from
`/usr/local/lib/patched/ModemManager`. If the package ABI changed, rebuild the
patch:

```sh
# see userspace/README.md
```

---

## Graphical session

Phosh is the default UI, not an opt-in experiment. Common symptoms:

- Phosh starts but the screen stays black: check `systemctl status phosh`,
  `journalctl -u phosh -b`, and `dmesg | grep -i msm`.
- Text loses random glyphs: make sure `GSK_RENDERER=cairo` reached the session
  (see [glyph glitches](#text-loses-random-letters-glyph-glitches)).
- Firefox shows magenta blocks or blank pages: make sure
  `FD_MESA_DEBUG=noubwc` reached the session (see
  [GPU app corruption](#firefox-and-other-gpu-apps-show-magenta-blocks-or-blank-pages)).
- Touch input is offset: the panel/touch node may not match; check
  `/proc/device-tree/model` is `Xiaomi Redmi Note 7 (Shenchao)`.
- The compositor crashes after a GPU hang: reboot and check
  `dmesg | grep -i a5xx`.
- On-screen keyboard does not appear: check
  `systemctl --user status mobi.phosh.OSK`; the provider is
  `phosh-osk-stevia` (the image no longer ships `squeekboard`).
- No terminal in the app grid: `foot` is no longer shipped.  The default
  terminal is GNOME Console (`kgx`); install `foot` yourself if you prefer it.

To go back to a text-only boot:

```sh
systemctl set-default multi-user.target
systemctl disable phosh
reboot
```

SSH over USB stays up, so a broken session is never a lockout. `getty@tty2`
is also available with Ctrl+Alt+F2 when a USB keyboard is attached.