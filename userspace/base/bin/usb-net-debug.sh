#!/bin/sh
# Bring up a USB RNDIS gadget with a fixed address so the phone can be
# reached over the USB cable while there is no GUI / no WiFi.
#
# Phone: 172.16.42.1/24 (this script)
# Host : 172.16.42.2/24 (DHCP from systemd-networkd, or set manually)
#
# The address is assigned by /etc/systemd/network/10-usb0.network, which also
# runs a DHCP server.  Logs go to /var/log/usb-net-debug.log.
exec >>/var/log/usb-net-debug.log 2>&1
set -x
BB=/opt/pmos-busybox
export LD_LIBRARY_PATH=$BB/lib
modprobe libcomposite 2>/dev/null || $BB/busybox modprobe libcomposite
modprobe usb_f_rndis 2>/dev/null || $BB/busybox modprobe usb_f_rndis
G=/sys/kernel/config/usb_gadget/archdbg
if [ ! -d "$G" ]; then
  mkdir -p "$G"
  echo 0x1d6b > "$G/idVendor"
  echo 0x0104 > "$G/idProduct"
  echo 0x0100 > "$G/bcdDevice"
  echo 0x0200 > "$G/bcdUSB"
  mkdir -p "$G/strings/0x409"
  echo arch0001 > "$G/strings/0x409/serialnumber"
  echo ArchLinux > "$G/strings/0x409/manufacturer"
  echo Lavender > "$G/strings/0x409/product"
  mkdir -p "$G/configs/c.1/strings/0x409"
  echo rndis > "$G/configs/c.1/strings/0x409/configuration"
  mkdir -p "$G/functions/rndis.usb0"
  echo 02:00:00:00:00:01 > "$G/functions/rndis.usb0/dev_addr"
  echo 02:00:00:00:00:02 > "$G/functions/rndis.usb0/host_addr"
  ln -sf "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0" 2>/dev/null || true
  UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
  [ -n "$UDC" ] && echo "$UDC" > "$G/UDC"
fi
sleep 3
if command -v ip >/dev/null 2>&1; then
  ip link set usb0 up 2>/dev/null || true
  ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
else
  $BB/busybox ifconfig usb0 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null || true
fi
exit 0