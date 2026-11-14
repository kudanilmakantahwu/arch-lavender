# Hardware and boot layout

## Device

| | |
| --- | --- |
| Model | Xiaomi Redmi Note 7 |
| Codename | `lavender` |
| Device tree | `sdm660-xiaomi-lavender-shenchao` (`xiaomi,lavender-shenchao`, `qcom,sdm660`) |
| SoC | Qualcomm Snapdragon 660 (SDM660) |
| CPU | 8 cores: 4× Kryo 260 Gold (Cortex-A73 class) + 4× Kryo 260 Silver (Cortex-A53 class) |
| GPU | Adreno 512 (a5xx, `msm` driver) |
| RAM | 4 GB or 6 GB (tested unit reports 5.5 GiB usable) |
| Storage | 64 GB or 128 GB eMMC (`/dev/mmcblk1`) |
| Display | 6.3" 1080×2340 IPS, Novatek NT36672A panel + Novatek NVT touch |
| WiFi / Bluetooth | Qualcomm WCN3990, `ath10k_snoc` |
| Modem | integrated SDM660 modem, QRTR + QMI |
| Fingerprint | FPC (not tested) |

The running system identifies itself as:

```
$ cat /proc/device-tree/model
Xiaomi Redmi Note 7 (Shenchao)

$ uname -a
Linux lave-arch 7.2.3-sdm660 #1 SMP PREEMPT ... aarch64 GNU/Linux
```

## Audio

| Path | Hardware | Driver |
| --- | --- | --- |
| Main speaker | MAX98937 smart amplifier on `blsp_i2c6` (`0x3a`), reset TLMM GPIO 77, supplied by PM660L L6B (1.8 V) | `snd-soc-max98937` (local patch) |
| Earpiece | PM660L (PM8916-compatible) analog codec | `snd-soc-msm8916-analog` |
| Internal microphone | PM660L analog codec, ADC1 | `snd-soc-msm8916-analog` |
| Speaker data | Primary MI2S (`gpio12`–`gpio15`) → MAX98937 | `q6afe` / `q6routing` |
| Mic data | PM660L → LPI MI2S TX3 | `q6afe` / `q6routing` |

The amplifier is a MAX98937, not the MAX98927 that earlier device trees
claimed.  Both parts share the bit layouts but not the register map, and the
MAX98937 additionally has a `GLOBAL_EN` register at `0x0500` that must be set
for the amplifier to leave global shutdown.  The UCM2 profile that routes
PipeWire to the speaker and microphone lives in `userspace/audio/ucm2`.

## Partition layout

The GPT is the stock Xiaomi layout. Linux only uses two of these partitions:

| Partition | Size | Contents |
| --- | --- | --- |
| `mmcblk1p60` (`boot`) | 64 MiB | Android boot image (kernel + appended DTB + initramfs) |
| `mmcblk1p66` (`userdata`) | ~50.9 GiB | ext4 root filesystem, label `pmOS_root` |

Other partitions that appear in `lsblk` (`modem`, `dsp`, `persist`, `dtbo`,
`vbmeta`, `system`, `vendor`, `cust`, …) are left untouched. Do not flash
them.

The `userdata` partition is much larger than the 8 GiB image that is flashed
to it; the filesystem is grown online after the first boot:

```sh
resize2fs /dev/disk/by-partlabel/userdata
```

## Boot image

The bootloader expects a **legacy Android boot image** (header version 0) with
the device tree concatenated after `Image.gz` (the `Image.gz-dtb` convention).
The bootloader finds the FDT by scanning for its magic, so this is a packaging
convention rather than a kernel option.
The values below were read back from a boot image that boots on the device.

### Header

| Field | Value |
| --- | --- |
| magic | `ANDROID!` |
| `kernel_addr` | `0x00008000` |
| `ramdisk_addr` | `0x01000000` |
| `second_addr` | `0x00f00000` |
| `tags_addr` | `0x00000100` |
| `page_size` | `4096` |
| `header_version` | `0` |
| `cmdline` | `console=tty0 loglevel=7 rootwait rw` |

### Layout

```
offset 0        header (4096 bytes)
offset 4096     Image.gz + sdm660-xiaomi-lavender-shenchao.dtb
offset  ...     initramfs (gzip-compressed newc cpio)
```

`kernel/mkboot.py` builds this from scratch; `kernel/make-bootimg.sh` is a
thin wrapper. The proven boot image is also shipped as
`arch-lavender-boot.img`.

### Command line

The bootloader appends its own stock Android command line (`androidboot.*`,
`mdss_mdp.panel=...`, and a broken `_oot=...`). The initramfs does **not**
trust `root=`; it finds the root filesystem itself by UUID and then by the
`pmOS_root` label. This is deliberate: the bootloader overwrites parts of the
command line.

## Root filesystem

| | |
| --- | --- |
| Type | ext4 |
| Label | `pmOS_root` |
| Original UUID | `746b0120-939b-4cc9-901b-e1210127811b` |
| Mount | `LABEL=pmOS_root / ext4 defaults,noatime 0 1` |

The initramfs looks for the UUID first, then the label `pmOS_root`, then the
legacy label `archroot`. This means a freshly built image works even if its
UUID differs, as long as the label is correct.

## Initramfs

The initramfs is a pmOS-style busybox image. It bundles:

- `busybox`, `busybox-extras`, `blkid`, `e2fsck`, `resize2fs`, `kmod`,
  `switch_root`;
- the full `7.2.3-sdm660` module tree;
- the firmware needed before `/usr` is mounted:
  - `ath10k/WCN3990/hw1.0/{firmware-5.bin,board-2.bin}`,
  - `qcom/a530_{pm4,pfp}.fw`, `qcom/a530v3_gpmu.fw2`,
  - `postmarketos/a512_zap.mbn`.

It runs `e2fsck -p` on the `userdata` partition before mounting it. If preen
fails it runs a full `e2fsck -f -y`. This is what makes the install survive
an unclean shutdown.

The `init` script is in [`../initramfs/init`](../initramfs/init); the shipped
binary image is `arch-initramfs-fsck.gz`.