# Arch Linux ARM on the Redmi Note 7 (`lavender`)

A step-by-step, actually-tested guide to running Arch Linux ARM on the Xiaomi Redmi Note 7 with a mainline Qualcomm SDM660 kernel.

> **Warning:** **This is not an officially supported distribution.** Following this guide will wipe Android completely. You can brick your phone if you skip steps. Read [`docs/INSTALL.md`](docs/INSTALL.md) thoroughly before starting.
> ⚠️ **Display Panel Note:** This build and driver stack have been explicitly tested **only on the Shenchao display panel** (`nt36672a_shenchao`). Other panel variants (Tianma, BOE) have not been tested yet and may require different kernel panel drivers/modules.

---

## Status at a Glance

| Property | Details |
| --- | --- |
| **Default Install** | **Phosh desktop** — graphical session on `tty1`, SSH over USB RNDIS & Wi-Fi |
| **GUI** | Phosh is the default UI; `getty@tty2` remains as a text-console fallback |
| **Kernel** | `7.2.3-sdm660` from [`sdm660-mainline/linux`](https://github.com/sdm660-mainline/linux) |
| **Root Filesystem** | Arch Linux ARM (`aarch64`), `ext4` |
| **Bootloader** | Unlocked bootloader required |

---

## Feature Status

| Feature | Status | Notes |
| --- | --- | --- |
| **Boot / Reboot** | Working | Stable system boot |
| **Wi-Fi** | Working | WCN3990 / `ath10k` (2.4 GHz & 5 GHz) |
| **Display & Touchscreen** | Working | — |
| **GPU (Adreno 512, a5xx)** | Partial | 7.2.3 includes the upstream a5xx fixes |
| **Charging & Battery** | Working | Standard charging and battery reporting work |
| **Offline Charging** | Broken | System does not boot into offline charging mode |
| **Microphone, Speaker, Earpiece** | Working | UCM2 profile included; MAX98937 speaker amp driver |
| **Modem & SIM Detection** | Working | SIM **must** be placed in Slot 1 |
| **LTE Registration** | Working | Network registration succeeds |
| **SMS** | Working | Via ModemManager / `mmcli` |
| **Cellular Data** | Broken | Kernel lacks SDM660 IPA driver (no data port) |
| **Phone Calls** | Partial | Call setup works; in-call audio is unsupported (no `q6voice` DSP driver) |
| **Package Management** | Working | `pacman` and package updates work properly |
| **Compressed swap (zram)** | Working | `/dev/zram0`, half of RAM, `zstd`, priority 100 |
| **PC internet over USB** | Working | `scripts/nat.sh` (NAT on the PC side) |
| **On-device console** | Working | 16×32 font on `getty@tty2` (Ctrl+Alt+F2) |
| **Bluetooth** | Broken | — |
| **Vibration** | Broken | — |
| **Flashlight / Torch** | Broken | — |
| **Cameras** | Broken | — |
| **Sensors** | Broken | — |
| **Video Decoding** | Untested | Hardware acceleration untested |
| **GPS** | Broken | — |
| **Suspend / Deep Sleep** | Untested | — |
| **Fingerprint Sensor** | Broken | — |
| **Phosh / GUI Session** | Working | Default UI; `GSK_RENDERER=cairo` and `FD_MESA_DEBUG=noubwc` work around Adreno 512 GTK4 glyph and UBWC corruption bugs |

For detailed version history and logs, see [`docs/STATUS.md`](docs/STATUS.md).

---

## Quick Start

1. **Unlock the Bootloader**: Mandatory step. Wipes all user data. See [`docs/INSTALL.md#1-unlock-the-bootloader`](docs/INSTALL.md#1-unlock-the-bootloader).
2. **Download Release Assets**: Grab the boot image, initramfs, rootfs tarball, and kernel. Verify all SHA-256 checksums.
3. **Build RootFS Image** (on PC; assets in `~/lavender-assets`, repo cloned to `~/arch-lavender`):

```bash
sudo ./rootfs/build-rootfs.sh ~/lavender-assets/rootfs-arch.tar.zst rootfs.img

```

4. **Flash via Fastboot**:

```bash
./scripts/flash.sh rootfs.img.sparse ~/lavender-assets/arch-lavender-boot.img

```

5. **Boot & Log In**:

The phone boots straight into Phosh. Connect the USB cable to get a shell over
SSH (both `root` and `alarm` use the password `arch`):

```bash
ssh root@172.16.42.1     # Default password: arch
ssh alarm@172.16.42.1    # Desktop user, same password
```

If the PC has internet but WiFi is not configured yet, share it over the same
USB cable:

```bash
sudo ./scripts/nat.sh     # then follow the printed phone-side commands

```

6. **Expand Root Filesystem**:

```bash
resize2fs /dev/disk/by-partlabel/userdata

```

7. **Run Post-Install Health Check**:

```bash
sh scripts/verify.sh

```

Complete walkthroughs for Wi-Fi and modem setup are located in [`docs/INSTALL.md`](docs/INSTALL.md).

> **Important:** the released tarball was repacked by an unprivileged user, so
> every file in it is owned by `1000:1000`. `build-rootfs.sh` runs
> `chown -R 0:0` and restores the setuid bits on `mount`, `su`, `sudo`,
> `passwd`, … . Skipping that step silently breaks the USB gadget and `sshd`.
> See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#no-usb-network).

## Graphical session and console fallback

The default install boots to `graphical.target` and starts Phosh on `tty1`
(phoc + squeekboard, user `alarm`). SSH over USB and WiFi remains enabled.

GTK4's NGL renderer loses glyphs at random on the Adreno 512, so the image
exports `GSK_RENDERER=cairo`. Mesa's UBWC compression also corrupts buffers
shared with Firefox/WebRender, so the image exports `FD_MESA_DEBUG=noubwc` as
well; without it pages show magenta blocks or stay blank. Both are the same
workarounds postmarketOS uses on Adreno 5xx devices. If a program still renders
badly, check that the variables reached its environment:

```sh
tr '\0' '\n' < /proc/$(pgrep -n phosh)/environ | grep -E 'GSK_RENDERER|FD_MESA_DEBUG'
```

`getty@tty2` stays enabled with a readable 16×32 console font
(`latarcyrheb-sun32`), so Ctrl+Alt+F2 always gives a text console if the
session misbehaves. `tty1` is reserved for Phosh.

---

## Repository Layout

```
.
├── README.md
├── docs/
│   ├── INSTALL.md           Full installation walkthrough
│   ├── HARDWARE.md          Hardware specs, partition layout, boot.img structure
│   ├── STATUS.md            Tested kernel versions & detailed feature matrix
│   ├── TROUBLESHOOTING.md   Boot loops, fsck, modem, Wi-Fi, and USB debugging
│   └── BUILD-KERNEL.md      Local and CI kernel build instructions
├── kernel/
│   ├── build.sh             Alpine-based kernel build script
│   ├── config/              pmOS-derived SDM660 kernel configuration
│   ├── patches/             Legacy patches 0001–0006 (already in 7.2.3)
│   ├── mkboot.py            Self-contained Android boot.img packer
│   └── make-bootimg.sh      Wrapper script for mkboot.py
├── initramfs/
│   ├── init                 Main init script executed on boot
│   ├── update-modules.sh    Utility to update kernel modules inside initramfs
│   └── arch-initramfs-fsck.gz Pre-built initramfs (e2fsck + firmware + modules)
├── rootfs/
│   ├── build-rootfs.sh      Converts rootfs tarball -> ext4 -> sparse image
│   └── overlay/             /etc/fstab, shadow, environment, sshd, USB networking
├── userspace/
│   ├── base/                Modem/DIAG units, USB gadget, zram, helpers
│   └── gui/                 Phosh systemd unit (cairo renderer workaround)
├── scripts/
│   ├── capture-rootfs.sh    Sanitized rootfs capture (run on the phone)
│   ├── flash.sh             Fastboot helper script for userdata and boot partitions
│   ├── nat.sh               Share the PC's internet with the phone over USB
│   └── verify.sh            On-device health check script
└── .github/
    ├── actions/build-kernel/ Shared CI kernel build action
    └── workflows/           GitHub Actions workflows (kernel.yml, release.yml)

```

---

## Releases & Assets

Large pre-built binary assets are hosted on the GitHub Releases page:

| Asset | Description |
| --- | --- |
| `arch-lavender-boot.img` | Compiled boot image (Kernel + DTB + initramfs) |
| `arch-initramfs-fsck.gz` | Boot initramfs bundled with `e2fsck` and essential hardware firmware |
| `rootfs-arch.tar.zst` | Sanitized base Arch Linux ARM root filesystem |
| `linux-7.2.3-sdm660.zip` | Kernel binaries, Device Tree Blob (DTB), System.map, and modules |
| `sha256sums.txt` | Cryptographic checksums for verifying asset integrity |

> **Note:** The rootfs image is thoroughly sanitized prior to release (SSH keys, saved Wi-Fi credentials, build artifacts, and sensitive `/etc/shadow` entries are removed). Default root access is set via `rootfs/overlay/`.

---

## Kernel & Patches

This project uses the upstream `sdm660-mainline/linux` **7.2.3** kernel
(commit `e9b7cc51f7944f3be7ac69dcf5caabc2429510dc`). That tree already contains
the Adreno a5xx and `ath10k` stability fixes, so `kernel/build.sh` does **not**
apply the patches by default. `kernel/patches/` keeps the original six patches
for older tags; build with `APPLY_PATCHES=1` only when using such a tree.

To build the kernel locally or set up CI workflows, see [`docs/BUILD-KERNEL.md`](docs/BUILD-KERNEL.md).

---

## Credits

* **Mainline SDM660 Kernel:** [`sdm660-mainline/linux`](https://github.com/sdm660-mainline/linux)
* **Kernel Config & Packaging:** postmarketOS maintainers ([`device/testing/linux-postmarketos-qcom-sdm660`](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/tree/main/device/testing/linux-postmarketos-qcom-sdm660))
* **GPU Patches:** Fabricio Akio & Dmitry Baryshkov (FROMLIST)
* **Wi-Fi Patches:** Fabricio Akio (linux-wireless)
* **Qualcomm Userspace Daemons:** [`linux-msm`](https://github.com/linux-msm) (`qrtr`, `tqftpserv`, `rmtfs`, `pd-mapper`, `diag`)

---

## License

Distributed under the [GPL-2.0 License](LICENSE). Upstream kernel patches retain their respective author copyrights and licenses.
