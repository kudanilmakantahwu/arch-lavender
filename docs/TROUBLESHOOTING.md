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

If no interface appears, the RNDIS gadget did not start. On the phone (the
`getty@tty2` console, Ctrl+Alt+F2, or a serial console):

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

To rule the ownership bug in or out from the phone's console:

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
on `tty1`; the font applies to the `getty@tty2` fallback. Check and change it
live:

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

Phosh owns `tty1`, so `getty@tty1` is intentionally disabled. Switch to the
fallback console with **Ctrl+Alt+F2** (`getty@tty2`), or log in over SSH.
Check:

```sh
systemctl is-enabled getty@tty2
systemctl status getty@tty2
```

If `getty@tty2` is missing, enable it:

```sh
systemctl enable --now getty@tty2
```

### Text loses random letters (glyph glitches)

GTK4's NGL renderer has a broken glyph cache on freedreno/Adreno 512. Headers
and buttons show missing letters while small text looks fine. The image exports
`GSK_RENDERER=cairo` in `/etc/environment` and in `phosh.service`; verify it
reached the session:

```sh
tr '\0' '\n' < /proc/$(pgrep -n phosh)/environ | grep GSK_RENDERER
# GSK_RENDERER=cairo
```

If it is missing, reinstall the unit or add the variable, then restart:

```sh
systemctl daemon-reload
systemctl restart phosh
```

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
- On-screen keyboard missing: check `pgrep -x squeekboard`.

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
- Touch input is offset: the panel/touch node may not match; check
  `/proc/device-tree/model` is `Xiaomi Redmi Note 7 (Shenchao)`.
- The compositor crashes after a GPU hang: reboot and check
  `dmesg | grep -i a5xx`.
- On-screen keyboard does not appear: `squeekboard` may not be running.

To go back to a text-only boot:

```sh
systemctl set-default multi-user.target
systemctl disable phosh
reboot
```

`getty@tty2` is always available with Ctrl+Alt+F2, and SSH over USB stays up,
so a broken session is never a lockout.