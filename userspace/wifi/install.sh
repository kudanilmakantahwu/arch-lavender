#!/bin/sh
# Install the ath10k_snoc throughput fix + watchdog on the running system.
#
# Usage (as root on the device):
#   ./install.sh
#   PROFILE="My SSID" ./install.sh
#
# It installs:
#   /etc/NetworkManager/dispatcher.d/99-ath10k-fix   (root:root, 0755)
#   /usr/local/sbin/ath10k-watchdog.sh               (root:root, 0755)
#   /etc/systemd/system/ath10k-watchdog.service      (root:root, 0644)
# disables IPv6 and pins DNS on the Wi-Fi profile, then enables and starts the
# watchdog. Requires `ethtool` (install it with pacman first).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="${PROFILE:-CAPING GUNUNG}"
DNS="${DNS:-1.1.1.1 8.8.8.8}"

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }
command -v ethtool >/dev/null || { echo "ethtool is required (pacman -S ethtool)" >&2; exit 1; }

install -d -m 0755 /etc/NetworkManager/dispatcher.d
install -m 0755 -o root -g root "$HERE/99-ath10k-fix" \
    /etc/NetworkManager/dispatcher.d/99-ath10k-fix

install -m 0755 -o root -g root "$HERE/ath10k-watchdog.sh" \
    /usr/local/sbin/ath10k-watchdog.sh
install -m 0644 -o root -g root "$HERE/ath10k-watchdog.service" \
    /etc/systemd/system/ath10k-watchdog.service

# Wi-Fi profile: no IPv6, fixed DNS.
nmcli connection modify "$PROFILE" \
    ipv6.method disabled \
    ipv4.ignore-auto-dns yes \
    ipv4.dns "$DNS"
nmcli connection up "$PROFILE" >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable --now ath10k-watchdog.service

echo "installed. status:"
systemctl --no-pager --full status ath10k-watchdog.service | head -n 12
