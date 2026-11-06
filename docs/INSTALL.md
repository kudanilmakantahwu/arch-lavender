# Install Arch Linux ARM on the Redmi Note 7

This is the complete walkthrough, in the order it was actually performed on a
real Redmi Note 7 (`lavender`). It installs the **headless** system: a console
on `tty1` and SSH over USB, with WiFi and the modem configured afterwards.

Read the whole page once before starting. Anything marked **destructive**
erases data.

- [0. What you need](#0-what-you-need)
- [1. Unlock the bootloader](#1-unlock-the-bootloader)
- [2. Install host tools](#2-install-host-tools)
- [3. Download and verify the release](#3-download-and-verify-the-release)
- [4. Build the root filesystem image](#4-build-the-root-filesystem-image)
- [5. Flash the phone](#5-flash-the-phone)
- [6. First boot and first login](#6-first-boot-and-first-login)
- [7. Grow the root filesystem](#7-grow-the-root-filesystem)
- [8. Set the root password and add a user](#8-set-the-root-password-and-add-a-user)
- [9. Configure WiFi](#9-configure-wifi)
- [10. Set the clock and timezone](#10-set-the-clock-and-timezone)
- [11. Verify the install](#11-verify-the-install)
- [12. Modem, SIM and SMS](#12-modem-sim-and-sms)
- [13. Package management](#13-package-management)
- [14. Updating the kernel](#14-updating-the-kernel)
- [15. Re-flashing and recovery](#15-re-flashing-and-recovery)
- [16. Experimental GUI](#16-experimental-gui)

---

## 0. What you need

- A Xiaomi Redmi Note 7 (`lavender`), any RAM/storage variant.
- A USB data cable that can carry data, not just power.
- A Linux PC or VM with at least 10 GB free. Debian/Ubuntu and Arch are both
  fine. Windows works for `fastboot`, but the rootfs build script assumes a
  Unix host.
- The phone charged to at least 50 %.
- Patience: the first boot and the first `pacman -Syu` are slow.

You do **not** need a custom recovery. The boot image is flashed directly with
`fastboot`.

> **Back up anything you care about.** Both the bootloader unlock and the
> `userdata` flash erase the phone.

## 1. Unlock the bootloader

This is mandatory. The stock bootloader only boots signed images.

1. On Android, enable **Developer options**, then **OEM unlocking** and **USB
   debugging**.
2. Insert a SIM and sign in to a Mi account, then bind the device in
   **Mi Unlock status**. Xiaomi enforces a waiting period (usually 168 hours)
   before the unlock is allowed.
3. After the waiting period, unlock with Xiaomi's **Mi Unlock Tool**, or with
   the token flow:

   ```sh
   adb reboot bootloader
   fastboot oem unlock <TOKEN>
   ```

4. Confirm:

   ```sh
   fastboot getvar unlocked      # must print: unlocked: yes
   ```

The phone wipes itself during the unlock. This is expected.

> The exact Mi Unlock UI and waiting period are controlled by Xiaomi and can
> change. This guide does not try to replace their instructions; it only notes
> that an unlocked bootloader is a hard requirement.

## 2. Install host tools

You need `fastboot`, `zstd`, `e2fsprogs` (`mkfs.ext4`, `e2fsck`,
`resize2fs`), `tar`, `unzip`, and ideally `img2simg`.

**Debian / Ubuntu**

```sh
sudo apt update
sudo apt install android-sdk-platform-tools-common fastboot zstd \
                 e2fsprogs unzip python3 android-sdk-libsparse-tools
```

If `android-sdk-libsparse-tools` is not available, install `img2simg` from
your distribution or skip the sparse step and flash the raw image (slower).

**Arch Linux**

```sh
sudo pacman -S android-tools zstd e2fsprogs unzip python
# img2simg is provided by android-tools on Arch
```

Check:

```sh
fastboot --version
mkfs.ext4 -V
zstd --version
command -v img2simg || echo "img2simg missing (optional)"
```

## 3. Download and verify the release

Download the assets from the GitHub release (replace the tag if needed):

```sh
mkdir -p ~/lavender-assets && cd ~/lavender-assets

gh release download v1.0 \
  --repo kudanilmakantahwu/arch-lavender \
  --pattern 'arch-lavender-boot.img' \
  --pattern 'arch-initramfs-fsck.gz' \
  --pattern 'rootfs-arch.tar.zst' \
  --pattern 'linux-7.0.14-sdm660.zip' \
  --pattern 'sha256sums.txt'
```

If you do not use `gh`, download the same files from the release page in a
browser.

Verify:

```sh
sha256sum -c sha256sums.txt
```

Every line must say `OK`.

## 4. Build the root filesystem image

The release ships a **tarball**, not a disk image, because a 1.2 GB tarball
compresses better and is easier to verify than a 3.5 GB sparse image. The
script turns it into an ext4 image labelled `pmOS_root` (the label the
initramfs searches for).

Clone this repository next to the downloaded assets:

```sh
cd ~
git clone https://github.com/kudanilmakantahwu/arch-lavender.git
cd arch-lavender
```

Build the image (needs root for the loop mount):

```sh
sudo ./rootfs/build-rootfs.sh ~/lavender-assets/rootfs-arch.tar.zst ./rootfs.img
```

The script:

- creates an 8 GiB image with `mkfs.ext4 -L pmOS_root`,
- extracts the tarball with ownership preserved,
- applies `rootfs/overlay/` (fstab, sanitized `shadow`, sshd root login,
  USB networking),
- installs the base userspace units and scripts,
- sets the default target to `multi-user.target` (headless),
- removes SSH host keys and the machine id,
- runs `e2fsck` and `resize2fs`,
- converts to a sparse Android image with `img2simg` when available.

You should end up with:

```
rootfs.img          8.0G  raw ext4 image
rootfs.img.sparse   ~3.5G Android sparse image  (if img2simg is installed)
```

> **Do not** skip `img2simg`. Flashing an 8 GB sparse image is what was tested;
> a raw 8 GB image works but is much slower over USB and can hit fastboot
> transfer limits.

### Choosing a different size

The image only needs to be big enough for the packages. 8 GiB is plenty for a
headless install. Override it with:

```sh
sudo IMG_SIZE=12G ./rootfs/build-rootfs.sh rootfs-arch.tar.zst rootfs.img
```

The phone's `userdata` partition is much larger; it is grown online after the
first boot (step 7).

## 5. Flash the phone

**Destructive: this erases the `userdata` partition.**

1. Boot into fastboot:

   ```sh
   adb reboot bootloader
   ```

   or hold **Volume Down + Power** until the Fastboot logo appears.

2. Check the connection:

   ```sh
   fastboot devices
   fastboot getvar product        # should print lavender
   fastboot getvar unlocked       # should print yes
   ```

3. Flash both partitions. The boot image lives in the download directory
   (`~/lavender-assets`), the rootfs image in the repo directory:

   ```sh
   ./scripts/flash.sh ./rootfs.img.sparse ~/lavender-assets/arch-lavender-boot.img
   ```

   This runs exactly:

   ```sh
   fastboot flash userdata ./rootfs.img.sparse
   fastboot flash boot     ~/lavender-assets/arch-lavender-boot.img
   fastboot reboot
   ```

   `vbmeta` is **not** touched. Do not flash random `vbmeta` images from other
   guides unless you know your phone needs it.

4. The phone reboots. The first boot can take one to two minutes; the
   initramfs runs `e2fsck` before mounting the root filesystem.

If the phone boots back into Android instead, the boot image was not flashed
or the bootloader rejected it. Boot fastboot again and re-check
`fastboot getvar unlocked`.

## 6. First boot and first login

The rootfs creates a USB RNDIS gadget with a fixed address:

| Side | Address |
| --- | --- |
| Phone | `172.16.42.1/24` |
| PC | `172.16.42.2/24` (DHCP, or set manually) |

1. Connect the USB cable to the PC.
2. Find the new interface:

   ```sh
   ip -brief link
   ```

   It is usually called `usb0` or `enp0s20u1`.

3. Get an address:

   ```sh
   sudo dhclient usb0
   ```

   or manually:

   ```sh
   sudo ip addr add 172.16.42.2/24 dev usb0
   sudo ip link set usb0 up
   ```

4. Log in:

   ```sh
   ssh root@172.16.42.1
   ```

   The shipped password is **`arch`**.

5. You should see:

   ```
   Arch Linux ARM
   ...
   [root@lave-arch ~]#
   ```

If SSH is not reachable, see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#no-usb-network). The fallback is the
console on `tty1`: the phone's own display, with a USB keyboard attached
through an OTG adapter.

> The `usb-net-debug.service` unit creates the gadget. It is only a bootstrap
> link; once WiFi and SSH work you can leave it enabled (it is harmless) or
> disable it.

## 7. Grow the root filesystem

The flashed image is 8 GiB, but the `userdata` partition is larger (50 GiB on
the tested 64 GB phone). Grow the filesystem online:

```sh
resize2fs /dev/disk/by-partlabel/userdata
df -h /
```

`resize2fs` can grow a mounted ext4 filesystem. No reboot is required.

> The initramfs finds the root filesystem by UUID first and by the
> `pmOS_root` label second, so growing the filesystem does not break boot.

## 8. Set the root password and add a user

**Change the root password immediately.** The shipped `arch` password is
public.

```sh
passwd root
```

Add a normal user (optional but recommended):

```sh
useradd -m -G wheel -s /bin/bash yourname
passwd yourname
```

Make sure `sudo` is installed and the `wheel` group is allowed:

```sh
pacman -S sudo
visudo        # uncomment: %wheel ALL=(ALL:ALL) ALL
```

Log out and back in as the new user, and test `sudo -v`.

## 9. Configure WiFi

NetworkManager is enabled. The easiest path is the text UI:

```sh
nmtui
```

Or directly:

```sh
nmcli device wifi list
nmcli device wifi connect "YOUR_SSID" password "YOUR_PASSWORD"
nmcli connection show
ip -brief addr
ping -c3 1.1.1.1
```

The WiFi chip is a Qualcomm WCN3990 driven by `ath10k`. The kernel includes
the `0006` patch that keeps it alive across disconnects. If WiFi dies after a
disconnect, see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#wifi-disappears-after-disconnect).

Once WiFi works you can find the phone's LAN address with `ip addr` and SSH to
it directly. The USB link still works as a fallback.

## 10. Set the clock and timezone

```sh
timedatectl set-timezone Asia/Jakarta     # or your zone
timedatectl set-ntp true
timedatectl status
```

The phone has no RTC battery behaviour worth relying on; NTP over WiFi is what
keeps the clock sane.

## 11. Verify the install

Copy the verification script to the phone:

```sh
scp scripts/verify.sh root@172.16.42.1:/root/
ssh root@172.16.42.1 'sh /root/verify.sh'
```

It checks the kernel, root filesystem, module tree, services, network, clock,
and modem, and prints a `RESULT:` line. Warnings are normal on a fresh
headless install (for example, "WiFi not configured"). Failures are not.

## 12. Modem, SIM and SMS

**Put the SIM in slot 1.** Slot 2 was not reliable on the tested device.

The modem stack is a chain of services:

```
tqftpserv -> pd-mapper -> diag-router -> rmtfs -> modem-uim-init -> ModemManager
```

`modem-uim-init` is the important part. The modem firmware boots in this
order:

```
shutting-down -> low-power -> online
```

Only when it is `online` can the UIM provisioning session be opened. The
service does the equivalent of:

```sh
qrtr-lookup
qmic -d <MODEM> --uim-change-provisioning-session \
    --session-type primary --activate 1 \
    --aid A0000000871002FF82FF3089010000FF
```

Check the result:

```sh
mmcli -L
mmcli -m 0
systemctl status modem-uim-init ModemManager
```

You want a modem with a SIM and an operator. Example from the tested device:

```
state: registered
operator name: Telkomsel
operator id: 51010
access technology: lte
```

Send a test SMS:

```sh
mmcli -m 0 --messaging-create-sms="text='hello from arch',number='+62xxxxxxxxxx'"
mmcli -s 0 --send
mmcli -m 0 --messaging-list-sms
```

If the modem is present but there is no SIM:

```sh
systemctl restart modem-uim-init ModemManager
```

> **Never** run `systemctl restart rmtfs` on a live system. Stop the modem
> first with `qcom-mss-stop`, then start `rmtfs` again. Restarting `rmtfs`
> underneath a running modem leaves the remoteproc in a bad state.

### Cellular data

Cellular **data** does not work. The kernel has no SDM660 IPA driver, so the
modem exposes no network port. ModemManager reports:

```
No valid data port found to launch connection
```

That is expected. SMS and registration still work because they use QMI, not
the IPA data path.

## 13. Package management

`pacman` works. A few things are pinned or special:

- `linux-aarch64` and `linux-aarch64-headers` are in `IgnorePkg` in
  `/etc/pacman.conf`. The running kernel is not installed as a package; it
  comes from the release boot image / kernel zip.
- ModemManager is patched. The binary is stored in
  `/usr/local/lib/patched/ModemManager`, and
  `/etc/pacman.d/hooks/99-local-patches.hook` copies it back after an upgrade.
- The GUI packages are installed but not enabled by default. See
  [`GUI-EXPERIMENTAL.md`](GUI-EXPERIMENTAL.md).

Update:

```sh
pacman -Syu
```

After a large upgrade (systemd, glibc, NetworkManager) reboot. After a
ModemManager upgrade, check:

```sh
systemctl status ModemManager
mmcli -L
```

If ModemManager fails to start, the patched binary may no longer match the
installed libraries. Rebuild it as described in
[`../userspace/README.md`](../userspace/README.md).

## 14. Updating the kernel

The kernel is not managed by `pacman`. To update it:

1. Download `linux-<version>-sdm660.zip` and a matching boot image from the
   release (or build them; see [`BUILD-KERNEL.md`](BUILD-KERNEL.md)).
2. Install the modules into the root filesystem:

   ```sh
   # on the phone, with the zip copied to /root
   unzip -q linux-7.0.14-sdm660.zip -d /tmp/kernel
   rm -rf /usr/lib/modules/7.0.14-sdm660
   cp -a /tmp/kernel/modroot/usr/lib/modules/7.0.14-sdm660 /usr/lib/modules/
   depmod 7.0.14-sdm660
   ```

3. Reboot into fastboot and flash the matching boot image:

   ```sh
   fastboot flash boot ~/lavender-assets/arch-lavender-boot.img
   ```

   The boot image contains the kernel and the initramfs. Flashing only the
   modules without the matching kernel (or vice versa) will fail to boot.

If you rebuild the boot image yourself, use `kernel/make-bootimg.sh`; the
addresses and appended-DTB handling are already correct.

## 15. Re-flashing and recovery

### The phone does not boot

1. Hold **Volume Down + Power** to enter fastboot.
2. Re-flash the proven boot image:

   ```sh
   fastboot flash boot ~/lavender-assets/arch-lavender-boot.img
   fastboot reboot
   ```

3. If it still fails, boot the image without writing it:

   ```sh
   fastboot boot ~/lavender-assets/arch-lavender-boot.img
   ```

### The initramfs drops to an emergency shell

The init script prints `ARCH-INIT: !!! rootfs not found` and lists block
devices. Check:

```sh
ls -l /dev/mmcblk* /dev/disk/by-partlabel/*
blkid
```

The root filesystem must have the label `pmOS_root` (or the expected UUID).
If it does not, the userdata flash did not complete.

### The root filesystem is corrupt

The initramfs runs `e2fsck -p` before mounting. If preen fails it runs a full
`e2fsck -f -y`. If that is not enough, boot a recovery environment and run
`e2fsck -f -y /dev/mmcblk1p66` manually.

### Start over

Re-run steps 4–5. This erases the phone's data. The boot image does not need
to be rebuilt.

## 16. Experimental GUI

Phosh can be enabled at image-build time:

```sh
sudo ./rootfs/build-rootfs.sh rootfs-arch.tar.zst rootfs.img --with-gui
```

It is still buggy. Read [`GUI-EXPERIMENTAL.md`](GUI-EXPERIMENTAL.md) before
enabling it, and keep the USB SSH link as your escape hatch.