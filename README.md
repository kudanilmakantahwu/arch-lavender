# Arch Linux ARM on the Redmi Note 7 (`lavender`)

A step-by-step, actually-tested guide to running Arch Linux ARM on the Xiaomi Redmi Note 7 with a mainline Qualcomm SDM660 kernel.

> **Warning:** **This is not an officially supported distribution.** Following this guide will wipe Android completely. You can brick your phone if you skip steps. Read [`docs/INSTALL.md`](docs/INSTALL.md) thoroughly before starting.
> ⚠️ **Display Panel Note:** This build and driver stack have been explicitly tested **only on the Shenchao display panel** (`nt36672a_shenchao`). Other panel variants (Tianma, BOE) have not been tested yet and may require different kernel panel drivers/modules.

---

## Status at a Glance

| Property | Details |
| --- | --- |
| **Default Install** | **Headless** — console on `tty1`, SSH over USB RNDIS & Wi-Fi |
| **GUI** | Experimental, opt-in. Phosh runs but remains buggy |
| **Kernel** | `7.0.14-sdm660` from [`sdm660-mainline/linux`](https://github.com/sdm660-mainline/linux) |
| **Root Filesystem** | Arch Linux ARM (`aarch64`), `ext4` |
| **Bootloader** | Unlocked bootloader required |

---

## Feature Status

| Feature | Status | Notes |
| --- | --- | --- |
| **Boot / Reboot** | Working | Stable system boot |
| **Wi-Fi** | Working | WCN3990 / `ath10k` (2.4 GHz & 5 GHz) |
| **Display & Touchscreen** | Working | — |
| **GPU (Adreno 512, a5xx)** | Partial | Works with patches in `kernel/patches/` |
| **Charging & Battery** | Working | Standard charging and battery reporting work |
| **Offline Charging** | Broken | System does not boot into offline charging mode |
| **Audio - Earpiece** | Working | Can be used as phone speaker |
| **Audio - Microphone** | Working | Works out of the box |
| **Audio - Speaker** | Broken | Main speaker is currently non-functional |
| **Modem & SIM Detection** | Working | SIM **must** be placed in Slot 1 |
| **LTE Registration** | Working | Network registration succeeds |
| **SMS** | Working | Via ModemManager / `mmcli` |
| **Cellular Data** | Broken | Kernel lacks SDM660 IPA driver (no data port) |
| **Phone Calls** | Partial | Call setup works; **audio routing is untested** |
| **Package Management** | Working | `pacman` and package updates work properly |
| **Bluetooth** | Broken | — |
| **Vibration** | Broken | — |
| **Flashlight / Torch** | Broken | — |
| **Cameras** | Untested | — |
| **Sensors** | Untested | — |
| **Video Decoding** | Untested | Hardware acceleration untested |
| **GPS** | Untested | — |
| **Suspend / Deep Sleep** | Untested | — |
| **Fingerprint Sensor** | Untested | — |
| **Phosh / GUI Session** | Experimental | Opt-in; see [`docs/GUI-EXPERIMENTAL.md`](docs/GUI-EXPERIMENTAL.md) |

For detailed version history and logs, see [`docs/STATUS.md`](docs/STATUS.md).

---

## Quick Start

1. **Unlock the Bootloader**: Mandatory step. Wipes all user data. See [`docs/INSTALL.md#1-unlock-the-bootloader`](docs/INSTALL.md#1-unlock-the-bootloader).
2. **Download Release Assets**: Grab the boot image, initramfs, rootfs tarball, and kernel. Verify all SHA-256 checksums.
3. **Build RootFS Image** (on PC; assets in `~/lavender-assets`, repo cloned to `~/arch-lavender`):

```bash
sudo ./rootfs/build-rootfs.sh ~/lavender-assets/rootfs-arch.tar.zst rootfs.img
# Optional: Add --with-gui for the experimental Phosh desktop

```

4. **Flash via Fastboot**:

```bash
./scripts/flash.sh rootfs.img.sparse ~/lavender-assets/arch-lavender-boot.img

```

5. **Boot & Log In**:
Connect USB cable and log in via SSH:

```bash
ssh root@172.16.42.1     # Default password: arch

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
│   ├── BUILD-KERNEL.md     Local and CI kernel build instructions
│   └── GUI-EXPERIMENTAL.md  Opt-in Phosh desktop guide
├── kernel/
│   ├── build.sh             Alpine-based kernel build script
│   ├── config/              pmOS-derived SDM660 kernel configuration
│   ├── patches/             Patches 0001–0006 (GPU & Wi-Fi stability fixes)
│   ├── mkboot.py            Self-contained Android boot.img packer
│   └── make-bootimg.sh      Wrapper script for mkboot.py
├── initramfs/
│   ├── init                 Main init script executed on boot
│   ├── update-modules.sh    Utility to update kernel modules inside initramfs
│   └── arch-initramfs-fsck.gz Pre-built initramfs (e2fsck + firmware + modules)
├── rootfs/
│   ├── build-rootfs.sh      Converts rootfs tarball -> ext4 -> sparse image
│   └── overlay/             Pre-configured configuration files (/etc/fstab, shadow, etc.)
├── userspace/
│   ├── base/                Modem, DIAG services, and helper tools
│   └── gui-experimental/    Phosh systemd units & wlroots patches
├── scripts/
│   ├── capture-rootfs.sh    Sanitized rootfs capture (run on the phone)
│   ├── flash.sh             Fastboot helper script for userdata and boot partitions
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
| `linux-7.0.14-sdm660.zip` | Kernel binaries, Device Tree Blob (DTB), System.map, and modules |
| `sha256sums.txt` | Cryptographic checksums for verifying asset integrity |

> **Note:** The rootfs image is thoroughly sanitized prior to release (SSH keys, saved Wi-Fi credentials, build artifacts, and sensitive `/etc/shadow` entries are removed). Default root access is set via `rootfs/overlay/`.

---

## Kernel & Patches

This project uses the upstream `v7.0.14-sdm660` kernel with six critical custom patches:

* **`0001`–`0005` (Adreno GPU Fixes):** Fixes crashdump register access on Adreno 512. Without `0002`, GPU hangs trigger unrecoverable kernel panics.
* **`0006` (Wi-Fi Fix):** Prevents WCN3990 firmware crashes during AP disassociation, avoiding Wi-Fi driver deadlocks.

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
