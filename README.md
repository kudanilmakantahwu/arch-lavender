# Arch Linux ARM on the Redmi Note 7 (`lavender`)

A step-by-step, actually-tested guide to running Arch Linux ARM on the Xiaomi Redmi Note 7 with a mainline Qualcomm SDM660 kernel.

> **Warning:** **This is not an officially supported distribution.** Following this guide will wipe Android completely. You can brick your phone if you skip steps. Read [`docs/INSTALL.md`](docs/INSTALL.md) thoroughly before starting.
> ⚠️ **Display Panel Note:** This build and driver stack have been explicitly tested **only on the Shenchao display panel** (`nt36672a_shenchao`). Other panel variants (Tianma, BOE) have not been tested yet and may require different kernel panel drivers/modules.

---

## Status at a Glance

| Property | Details |
| --- | --- |
| **Default Install** | **Phosh desktop** — graphical session on `tty1`, SSH over USB RNDIS & Wi-Fi |
| **GUI** | Phosh is the default UI; recover over SSH (USB/Wi-Fi). `getty@tty2` needs a USB/OTG keyboard |
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
| **GPU (Adreno 512, a5xx)** | Partial | Kernel 7.2.3 carries the upstream a5xx fixes; Mesa's a5xx 2D-blit glyph bug is fixed in userspace by the patched `libgallium` in `userspace/mesa/` |
| **Charging & Battery** | Working | Standard charging and battery reporting work |
| **Offline Charging** | Broken | System does not boot into offline charging mode |
| **Microphone, Speaker, Earpiece** | Partial | Speaker and earpiece work (UCM2 HiFi profile, MAX98937 amp; kernel pins the MultiMedia1 front end to `S16_LE`, so no userspace rule is needed on the current kernel); microphone is a separate UCM verb because its capture probe currently fails on 7.2.3. Kernel needs `CONFIG_SND_SOC_SM8250=m` |
| **Modem & SIM Detection** | Working | SIM **must** be placed in Slot 1 |
| **LTE Registration** | Working | Network registration succeeds |
| **SMS** | Working | Via ModemManager / `mmcli` |
| **Cellular Data** | Broken | Kernel lacks SDM660 IPA driver (no data port) |
| **Phone Calls** | Partial | Call setup works; in-call audio is unsupported (no `q6voice` DSP driver) |
| **Package Management** | Working | `pacman` and package updates work properly |
| **Compressed swap (zram)** | Working | `/dev/zram0`, half of RAM, `zstd`, priority 100 |
| **PC internet over USB** | Working | `scripts/nat.sh` (NAT on the PC side) |
| **On-device console** | Working | 16×32 font on `getty@tty2`; needs a USB/OTG keyboard |
| **Bluetooth** | Broken | — |
| **Vibration** | Broken | — |
| **Flashlight / Torch** | Broken | — |
| **Cameras** | Broken | — |
| **Sensors** | Broken | — |
| **Video Decoding** | Partial | VP8/VP9 software decode works; H.264 via `qcom-venus` is broken (see [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md)) |
| **GPS** | Broken | — |
| **Suspend / Deep Sleep** | Broken | s2idle enters and resumes, but RTC wake is unreliable and resume reloads `ath10k`; automatic suspend is disabled by default (see `docs/STATUS.md` and FINDINGS section D) |
| **Fingerprint Sensor** | Broken | — |
| **Waydroid (optional)** | Working | Not enabled by default; occasional font glitches, otherwise stable |
| **Phosh / GUI Session** | Working | Default UI on `phoc` (FD512, GLES 3.1); GTK4 apps use `GSK_RENDERER=gl` with the patched a5xx `libgallium`, and the session exports `FD_MESA_DEBUG=noubwc`. Phosh 0.57 itself is a GTK3 shell, so `GSK_RENDERER` governs its GTK4 apps, not the shell; see [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) |
| **Plasma Mobile (optional)** | Experimental | 6.8.3 starts on `tty1` (KWin + plasmashell) with non-fatal QML warnings; see [`docs/DESKTOP.md`](docs/DESKTOP.md) |

Phosh is the default session. To run Plasma Mobile, GNOME, Sway, Hyprland or
another DE/WM without losing the device patches, see
[`docs/DESKTOP.md`](docs/DESKTOP.md).

For detailed version history and logs, see [`docs/STATUS.md`](docs/STATUS.md);
for the renderer/memory/governor A/B measurements and the final tuned
defaults, see [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).

On kernel `7.2.3-sdm660` from v1.2 onwards the machine driver pins the
MultiMedia1 front end to `S16_LE` when the device tree sets
`qcom,force-s16-fe`, so no userspace rule is needed on the current kernel. The
image still installs the WirePlumber `S16LE` speaker rule as a fallback for
older kernels; it is harmless with the kernel quirk. Without either, PipeWire
feeds a 24-bit front end to the 16-bit MAX98937 backend and apps play clean
audio about 48 dB too quiet; see
[Speaker is clean but extremely quiet in apps](docs/TROUBLESHOOTING.md#speaker-is-clean-but-extremely-quiet-in-apps).

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
(phoc + stevia on-screen keyboard, user `alarm`). SSH over USB and WiFi remains enabled.

The image sets `GSK_RENDERER=gl`, which is GTK4's GL renderer. Text scrolling in
a GTK4 app reaches ~50 fps against ~23 fps with cairo on the same 4000-line
`GtkTextView`. GTK 4.24 renamed the renderer from `ngl` to `gl`; `ngl` is
ignored with a warning. Phosh 0.57 itself is a GTK3 shell, so the variable
applies to its GTK4 apps (Firefox, GNOME apps), while `phoc` renders the
compositor with GLES directly.

The rootfs also installs the patched a5xx `libgallium` from `userspace/mesa/`.
An ABI-matched prebuilt library is included, and the backport plus
`build-libgallium.sh` are there to rebuild it. Without it, Mesa's 2D blit
silently drops staging texture uploads and GTK/browser text loses glyphs; the
renderer choice alone does not fix that bug. Mesa's UBWC
compression still corrupts buffers shared with Firefox/WebRender, so the image
exports `FD_MESA_DEBUG=noubwc` as well; without it pages show magenta blocks or
stay blank. If a program still renders badly, check that the variables reached
its environment:

```sh
tr '\0' '\n' < /proc/$(pgrep -n phosh)/environ | grep -E 'GSK_RENDERER|FD_MESA_DEBUG'
```

`getty@tty2` stays enabled with a readable 16×32 console font
(`latarcyrheb-sun32`), but the phone has no built-in keyboard. Without a
USB/OTG keyboard, the recovery path is **SSH over USB or Wi-Fi**; keep a
session open before changing the graphical stack. `tty1` is reserved for
Phosh.

---

## Repository Layout

```
.
├── README.md
├── docs/
│   ├── INSTALL.md           Full installation walkthrough
│   ├── DESKTOP.md           Switching DE/WM (Plasma Mobile, GNOME, Sway, ...)
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
│   ├── gui/                 Phosh systemd unit (GL renderer for GTK4 apps)
│   └── mesa/                a5xx 2D-blit fix: prebuilt lib, backport, build script
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
