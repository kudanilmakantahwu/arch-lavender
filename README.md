# Arch Linux ARM on the Redmi Note 7 (`lavender`)

A step-by-step, actually-tested guide to running Arch Linux ARM on the Xiaomi
Redmi Note 7 with a mainline Qualcomm SDM660 kernel.

> **This is not a supported distribution.** You will erase Android and you can
> brick the phone if you skip steps. Read [`docs/INSTALL.md`](docs/INSTALL.md)
> all the way through before you start.

## Status at a glance

| | |
| --- | --- |
| **Default install** | **Headless** — console on `tty1`, SSH over USB/WiFi |
| **GUI** | Experimental, opt-in. Phosh runs but is still buggy. |
| **Kernel** | `7.0.14-sdm660` from [`sdm660-mainline/linux`](https://github.com/sdm660-mainline/linux) |
| **Root filesystem** | Arch Linux ARM aarch64, ext4 |
| **Bootloader** | Unlocked bootloader required |

The headless install is the one that has been replayed end-to-end. The GUI is
shipped as an opt-in extra because it is not reliable enough to be the
default.

## What works

| Feature | State |
| --- | --- |
| Boot / reboot | works |
| Serial console on `tty1` | works |
| SSH over USB RNDIS (`172.16.42.1`) | works |
| SSH over WiFi | works |
| WiFi (WCN3990 / `ath10k`) | works, 2.4 and 5 GHz |
| Display + touchscreen | works |
| GPU (Adreno 512, a5xx) | works with the patches in `kernel/patches/` |
| Modem / SIM detection | works (SIM must be in slot 1) |
| LTE registration | works |
| SMS (ModemManager / `mmcli`) | works |
| Charging / battery reporting | works |
| `pacman` and package installs | works |

## What does not work (or is untested)

| Feature | State |
| --- | --- |
| Cellular **data** | does not work — the kernel has no SDM660 IPA driver, so ModemManager has no data port |
| Phone calls | call setup works; **audio routing is untested** |
| Phosh / GUI | experimental; see [`docs/GUI-EXPERIMENTAL.md`](docs/GUI-EXPERIMENTAL.md) |
| Camera | not tested |
| Bluetooth | not tested |
| GPS | not tested |
| Suspend / deep sleep | not tested |
| Fingerprint sensor | not tested |

See [`docs/STATUS.md`](docs/STATUS.md) for details and tested versions.

## Quick start

1. **Unlock the bootloader.** This is mandatory and wipes the phone. See
   [`docs/INSTALL.md`](docs/INSTALL.md#1-unlock-the-bootloader).
2. **Download the release assets** (boot image, initramfs, rootfs tarball,
   kernel). Verify the checksums.
3. **Build a flashable rootfs image** on your PC:

   ```sh
   sudo ./rootfs/build-rootfs.sh rootfs-arch.tar.zst rootfs.img
   # optional: --with-gui for the experimental Phosh session
   ```

4. **Flash** from fastboot mode:

   ```sh
   ./scripts/flash.sh rootfs.img.sparse arch-lavender-boot.img
   ```

5. **Boot, connect the USB cable, and log in**:

   ```sh
   ssh root@172.16.42.1     # password: arch
   ```

6. **Grow the filesystem** to the full userdata partition:

   ```sh
   resize2fs /dev/disk/by-partlabel/userdata
   ```

7. Run `sh scripts/verify.sh` on the phone.

The full walkthrough, including WiFi and modem setup, is in
[`docs/INSTALL.md`](docs/INSTALL.md).

## Repository layout

```
.
├── README.md
├── docs/
│   ├── INSTALL.md              full install walkthrough
│   ├── HARDWARE.md             device, partitions, boot image layout
│   ├── STATUS.md               what works / tested versions
│   ├── TROUBLESHOOTING.md      boot, fsck, modem, WiFi, USB
│   ├── BUILD-KERNEL.md         local and CI kernel builds
│   └── GUI-EXPERIMENTAL.md     opt-in Phosh session
├── kernel/
│   ├── build.sh                builds the kernel in Alpine
│   ├── config/                 pmOS-derived kernel config
│   ├── patches/                0001–0006 (GPU + WiFi fixes)
│   ├── mkboot.py               self-contained Android boot.img builder
│   └── make-bootimg.sh         wrapper around mkboot.py
├── initramfs/
│   ├── init                    the init script that runs on the phone
│   ├── update-modules.sh       swap modules inside an initramfs
│   └── arch-initramfs-fsck.gz  proven initramfs (e2fsck + firmware + modules)
├── rootfs/
│   ├── build-rootfs.sh         tarball -> ext4 image -> sparse image
│   └── overlay/                sanitized /etc files (fstab, shadow, sshd, ...)
├── userspace/
│   ├── base/                   modem/DIAG services, patches (always installed)
│   └── gui-experimental/       Phosh units + wlroots patch (opt-in)
├── scripts/
│   ├── capture-rootfs.sh       sanitized rootfs capture (run on the phone)
│   ├── flash.sh                fastboot userdata + boot
│   └── verify.sh               post-boot health check
└── .github/
    ├── actions/build-kernel/   shared kernel build
    └── workflows/              kernel.yml, release.yml
```

## Releases and assets

Large files live in the GitHub release, not in git:

| Asset | What it is |
| --- | --- |
| `arch-lavender-boot.img` | proven boot image: kernel + appended DTB + initramfs |
| `arch-initramfs-fsck.gz` | proven initramfs (runs `e2fsck`, bundles firmware) |
| `rootfs-arch.tar.zst` | sanitized Arch Linux ARM root filesystem |
| `linux-7.0.14-sdm660.zip` | kernel, DTB, System.map, modules |
| `sha256sums.txt` | checksums for all of the above |

The rootfs tarball is sanitized. The capture script
([`scripts/capture-rootfs.sh`](scripts/capture-rootfs.sh)) excludes:

- `/etc/shadow`, `/etc/gshadow` (the overlay supplies sanitized versions),
- all SSH host keys and `authorized_keys`,
- `/root` and the user home directories (browser profiles, cookies, chat/SMS
  history, build trees),
- pacman private keys (`secring.gpg`, `private-keys-v1.d`) while keeping the
  public keyring,
- saved WiFi and NetworkManager connections, DHCP leases, `/etc/resolv.conf`,
- `machine-id`, random seeds, logs, caches, crash dumps.

The repo's `rootfs/overlay/` supplies a documented root password instead.

## Kernel

The kernel is the `v7.0.14-sdm660` tag plus six patches:

- `0001`–`0005`: Adreno a5xx GPU fixes. Without `0002` the GPU crashdump path
  reads GPMU registers that the Adreno 512 does not have, and a GPU hang
  reboots the phone.
- `0006`: `ath10k` fix; without it the WCN3990 firmware crashes on
  disassociation and WiFi stays dead until reboot.

The kernel can be rebuilt locally or in GitHub Actions; see
[`docs/BUILD-KERNEL.md`](docs/BUILD-KERNEL.md).

## Credits

- Mainline SDM660 kernel: [`sdm660-mainline/linux`](https://github.com/sdm660-mainline/linux)
- Kernel config and packaging: pmaports
  `device/testing/linux-postmarketos-qcom-sdm660`
- GPU patches: Fabricio Akio and Dmitry Baryshkov (FROMLIST)
- WiFi patch: Fabricio Akio (linux-wireless)
- Qualcomm userspace: [`linux-msm`](https://github.com/linux-msm) (`qrtr`,
  `tqftpserv`, `rmtfs`, `pd-mapper`, `diag`)

## License

GPL-2.0. See [`LICENSE`](LICENSE). Kernel patches retain their upstream
authors and licenses.