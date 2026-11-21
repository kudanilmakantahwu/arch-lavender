# Fingerprint: Qualcomm QSEE TrustZone transport

This directory records a **feasibility result** for lavender's fingerprint
sensor. It is **not** a working fingerprint reader yet: it proves that mainline
Linux on lavender can reach Qualcomm's TrustZone (QSEE) and load the device's
own signed fingerprint Trusted Application (TA). The remaining work (a userspace
TA-protocol plugin + fprintd) is described at the end.

Nothing here is installed into the rootfs by default, and nothing changes the
kernel image. The transport is an out-of-tree module that is loaded at runtime.

## Why fingerprint is hard on this device

The FPC sensor is **not** a normal SPI/I²C device. Its bus is owned by
TrustZone, and all imaging, feature extraction, template storage and matching
happen inside a Qualcomm-signed TA (`fpctzappfingerprint`) running in QSEE.
Normal world (Linux) cannot read the sensor directly; it can only

1. **load** the signed TA into QSEE, and
2. **relay** commands to it and answer its storage callbacks.

Everything else — including the sensor protocol, which is proprietary and
undocumented — is inside the TA. Loading a TA requires the QSEECOM transport,
which upstream mainline `qcom_scm` only exposes to an allowlist of "tested"
machines. lavender's machine compatible is not on that list, so the in-kernel
`qcom_qseecom` driver prints `qseecom: untested machine, skipping`.

The out-of-tree driver used here sidesteps that gate: it resolves the kernel's
own `__scm_smc_call`/`qcom_scm_lock` symbols through a kprobe and issues the
QSEE SMCCC calls itself, so no kernel patch and no allowlist entry are needed.

## Result on lavender (2026-11-21)

Status: **transport works, the vendor TA loads into TrustZone.**

* Kernel prerequisites are already present in `7.2.3-sdm660`:
  `CONFIG_QCOM_SCM=y`, `CONFIG_QCOM_TZMEM=y` (mode **Generic**), and the
  `qcom_tzmem_*` symbols are exported. `CONFIG_MODULE_SIG_FORCE` is **not** set,
  so an unsigned module loads (it taints the kernel, which is expected).
* The module builds against the exact kernel toolchain (Clang 23.1.5, the
  `kbuild-edge:7.2.3` image used by `kernel/build.sh`) and carries the matching
  `vermagic: 7.2.3-sdm660`. Clang 23 needs the one-line fix in `patches/`.
* After `insmod`, `/dev/qseecom_mobile` appears and the driver reports:
  `SCM synchronization active: smc_call=__scm_smc_call scm_lock=… scm_dev=firmware:scm`.
* Loading the FPC TA succeeds:

  ```
  qseecom_mobile: loading 'fpctzappfingerprint': mdt_len=7004 total_len=2576481 segments=8
  qseecom_mobile: successfully loaded 'fpctzappfingerprint' with id 131074
  ```

  i.e. TrustZone verified the Xiaomi signature and started the TA. The driver
  auto-unloads the app when the last fd closes.

## Credits and provenance

All third-party work this directory builds on, with authors and licences:

| Project | Author | Licence | What we use |
| --- | --- | --- | --- |
| [`nyl/linux-qseecom-mobile`](https://github.com/nyl/linux-qseecom-mobile) | Nitescu Ion Laurentiu `<contact@nyl.ro>` | `GPL-2.0-or-later` (per the source-file SPDX headers; the repo has no top-level LICENSE file) | The whole QSEE transport driver + the `tz-qsee-fingerprintd` daemon/plugin architecture. Cloned at commit `fa3b070`; the only local change is the Clang-23 cast fix in `patches/`. |
| [`yarons/beryllium_fpc`](https://github.com/yarons/beryllium_fpc) | yarons (GitHub) | `GPL-2.0` | QSEE fingerprint reverse-engineering notes and an early FPC client (reference only, not vendored). |
| [`brysonwf/linuxduobench`](https://github.com/brysonwf/linuxduobench) | brysonwf (GitHub) | `GPL-2.0` | Prior art for driving an FPC QSEE TA (`fpctzrel`) from mainline (reference only, not vendored). |

The FPC TA blobs (`fpctzappfingerprint.*`) are Xiaomi-signed vendor firmware and
are deliberately **not** committed; `extract-fpc-ta.sh` pulls them from your own
`vendor.raw.img`.

## What is in here

| File | Purpose |
| --- | --- |
| `build-module.sh` | Clone the upstream driver at the pinned commit, apply the local patch, and build `qcom_qseecom_mobile.ko` with the Clang 23.1.5 image. |
| `patches/0001-fix-clang23-incompatible-pointer-types.patch` | The only source change needed: explicit casts for the driver's layout-identical mirror structs (kCFI hashes the function-pointer type, so this is safe). |
| `qsee_probe.c` | Tiny `LOAD_APP` probe for `/dev/qseecom_mobile`. |
| `extract-fpc-ta.sh` | Pull `fpctzappfingerprint.*` out of a stock `vendor.raw.img` with `7z` (no root, no loop mount). |
| `prebuilt/qcom_qseecom_mobile.ko` | The built module (with `SHA256SUMS`), for convenience. |

## Build

```sh
# kernel/src must be built first (kernel/build.sh); the module needs Module.symvers
./build-module.sh
# -> prebuilt/qcom_qseecom_mobile.ko  (+ sha256)
```

## Load and verify on the device

```sh
# 1. Extract the FPC TA from your stock vendor image and copy it to the device
./extract-fpc-ta.sh /path/to/vendor.raw.img ./fpc-ta
scp ./fpc-ta/fpctzappfingerprint.* root@<device>:/lib/firmware/

# 2. Build the probe, copy the module + probe to the device
aarch64-linux-gnu-gcc -static -O2 -o qsee_probe qsee_probe.c
scp prebuilt/qcom_qseecom_mobile.ko qsee_probe root@<device>:/tmp/

# 3. On the device (root):
insmod /tmp/qcom_qseecom_mobile.ko
dmesg | grep qseecom_mobile          # expect "initialized /dev/qseecom_mobile"
chmod +x /tmp/qsee_probe
/tmp/qsee_probe fpctzappfingerprint  # expect app_id=131074 and LOAD success in dmesg

# Cleanup:
rm -f /lib/firmware/fpctzappfingerprint.*
rmmod qcom_qseecom_mobile
```

## What is still missing (the real work)

The upstream repo ships a userspace daemon (`tz-qsee-fingerprintd`, a
`net.reactivated.Fprint` D-Bus service) and a **per-device plugin** vtable, but
it only contains a Chipone/FP4 plugin. A **new FPC plugin** must be written that
speaks the FPC TA protocol, plus the sensor's reset/IRQ GPIO handling. Prior art
to reuse instead of starting from scratch:

* [`nyl/linux-qseecom-mobile`](https://github.com/nyl/linux-qseecom-mobile) — the
  transport + daemon + plugin architecture itself.
* [`yarons/beryllium_fpc`](https://github.com/yarons/beryllium_fpc) — FPC/GDIX
  QSEE reverse-engineering notes and an early FPC client.
* [`brysonwf/linuxduobench`](https://github.com/brysonwf/linuxduobench) — an FPC
  QSEE TA (`fpctzrel`) driven from mainline: TA stayed resident, finger-detect and
  frame capture worked; enrollment commit was blocked on a Gatekeeper token.

Known remaining blockers:

* **Enrollment commit needs a Gatekeeper/HAT token.** The TA wants a hardware-auth
  token signed by Gatekeeper before it will store a template (the prior art hit
  the same wall). That means also loading/provisioning the `keymaster64` TA
  (which is *not* in the `vendor` image; look in the other firmware partitions),
  and possibly rpmb.
* **The FPC TA protocol is undocumented** and must be recovered from the Android
  vendor HAL (`vendor.qti.hardware.fingerprint@1.0.so` in the `vendor` image).
  The prior art found the general shape (`u32 group, u32 cmd, i32 status, …`;
  build-info is `group 0x0c, cmd 0x01`), but the full command map is per-TA.
* **TrustZone watchdog risk.** Malformed SMC/protocol traffic can trip the EL3
  watchdog and reboot (or, worst case, hang) the device. Test on a RAM
  (`fastboot boot`) boot, or accept a reboot.

## Notes

* The driver's Kconfig default is the **Generic** `qcom_tzmem` mode, not
  SHMBridge, and it worked here for loading the TA. Some newer firmware requires
  SHMBridge; lavender did not.
* The venus/DRI and audio work is unrelated and untouched by this directory.
