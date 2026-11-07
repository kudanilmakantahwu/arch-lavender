#!/bin/sh
# Share the PC's internet with the phone over the USB RNDIS link.
#
# Run this on the PC (as root), after the phone has booted and its USB
# interface has appeared:
#
#     sudo ./scripts/nat.sh [usb-interface]
#
# The USB interface is auto-detected (enx* or usb*).  Then follow the printed
# instructions on the phone to point its default route at the PC.
#
# This is optional and only useful before Wi-Fi is configured; once Wi-Fi
# works, unplugging the cable and removing the USB default route is fine.
set -eu

# On Debian/Ubuntu iptables and sysctl live in /usr/sbin, which is often not
# in a normal user's PATH; running the script through sudo usually fixes that,
# but be explicit so it also works from `su -c`.
PATH="$PATH:/usr/sbin:/sbin"
export PATH

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 [usb-interface]" >&2; exit 1; }

IFACE=${1:-}
if [ -z "$IFACE" ]; then
    IFACE=$(ip -brief link | awk '$1 ~ /^(enx|usb)/ { print $1; exit }')
fi
[ -n "$IFACE" ] || {
    echo "USB interface not found. Is the phone connected and booted?" >&2
    exit 1
}

WAN=$(ip route show default 2>/dev/null | awk '{ print $5; exit }')
[ -n "$WAN" ] || { echo "PC has no default route (no internet)." >&2; exit 1; }

echo "USB interface: $IFACE"
echo "internet via:  $WAN"

ip link set "$IFACE" up
ip addr replace 172.16.42.2/24 dev "$IFACE"

sysctl -qw net.ipv4.ip_forward=1

iptables -t nat -C POSTROUTING -s 172.16.42.0/24 -o "$WAN" -j MASQUERADE 2>/dev/null ||
    iptables -t nat -A POSTROUTING -s 172.16.42.0/24 -o "$WAN" -j MASQUERADE
iptables -C FORWARD -i "$IFACE" -o "$WAN" -j ACCEPT 2>/dev/null ||
    iptables -A FORWARD -i "$IFACE" -o "$WAN" -j ACCEPT
iptables -C FORWARD -i "$WAN" -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
    iptables -A FORWARD -i "$WAN" -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

cat <<EOF

NAT is enabled. On the phone (console on tty1, or over ssh) run:

    ip route replace default via 172.16.42.2 dev usb0
    printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf

Test with:  ping -c3 172.16.42.2   then   ping -c3 1.1.1.1

To undo on the PC:
    iptables -t nat -D POSTROUTING -s 172.16.42.0/24 -o $WAN -j MASQUERADE
EOF
