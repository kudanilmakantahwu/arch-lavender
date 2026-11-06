#!/bin/sh
# Capture a sanitized root filesystem tarball from a *running* device.
#
# Run this as root ON THE PHONE, and redirect stdout to a file on the host:
#
#   ssh root@172.16.42.1 'sh -s' < scripts/capture-rootfs.sh > rootfs.tar
#   zstd -T0 -6 rootfs.tar -o rootfs-arch.tar.zst
#
# or, on the phone:
#
#   sh /root/capture-rootfs.sh > /tmp/rootfs.tar
#
# The exclusion list is intentionally aggressive.  Everything below is either
# a secret, a machine-specific identifier, a cache, or data that must not be
# published:
#
#   * /etc/shadow, /etc/gshadow          -> rootfs/overlay/ supplies them
#   * SSH host keys (all types)          -> regenerated on first boot
#   * authorized_keys, /home, /root      -> user data and browser/SMS history
#   * pacman private keys                -> public keyring is kept
#   * saved WiFi / NetworkManager state  -> contains the builder's networks
#   * machine-id, random-seed, resolv.conf, DHCP leases
#   * logs, caches, crash dumps, build trees
#
# The filesystem must be captured from `/`, one filesystem only, so mounted
# pseudo-filesystems and the boot partition are not included.

set -eu

exec tar -C / \
    --one-file-system \
    --numeric-owner \
    --ignore-failed-read \
    --warning=no-file-changed \
    -cpf - \
    --exclude=./proc \
    --exclude=./sys \
    --exclude=./dev \
    --exclude=./run \
    --exclude=./boot \
    --exclude=./tmp \
    --exclude=./var/tmp \
    --exclude=./var/log \
    --exclude=./var/cache \
    --exclude=./var/lib/systemd/coredump \
    --exclude=./var/lib/systemd/pstore \
    --exclude=./var/lib/systemd/network \
    --exclude=./var/lib/systemd/random-seed \
    --exclude=./var/lib/systemd/linger \
    --exclude=./var/lib/dbus/machine-id \
    --exclude=./var/lib/NetworkManager \
    --exclude=./var/lib/bluetooth \
    --exclude=./var/lib/geoclue \
    --exclude=./var/lib/AccountsService \
    --exclude=./var/lib/upower \
    --exclude=./root \
    --exclude=./home/alarm \
    --exclude=./home/maf \
    --exclude=./etc/shadow \
    --exclude=./etc/shadow- \
    --exclude=./etc/gshadow \
    --exclude=./etc/gshadow- \
    --exclude=./etc/machine-id \
    --exclude=./etc/resolv.conf \
    --exclude=./etc/ssh/ssh_host_* \
    --exclude=./etc/ssh/sshd_config.d/99-lab-anyuser.conf \
    --exclude=./etc/pacman.d/gnupg/private-keys-v1.d \
    --exclude=./etc/pacman.d/gnupg/secring.gpg \
    --exclude=./etc/pacman.d/gnupg/openpgp-revocs.d \
    --exclude=./etc/pacman.d/gnupg/pubring.gpg~ \
    --exclude=./etc/NetworkManager/system-connections \
    --exclude=./etc/NetworkManager/conf.d \
    --exclude=./etc/wpa_supplicant \
    --exclude=./etc/iwd \
    --exclude=./etc/ssl/private \
    --exclude=./etc/sudoers.d \
    --exclude=./etc/polkit-1/rules.d \
    --exclude=./usr/lib/modules/6.19.10-sdm660 \
    .