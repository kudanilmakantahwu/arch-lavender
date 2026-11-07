#!/bin/sh
# Build a flashable ext4 root filesystem image from the released rootfs
# tarball, then (optionally) convert it to an Android sparse image.
#
# Usage (as root):
#   ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img [--with-gui]
#
# Requirements on the host: tar, zstd, e2fsprogs (mkfs.ext4, e2fsck,
# resize2fs).  android-sdk-libsparse-tools (img2simg) is optional; without
# it fastboot can still flash the raw .img.
#
# The image is created with the label pmOS_root, which is what the
# initramfs uses to find the root filesystem.  The phone's userdata
# partition is larger than the image; grow the filesystem online after the
# first boot with:
#     resize2fs /dev/disk/by-partlabel/userdata
set -eu

IMG_SIZE="${IMG_SIZE:-8G}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)

TARBALL=""
OUT=""
WITH_GUI=0

for arg in "$@"; do
    case "$arg" in
        --with-gui) WITH_GUI=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)
            if [ -z "$TARBALL" ]; then TARBALL="$arg"
            elif [ -z "$OUT" ]; then OUT="$arg"
            else echo "too many arguments" >&2; exit 2
            fi
            ;;
    esac
done

[ -n "$TARBALL" ] && [ -n "$OUT" ] || {
    echo "usage: $0 <rootfs.tar.zst> <rootfs.img> [--with-gui]" >&2
    exit 2
}
[ "$(id -u)" -eq 0 ] || { echo "must run as root (needs loop mounts)" >&2; exit 1; }

MNT=$(mktemp -d)
cleanup() {
    umount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> creating $IMG_SIZE ext4 image $OUT (label pmOS_root)"
rm -f "$OUT"
truncate -s "$IMG_SIZE" "$OUT"
mkfs.ext4 -q -L pmOS_root -F "$OUT"

echo "==> mounting"
mount -o loop "$OUT" "$MNT"

echo "==> extracting root filesystem"
zstd -dc "$TARBALL" | tar -xpf - -C "$MNT" --numeric-owner

echo "==> applying overlay"
cp -a "$REPO/rootfs/overlay/." "$MNT/"

# The released tarball was re-packed by the sanitizer while it ran as an
# unprivileged user with --numeric-owner, so every one of its ~112k entries --
# and every file copied from the overlay with `cp -a` -- is owned by uid/gid
# 1000 instead of root.  This is not cosmetic:
#
#   * /usr/bin/mount, su, sudo, passwd, ... are setuid programs.  Owned by
#     1000, they run with euid 1000, so util-linux refuses with "must be
#     superuser to use mount" and EVERY mount unit fails -- including
#     sys-kernel-config.mount, which the USB RNDIS gadget needs.  That is why
#     the phone had no USB network at all.
#   * sshd refuses to start because /usr/share/empty.sshd is not owned by root.
#
# Restore root ownership, then re-fix the few paths that belong to other
# accounts (the home directories, further down).
echo "==> restoring root ownership (tarball ships files owned by uid 1000)"
# chown(1) clears setuid/setgid bits when it changes ownership.  Record every
# file/directory that has one *before* the chown, then restore the exact mode
# afterwards.  A hard-coded list of helpers misses pkexec, unix_chkpwd, the
# setgid `tty` programs (wall/write) and setgid directories.
suid_list=$(mktemp)
find "$MNT" -xdev -perm /6000 -printf '%m\t%p\n' > "$suid_list" 2>/dev/null || true
chown -R 0:0 "$MNT"
chmod 600 "$MNT/etc/shadow" "$MNT/etc/gshadow" 2>/dev/null || true
chmod 440 "$MNT/etc/sudoers" 2>/dev/null || true
while IFS="$(printf '\t')" read -r mode path; do
    [ -n "$mode" ] && [ -n "$path" ] && chmod "$mode" "$path" 2>/dev/null || true
done < "$suid_list"
rm -f "$suid_list"

# The capture excludes /root and the user homes (they contained browser data,
# chat history and build trees).  Recreate empty, correctly-owned homes.
echo "==> recreating empty home directories"
mkdir -p "$MNT/home"
chmod 755 "$MNT/home"
for u in alarm maf; do
    uid=$(awk -F: -v u="$u" '$1 == u { print $3 }' "$MNT/etc/passwd")
    gid=$(awk -F: -v u="$u" '$1 == u { print $4 }' "$MNT/etc/passwd")
    [ -n "$uid" ] || continue
    mkdir -p "$MNT/home/$u"
    chown "$uid:$gid" "$MNT/home/$u"
    chmod 700 "$MNT/home/$u"
done
mkdir -p "$MNT/root" "$MNT/var/lib/dbus"
chown 0:0 "$MNT/root"
chmod 700 "$MNT/root"
ln -sf /etc/machine-id "$MNT/var/lib/dbus/machine-id"

# The capture deleted /var/log and /var/cache along with the logs.  systemd,
# journald and the USB gadget helper all expect /var/log to exist.  Without
# it, usb-net-debug.sh dies on `exec >>/var/log/usb-net-debug.log` and the
# phone comes up with no USB network at all.
echo "==> recreating /var/log and /var/cache"
mkdir -p "$MNT/var/log/journal" "$MNT/var/cache"
chmod 755 "$MNT/var/log" "$MNT/var/log/journal" "$MNT/var/cache"

# Load the gadget modules early so the RNDIS gadget can be created.
echo "==> enabling USB gadget modules at boot"
printf 'libcomposite\nusb_f_rndis\n' > "$MNT/etc/modules-load.d/usb-gadget.conf"

echo "==> installing base userspace files"
install -Dm755 "$REPO/userspace/base/bin/modem-uim-init"      "$MNT/usr/local/sbin/modem-uim-init"
install -Dm755 "$REPO/userspace/base/bin/qcom-mss-stop"       "$MNT/usr/local/sbin/qcom-mss-stop"
install -Dm755 "$REPO/userspace/base/bin/reinstall-patched-libs" "$MNT/usr/local/sbin/reinstall-patched-libs"
install -Dm755 "$REPO/userspace/base/bin/usb-net-debug.sh"    "$MNT/usr/local/bin/usb-net-debug.sh"
install -Dm755 "$REPO/userspace/base/bin/zram-swap.sh"        "$MNT/usr/local/bin/zram-swap.sh"
install -Dm644 "$REPO/userspace/base/pacman/99-local-patches.hook" "$MNT/etc/pacman.d/hooks/99-local-patches.hook"

for u in tqftpserv pd-mapper diag-router rmtfs modem-uim-init usb-net-debug zram-swap; do
    install -Dm644 "$REPO/userspace/base/systemd/$u.service" "$MNT/etc/systemd/system/$u.service"
    ln -sf "/etc/systemd/system/$u.service" "$MNT/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || true
done

# On-screen keyboard on the framebuffer console, so the phone can be used
# (and debugged) without USB networking or an OTG keyboard.
if [ -f "$REPO/userspace/base/bin/fbkeyboard" ]; then
    echo "==> installing fbkeyboard on-screen keyboard"
    install -Dm755 "$REPO/userspace/base/bin/fbkeyboard" "$MNT/usr/local/bin/fbkeyboard"
    install -Dm644 "$REPO/userspace/base/systemd/fbkeyboard.service" "$MNT/etc/systemd/system/fbkeyboard.service"
    install -Dm644 "$REPO/userspace/base/profile.d/fbkeyboard-rows.sh" "$MNT/etc/profile.d/fbkeyboard-rows.sh"
    ln -sf /etc/systemd/system/fbkeyboard.service \
           "$MNT/etc/systemd/system/multi-user.target.wants/fbkeyboard.service" 2>/dev/null || true
else
    echo "==> fbkeyboard binary not present; skipping on-screen keyboard"
fi

# The patched binaries live in /usr/local/lib/patched so the pacman hook can
# restore them after a package upgrade.  Install them right away too.
if [ -f "$MNT/usr/local/lib/patched/ModemManager" ]; then
    install -Dm755 "$MNT/usr/local/lib/patched/ModemManager" "$MNT/usr/bin/ModemManager"
    install -Dm755 "$MNT/usr/local/lib/patched/ModemManager" "$MNT/usr/sbin/ModemManager"
fi
if [ -f "$MNT/usr/local/lib/patched/libwlroots-0.20.so" ]; then
    install -Dm755 "$MNT/usr/local/lib/patched/libwlroots-0.20.so" "$MNT/usr/lib/libwlroots-0.20.so"
fi

# Headless by default: console on tty1, no compositor autostart.
# The released rootfs was captured from a Phosh session, so undo its GUI
# enablement explicitly.  systemctl --root works without booting the image.
if command -v systemctl >/dev/null 2>&1 &&
   systemctl --root="$MNT" set-default multi-user.target >/dev/null 2>&1; then
    systemctl --root="$MNT" enable getty@tty1.service >/dev/null 2>&1 || true
    systemctl --root="$MNT" enable systemd-networkd.service >/dev/null 2>&1 || true
    systemctl --root="$MNT" enable NetworkManager.service >/dev/null 2>&1 || true
    systemctl --root="$MNT" enable sshd.service >/dev/null 2>&1 || true
else
    ln -sf /usr/lib/systemd/system/multi-user.target "$MNT/etc/systemd/system/default.target"
    ln -sf /usr/lib/systemd/system/getty@.service \
           "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" 2>/dev/null || true
fi
rm -f "$MNT/etc/systemd/system/getty@tty1.service"
rm -f "$MNT/etc/systemd/system/graphical.target.wants/phosh.service"
rm -f "$MNT/etc/systemd/system/graphical.target.wants/touch-zoom.service"
ln -sf /usr/lib/systemd/system/getty@.service \
       "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" 2>/dev/null || true
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
for u in systemd-networkd NetworkManager sshd; do
    ln -sf "/usr/lib/systemd/system/$u.service" \
           "$MNT/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || true
done

if [ "$WITH_GUI" -eq 1 ]; then
    echo "==> enabling EXPERIMENTAL Phosh session"
    install -Dm755 "$REPO/userspace/gui-experimental/bin/touch-zoom" "$MNT/usr/local/bin/touch-zoom"
    for u in phosh touch-zoom; do
        install -Dm644 "$REPO/userspace/gui-experimental/systemd/$u.service" "$MNT/etc/systemd/system/$u.service"
        ln -sf "/etc/systemd/system/$u.service" "$MNT/etc/systemd/system/graphical.target.wants/$u.service"
    done
    # Phosh provides its own keyboard; do not draw fbkeyboard on top of it.
    rm -f "$MNT/etc/systemd/system/multi-user.target.wants/fbkeyboard.service"
    rm -f "$MNT/etc/systemd/system/getty@tty1.service"
    rm -f "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service"
    ln -sf /usr/lib/systemd/system/graphical.target "$MNT/etc/systemd/system/default.target"
    ln -sf /usr/lib/systemd/system/systemd-user-sessions.service \
           "$MNT/etc/systemd/system/graphical.target.wants/systemd-user-sessions.service" 2>/dev/null || true

    # phosh.service uses PAMName=login, which refuses a locked account.  Give
    # alarm the same documented password as root so the opt-in GUI can start;
    # change it after the first login.
    if command -v chpasswd >/dev/null 2>&1 &&
       printf 'alarm:arch\n' | chpasswd -R "$MNT" >/dev/null 2>&1; then
        :
    else
        ROOTHASH=$(awk -F: '$1 == "root" { print $2 }' "$MNT/etc/shadow")
        awk -F: -v OFS=: -v h="$ROOTHASH" '$1 == "alarm" { $2 = h } { print }' \
            "$MNT/etc/shadow" > "$MNT/etc/shadow.tmp"
        mv "$MNT/etc/shadow.tmp" "$MNT/etc/shadow"
    fi
    chmod 600 "$MNT/etc/shadow" "$MNT/etc/gshadow" 2>/dev/null || true
fi

# The captured image had a duplicate root-login drop-in with an unclear name.
# The overlay's 99-root-login.conf replaces it.
rm -f "$MNT/etc/ssh/sshd_config.d/99-lab-anyuser.conf"

# Never ship host keys or a machine id from the build host.
rm -f "$MNT"/etc/ssh/ssh_host_* 2>/dev/null || true
: > "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/systemd/random-seed" 2>/dev/null || true

echo "==> unmounting"
sync
umount "$MNT"
trap - EXIT INT TERM
rmdir "$MNT" 2>/dev/null || true

echo "==> filesystem check"
e2fsck -pf "$OUT" || e2fsck -fy "$OUT" || true

echo "==> growing filesystem to image size"
resize2fs "$OUT" >/dev/null 2>&1 || true

if command -v img2simg >/dev/null 2>&1; then
    echo "==> converting to Android sparse image: ${OUT}.sparse"
    img2simg "$OUT" "${OUT}.sparse"
    echo "done: ${OUT}.sparse"
else
    echo "img2simg not found; flash the raw image directly: $OUT"
fi