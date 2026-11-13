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

Empty `/root` and `/home/alarm` directories are recreated by
`build-rootfs.sh` with the correct owners. The build-only `maf` account is
removed, so the image ships exactly two login accounts: `root` and `alarm`.

The root and `alarm` passwords in `overlay/etc/shadow` are **`arch`** so the
first login and the Phosh session work. Change them immediately (see
`docs/INSTALL.md`).

## Build an image

```sh
sudo ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img
```

Options:

```sh
sudo IMG_SIZE=12G ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img
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
| `etc/shadow`, `etc/gshadow` | documented passwords, locked system users |
| `etc/environment` | `GSK_RENDERER=cairo` for the Adreno 512 GTK4 workaround |
| `etc/ssh/sshd_config.d/99-root-login.conf` | allow the first root login |
| `etc/NetworkManager/conf.d/usb0.conf` | keep NetworkManager off `usb0` |
| `etc/systemd/network/10-usb0.network` | static `172.16.42.1/24` + DHCP server |
| `etc/pacman.conf` | pin the kernel packages, Arch ARM architecture |
| `etc/pacman.d/mirrorlist` | Arch Linux ARM mirror |

## Phosh by default

The image boots to `graphical.target` and starts Phosh on `tty1` as user
`alarm`. `phosh.service` is installed from `../userspace/gui/` and carries the
`GSK_RENDERER=cairo` workaround for the Adreno 512 glyph bug.

The build:

- installs and enables `phosh.service` (plus `seatd`),
- enables `systemd-networkd`, `NetworkManager`, and `sshd`,
- keeps `getty@tty2` enabled as a text-console fallback,
- removes `getty@tty1` so it cannot fight the compositor,
- sets both `root` and `alarm` passwords to `arch`,
- deletes the `maf` build account and stale `fbkeyboard` / `touch-zoom` /
  patched-wlroots leftovers from the captured rootfs,
- drops older sdm660 module trees when the 7.2.3 tree is present.

There is no opt-in switch: Phosh is the only session this image ships.