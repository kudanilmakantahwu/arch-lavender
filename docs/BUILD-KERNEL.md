# Building the kernel

The running kernel is:

```
7.2.3-sdm660
```

built from [`sdm660-mainline/linux`](https://github.com/sdm660-mainline/linux),
branch `qcom-sdm660-7.2.y`, commit
`e9b7cc51f7944f3be7ac69dcf5caabc2429510dc`, with the pmOS SDM660 config.

## Source

| | |
| --- | --- |
| Repository | <https://github.com/sdm660-mainline/linux> |
| Branch | `qcom-sdm660-7.2.y` |
| Commit | `e9b7cc51f7944f3be7ac69dcf5caabc2429510dc` |
| Tarball | `https://github.com/sdm660-mainline/linux/archive/e9b7cc51f7944f3be7ac69dcf5caabc2429510dc.tar.gz` |
| SHA-256 | `73564840ad5c0904aa65fdc9ba05e807c34406337c42da8f3983155f354b333f` |
| Config | `kernel/config/config-postmarketos-qcom-sdm660.aarch64` (from pmaports) |

## Patches

`kernel/patches/` keeps the six fixes that were required on the older 7.0.x
tree:

| Patch | Effect |
| --- | --- |
| `0001-drm-msm-a5xx-add-hangcheck-progress-detection.patch` | detects GPU hangs earlier |
| `0002-drm-msm-a5xx-dont-read-gpmu-registers-without-gpmu.patch` | **critical**: the Adreno 512 has no GPMU; without this a GPU crashdump reads GPMU registers and reboots the phone |
| `0003-drm-msm-a5xx-reset-gpu-on-resume.patch` | resets the GPU on resume |
| `0004-drm-msm-a5xx-hold-cpu-latency-request.patch` | keeps the CPU latency request held |
| `0005-drm-msm-a5xx-write-cp-rb-wptr-under-preempt-lock.patch` | fixes a ringbuffer write race |
| `0006-wifi-ath10k-dont-reset-txbf-on-disassociation.patch` | prevents the WCN3990 firmware crash on disconnect |

These fixes are already upstream in 7.2.3, so `kernel/build.sh` **skips them by
default**. Apply them with `APPLY_PATCHES=1` only when building an older tag:

```sh
docker run --rm -e APPLY_PATCHES=1 ... alpine:edge sh /work/build.sh
```

`0001`–`0005` come from Fabricio Akio and Dmitry Baryshkov (FROMLIST,
Sep–Nov 2026). `0006` is from Fabricio Akio (linux-wireless, Oct 2026).

## Local build

The build runs inside `alpine:edge` so the toolchain matches the one used for
the device. Docker or Podman is required.

From the repository root:

```sh
mkdir -p kernel/out

docker run --rm \
  -v "$PWD/kernel:/work" \
  -w /work \
  alpine:edge sh /work/build.sh
```

`kernel/build.sh`:

1. installs `clang`, `lld`, `llvm`, `bc`, `bison`, `flex`, `dtc`, `kmod`,
   `pahole`, `openssl`, `xz`, `zstd`, and friends;
2. downloads the pinned commit tarball and verifies its SHA-256;
3. applies `patches/*.patch` only when `APPLY_PATCHES=1`;
4. copies the pmOS config and runs `make olddefconfig`;
5. builds `make ARCH=arm64 LLVM=1 all Image.gz modules`;
6. installs modules with `INSTALL_MOD_STRIP=1`;
7. installs DTBs with `dtbs_install`;
8. runs `depmod` and verifies `ath10k_snoc` links against `ath10k_core`
   (an empty `modules.dep` would make WiFi fail at boot);
9. collects the outputs.

Outputs (inside `kernel/out`):

```
vmlinuz                         Image.gz
vmlinuz.efi                     Image (EFI stub)
System.map
dtbs/qcom/sdm660-xiaomi-lavender-shenchao.dtb
modroot/usr/lib/modules/7.2.3-sdm660/
```

The kernel and modules are built in one pass so the kCFI type hashes match.
Do not mix modules from one build with a kernel from another.

## Building the boot image

The boot image needs the kernel, the DTB, and an initramfs:

```sh
python3 kernel/mkboot.py \
  --kernel kernel/out/vmlinuz \
  --dtb kernel/out/dtbs/qcom/sdm660-xiaomi-lavender-shenchao.dtb \
  --ramdisk initramfs/arch-initramfs-fsck.gz \
  --out kernel/out/boot-7.2.3-sdm660.img \
  --cmdline "console=tty0 loglevel=7 rootwait rw"
```

or:

```sh
./kernel/make-bootimg.sh \
  kernel/out/vmlinuz \
  kernel/out/dtbs/qcom/sdm660-xiaomi-lavender-shenchao.dtb \
  initramfs/arch-initramfs-fsck.gz \
  kernel/out/boot-7.2.3-sdm660.img
```

The shipped `initramfs/arch-initramfs-fsck.gz` already contains the
`7.2.3-sdm660` module tree, which is what the kernel needs to bring up the
display before the root filesystem is mounted.

The DTB is appended to `Image.gz`, as the bootloader expects. The header
addresses are the proven ones (see [`HARDWARE.md`](HARDWARE.md#boot-image)).
Do not use the stock Android `mkbootimg` defaults.

## Running the new kernel

Test without writing anything:

```sh
fastboot boot kernel/out/boot-7.2.3-sdm660.img
```

If it boots, flash it:

```sh
fastboot flash boot kernel/out/boot-7.2.3-sdm660.img
fastboot reboot
```

Install the modules into the root filesystem:

```sh
unzip -q kernel/out/linux-7.2.3-sdm660.zip -d /tmp/kernel
rm -rf /usr/lib/modules/7.2.3-sdm660
cp -a /tmp/kernel/modroot/usr/lib/modules/7.2.3-sdm660 /usr/lib/modules/
depmod 7.2.3-sdm660
```

If the kernel version string changes, update the paths accordingly. The
initramfs also contains a copy of the modules; use
`initramfs/update-modules.sh` to refresh it if you rebuild it.

## GitHub Actions

Two workflows build the kernel:

- `.github/workflows/kernel.yml` — runs on pushes to `kernel/**` and on manual
  dispatch. It builds the kernel and boot image, uploads them as artifacts,
  and, if you pass a release `tag`, attaches them to that release as `-ci`
  assets.
- `.github/workflows/release.yml` — runs on tags matching `v*`. It builds the
  same assets and uploads them as `-ci` files, so they never overwrite the
  proven boot image and kernel zip. Test a `-ci` boot image with
  `fastboot boot`, then promote it by hand.

Both use the composite action `.github/actions/build-kernel`, which runs
`kernel/build.sh` in `alpine:edge` and packages:

```
linux-7.2.3-sdm660.zip
boot-7.2.3-sdm660.img
sha256sums-kernel.txt
```

The release workflow renames them to `linux-7.2.3-sdm660-ci.zip` and
`boot-7.2.3-sdm660-ci.img` before uploading.

The rootfs tarball is **not** built by CI. It cannot be reproduced without a
device (it is a sanitized capture of a working install). It is uploaded to the
release manually.

### Publishing a kernel build

From the Actions tab, run **kernel** with:

```
tag: v1.0
```

The workflow creates the release if it does not exist and uploads the three
assets as `-ci` files (`linux-7.2.3-sdm660-ci.zip` and
`boot-7.2.3-sdm660-ci.img`) with `--clobber`, so they never overwrite the
proven boot image / kernel zip. Test a `-ci` boot image on the phone first;
a release is just a tag, it does not make an untested kernel safe.

## Notes

- **Do not** enable `CONFIG_MODULE_SIG_FORCE` or strip module signatures
  differently between kernel and modules. The shipped config and build keep
  them consistent.
- The bootloader overwrites parts of the command line. The initramfs finds the
  root filesystem itself; do not rely on `root=`.
- The panel is selected with `mdss_mdp.panel=...` in the command line appended
  by the bootloader. The DTB and panel driver must match; the tested
  combination is `nt36672a_shenchao_fhdplus_video`.
- A kernel panic caused by the a5xx GPU on an older tree is almost always a
  missing or misapplied `0002` patch. 7.2.3 has it upstream; check
  `dmesg | grep -i a5xx` if you are on a different version.
