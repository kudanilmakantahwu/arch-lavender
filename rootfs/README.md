# rootfs

The release ships `rootfs-arch.tar.zst`, a sanitized capture of the Arch
Linux ARM root filesystem. It is a tarball rather than a disk image so it is
smaller and easier to verify.

## What is removed

The capture is produced by
[`../scripts/capture-rootfs.sh`](../scripts/capture-rootfs.sh). It excludes:

- `/etc/shadow`, `/etc/gshadow` (the overlay supplies sanitized versions),
- every SSH host key (RSA, ECDSA, ED25519, ML-DSA) and `authorized_keys`,
- `/root` and all user home directories (browser profiles, cookies, chat/SMS
  history, shell history, build trees),
- pacman private keys (`secring.gpg`, `private-keys-v1.d`,
  `openpgp-revocs.d`) while keeping the public keyring,
- saved NetworkManager connections and `/etc/NetworkManager/conf.d`,
- `/etc/resolv.conf`, DHCP leases, `/var/lib/dbus/machine-id`,
- logs, caches, crash dumps, the old `6.19.10-sdm660` module tree.

Empty `/root`, `/home/alarm`, and `/home/maf` directories are recreated by
`build-rootfs.sh` with the correct owners.

The root password in `overlay/etc/shadow` is **`arch`** so the first login
works. Change it immediately (see `docs/INSTALL.md`).

## Build an image

```sh
sudo ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img
```

Options:

```sh
sudo IMG_SIZE=12G ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img
sudo ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img --with-gui
```

The script requires root because it loop-mounts the image. It needs
`mkfs.ext4`, `e2fsck`, `resize2fs`, `zstd`, and `tar`. `img2simg` is optional
but strongly recommended; without it you get a raw 8 GiB image instead of a
sparse one.

## Overlay

`overlay/` is copied over the extracted tarball with `cp -a`. It contains the
files that must not come from the captured system:

| File | Purpose |
| --- | --- |
| `etc/fstab` | mounts `LABEL=pmOS_root` |
| `etc/hostname` | `lave-arch` |
| `etc/shadow`, `etc/gshadow` | documented root password, locked system users |
| `etc/ssh/sshd_config.d/99-root-login.conf` | allow the first root login |
| `etc/NetworkManager/conf.d/usb0.conf` | keep NetworkManager off `usb0` |
| `etc/systemd/network/10-usb0.network` | static `172.16.42.1/24` + DHCP server |
| `etc/pacman.conf` | pin the kernel packages, Arch ARM architecture |
| `etc/pacman.d/mirrorlist` | Arch Linux ARM mirror |

## Headless by default

The tarball was captured from a Phosh session, so `build-rootfs.sh` explicitly
undoes the GUI enablement:

- `default.target` → `multi-user.target`
- `getty@tty1` enabled (the `/dev/null` mask is removed)
- `phosh` and `touch-zoom` removed from `graphical.target.wants`
- `systemd-networkd`, `NetworkManager`, and `sshd` enabled

`--with-gui` reverses this and enables the experimental session.