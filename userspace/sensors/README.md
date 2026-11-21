# Sensors on the Redmi Note 7 (SDM660)

The phone has three sensors behind the ADSP:

| Sensor | Chip | IIO device |
| --- | --- | --- |
| Accelerometer + gyroscope | InvenSense ICM20607 | `qcom-smgr-accel`, `qcom-smgr-gyro` |
| Magnetometer | Asahi Kasei AK09918 | `qcom-smgr-mag` |
| Ambient light + proximity | Sensortek STK3x3x | `qcom-smgr-prox` (`qcom-smgr-prox-light`) |

## Why sensors did not work

The ADSP sensor stack needs a **sensor registry**, a small binary blob that
`qcom_sns_reg` (`CONFIG_QCOM_SNS_REG`) loads as firmware and hands to the ADSP.
Without it `qcom_sns_reg` fails at probe:

```
qcom_sns_reg ...: Direct firmware load for qcom/sensors/sns.reg failed with error -2
qcom_sns_reg ...: error -ENOENT: qcom_sns_reg probe failed!
```

and the SMGR service never starts, so no IIO device is created.

The registry is normally produced by the Android sensors HAL from
`/vendor/etc/sensors/sensor_def_qcomdev.conf` and stored on the `persist`
partition as `sensors/sns.reg`.  Neither the stock `NON-HLOS.bin` nor the
`firmware-xiaomi-lavender` package ship it -- it is device-specific data that
the factory writes to `persist`, so the release cannot fetch it from a ROM.

## What this port ships

`rootfs/firmware/qcom/sensors/sns.reg` is that blob, extracted from the
`persist` partition of this device (`/dev/disk/by-partlabel/persist`,
`sensors/sns.reg`, 25468 bytes,
SHA-256 `402986feeabfdae1111bd010a9026f7a59dd05ece2748b12f121dacaf9d8f255`).

`rootfs/build-rootfs.sh` installs it as
`/lib/firmware/qcom/sensors/sns.reg`, which is the fallback name
`qcom_sns_reg` requests after the per-device
`qcom/sensors/sns.reg-xiaomi,lavender-shenchao` name.

`userspace/sensors/modules-load.d/sdm660-sensors.conf` is installed as
`/etc/modules-load.d/sdm660-sensors.conf` so the SMGR stack comes up even when
udev does not process the QRTR modalias.

## Booting the stack automatically

Two pieces are installed at boot; nothing has to be done by hand:

* `/etc/modules-load.d/sdm660-sensors.conf` loads `qcom_sns_reg`,
  `qcom_smgr` and the SMGR child drivers (`qcom_smgr_accel`, `_gyro`,
  `_mag`, `_prox`) before udev settles, so the IIO devices always appear even
  if the QRTR `platform:qcom-smgr-*` modalias is missed.
* `/etc/udev/rules.d/90-iio-sensor-proxy-no-ssc.rules` stops
  `iio-sensor-proxy` from loading its libssc backend (see below), so the
  proxy comes up cleanly and picks up the accelerometer.

`iio-sensor-proxy.service` is `static`; it is started by the
`SYSTEMD_WANTS` tag that `80-iio-sensor-proxy.rules` adds to the IIO device.

## What iio-sensor-proxy can and cannot use

`monitor-sensor` is the only supported way to read the sensors and it goes
through `iio-sensor-proxy`.  On this device it reports **orientation**
(live, from the accelerometer buffer):

```
$ monitor-sensor
+++ iio-sensor-proxy appeared
=== Has accelerometer (orientation: portrait, ...)
=== No ambient light sensor
=== No proximity sensor
=== No compass
```

The gyroscope, magnetometer, proximity and ambient-light values are *not*
reported, for reasons that are in the **kernel driver and in
iio-sensor-proxy**, not in the sensor registry:

1. `drivers/iio/common/qcom_smgr/qcom_smgr.c` streams only the sensor's
   `SNS_SMGR_DATA_TYPE_PRIMARY` data type and pushes it into a plain kfifo
   buffer.  For the STK3x3x `0x28` sensor the ADSP reports two data types
   (`0x28,0` proximity and `0x28,1` ambient light), but
   `drivers/iio/proximity/qcom_smgr_prox.c` only exposes the first one, and
   only as a buffer channel (`scan_elements/in_proximity_en`).  There is no
   `in_proximity_raw` and no light/`in_illuminance_*` channel at all.
2. Upstream `iio-sensor-proxy` (tested with 3.9) has a driver for *polled*
   proximity (`in_proximity_raw`) but **none for buffered proximity**, and
   its udev rules only classify polled ALS (`in_illuminance_raw`, ...).  So
   even the buffered proximity channel that does exist is ignored, and the
   missing light channel cannot be matched.
3. `/dev/fastrpc-adsp*` makes the stock rules probe the libssc/SSC backend,
   but this ADSP has no SSC service: `qrtr-lookup` shows the Sensor Manager
   service as QMI `0x0100` (which the in-kernel `sns_smgr` driver uses) and
   there is no `0x0190` (SSC).  `ssccli --sensor ...` fails with
   `SSC QMI Service not found` and `iio-sensor-proxy` crashes in
   `ssc_sensor_light_new_sync()`.  The `90-...rules` file above disables
   that backend.

Making proximity and ambient light show up needs kernel work (expose the
`sns_smgr` secondary data type and an `in_illuminance_*` channel, and a
raw/polled read) plus an iio-sensor-proxy buffer-proximity driver; there is
no upstream patch to cherry-pick for either.  It is left for a follow-up.

The **vibrator** (`spmi_haptics` on `/dev/input/event4`) works with no
configuration at all -- see `docs/STATUS.md`.

## Verifying on the device

After the kernel and rootfs are in place:

```sh
lsmod | grep -E 'qcom_sns_reg|qcom_smgr'
dmesg | grep -iE 'sns_reg|smgr'
for d in /sys/bus/iio/devices/iio:device*; do echo "$d: $(cat $d/name)"; done
systemctl is-active iio-sensor-proxy
timeout 5 monitor-sensor          # orientation must track the phone
```

A healthy device shows `qcom-smgr-accel`, `qcom-smgr-gyro`, `qcom-smgr-mag`
and `qcom-smgr-prox`, `dmesg` reports `firmware loaded` from `qcom_sns_reg`,
and `monitor-sensor` prints `Has accelerometer`.

The accelerometer buffer streams raw samples; a quick check without the proxy
is

```sh
D=/sys/bus/iio/devices/iio:device$(for d in /sys/bus/iio/devices/iio:device*; do
        [ "$(cat $d/name)" = qcom-smgr-accel ] && echo ${d##*device}; done)
echo 1 > $D/buffer/enable
timeout 1 cat /dev/iio:device${D##*device} | od -An -tu2 | head
echo 0 > $D/buffer/enable
```

## On the IIO trigger

The SMGR child drivers use `devm_iio_kfifo_buffer_setup()` and push samples
from the QMI indication handler in `qcom_smgr_buffering_report_handler()`;
they self-trigger and have no `trigger/current_trigger` attribute.  A
`iio-trig-hrtimer` / `iio-trig-sysfs` trigger is therefore neither needed nor
usable here (and `CONFIG_IIO_CONFIGFS` is off, so
`/sys/kernel/config/iio/triggers/hrtimer/` does not exist).  Binding a
trigger would require rewriting the driver to use
`devm_iio_triggered_buffer_setup()` first.
