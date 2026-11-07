#!/bin/sh
# Bring up a USB RNDIS gadget with a fixed address so the phone can be
# reached over the USB cable while there is no GUI / no WiFi.
#
# Phone: 172.16.42.1/24 (this script)
# Host : 172.16.42.2/24 (DHCP from systemd-networkd, or set manually)
#
# The address is assigned by /etc/systemd/network/10-usb0.network, which also
# runs a DHCP server.  Logs go to /var/log/usb-net-debug.log.
#
# NOTE: the released rootfs tarball is sanitized and does not contain /var/log
# (the capture removed all logs).  build-rootfs.sh recreates it, but create it
# here too: `exec >>file` on a missing directory kills the shell outright.
mkdir -p /var/log
exec >>/var/log/usb-net-debug.log 2>&1
set -x

BB=/opt/pmos-busybox
export LD_LIBRARY_PATH=$BB/lib

modprobe libcomposite 2>/dev/null || "$BB/busybox" modprobe libcomposite 2>/dev/null || true
modprobe usb_f_rndis 2>/dev/null || "$BB/busybox" modprobe usb_f_rndis 2>/dev/null || true

# configfs is usually mounted by systemd (sys-kernel-config.mount); mount it
# ourselves if it is not.  The mount point may not exist yet (systemd creates
# it for the mount unit), and mounting onto a missing directory fails with
# ENOENT -- that was the original "no USB at all" bug.
if [ ! -d /sys/kernel/config/usb_gadget ]; then
    mkdir -p /sys/kernel/config
    mount -t configfs configfs /sys/kernel/config
fi

echo "ARCH-USB: UDC list: $(ls /sys/class/udc 2>/dev/null | tr '\n' ' ')"
echo "ARCH-USB: gadget modules: $(lsmod 2>/dev/null | grep -E 'libcomposite|usb_f_rndis|u_ether' | tr '\n' ' ')"

G=/sys/kernel/config/usb_gadget/archdbg
if [ ! -d "$G" ]; then
    mkdir -p "$G" || exit 0
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
fi

# The UDC (dwc3) may probe after this unit starts, so wait for it and bind.
i=0
while [ -z "$(cat "$G/UDC" 2>/dev/null)" ]; do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
    [ -n "$UDC" ] && echo "$UDC" > "$G/UDC" 2>/dev/null
    [ -n "$(cat "$G/UDC" 2>/dev/null)" ] && break
    i=$((i+1))
    [ "$i" -ge 60 ] && break
    sleep 1
done
echo "ARCH-USB: bound UDC: $(cat "$G/UDC" 2>/dev/null)"

# Give the gadget a moment to enumerate, then assign the fixed address.
sleep 2
if command -v ip >/dev/null 2>&1; then
    ip link set usb0 up 2>/dev/null || true
    ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
else
    "$BB/busybox" ifconfig usb0 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null || true
fi
exit 0
