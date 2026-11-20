#!/bin/sh
# Build a flashable ext4 root filesystem image from the released rootfs
# tarball, then (optionally) convert it to an Android sparse image.
#
# Usage (as root):
#   ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img
#   MESA_GALLIUM=/path/to/libgallium-<ABI>.so \
#       ./build-rootfs.sh rootfs-arch.tar.zst rootfs.img
#
# MESA_GALLIUM is optional; see userspace/mesa/README.md. Without it, the
# script selects the prebuilt matching the rootfs libEGL_mesa soname.
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

for arg in "$@"; do
    case "$arg" in
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
    echo "usage: $0 <rootfs.tar.zst> <rootfs.img>" >&2
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

# The capture was taken from the builder's machine and still carries the
# `maf` account plus leftovers from the old headless/experimental GUI.  This
# image ships root and alarm only, and Phosh is the only session.
echo "==> removing build account and stale GUI helpers"
for f in etc/passwd etc/group etc/shadow etc/gshadow etc/subuid etc/subgid; do
    [ -f "$MNT/$f" ] && sed -i '/^maf:/d' "$MNT/$f"
done
sed -i -e 's/,maf\>//g' -e 's/\<maf,//g' -e 's/:\<maf\>:/::/g' "$MNT/etc/group" 2>/dev/null || true
rm -rf "$MNT/home/maf"
rm -f "$MNT/usr/local/bin/fbkeyboard" \
      "$MNT/etc/profile.d/fbkeyboard-rows.sh" \
      "$MNT/etc/systemd/system/fbkeyboard.service" \
      "$MNT/etc/systemd/system/multi-user.target.wants/fbkeyboard.service" \
      "$MNT/usr/local/bin/touch-zoom" \
      "$MNT/etc/systemd/system/touch-zoom.service" \
      "$MNT/etc/systemd/system/graphical.target.wants/touch-zoom.service" \
      "$MNT/usr/local/lib/patched/libwlroots-0.20.so"
# Lab-only Mesa build; the release uses the patched libgallium in /usr/lib.
rm -rf "$MNT/opt/mesa-hbb"

# When the captured rootfs already carries the 7.2.3 module tree, drop older
# sdm660 trees (rollback copies) so depmod only sees the running kernel.
if [ -d "$MNT/usr/lib/modules/7.2.3-sdm660" ]; then
    find "$MNT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
        ! -name '7.2.3-sdm660' -exec rm -rf {} + 2>/dev/null || true
fi

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
for u in alarm; do
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
mkdir -p "$MNT/etc/modules-load.d"
printf 'libcomposite\nusb_f_rndis\n' > "$MNT/etc/modules-load.d/usb-gadget.conf"

echo "==> installing base userspace files"
install -Dm755 "$REPO/userspace/base/bin/modem-uim-init"      "$MNT/usr/local/sbin/modem-uim-init"
install -Dm755 "$REPO/userspace/base/bin/qcom-mss-stop"       "$MNT/usr/local/sbin/qcom-mss-stop"
install -Dm755 "$REPO/userspace/base/bin/reinstall-patched-libs" "$MNT/usr/local/sbin/reinstall-patched-libs"
install -Dm755 "$REPO/userspace/base/bin/usb-net-debug.sh"    "$MNT/usr/local/bin/usb-net-debug.sh"
install -Dm755 "$REPO/userspace/base/bin/zram-swap.sh"        "$MNT/usr/local/bin/zram-swap.sh"
install -Dm644 "$REPO/userspace/base/pacman/99-local-patches.hook" "$MNT/etc/pacman.d/hooks/99-local-patches.hook"

# The a512/FD512 glyph fix and GTK EGL config fix are patched userspace
# libgallium changes, not kernel changes. Prefer the exact ABI requested by
# this rootfs's libEGL_mesa, then fall back to an explicitly supplied or any
# prebuilt library.
MESA_LIB="${MESA_GALLIUM:-}"
if [ -z "$MESA_LIB" ] && [ -f "$MNT/usr/lib/libEGL_mesa.so.0" ] &&
   command -v readelf >/dev/null 2>&1; then
    MESA_NEEDED=$(readelf -d "$MNT/usr/lib/libEGL_mesa.so.0" 2>/dev/null |
                  sed -n 's/.*\[\(libgallium-.*\.so\)\].*/\1/p' | head -n 1)
    if [ -n "$MESA_NEEDED" ] && [ -f "$REPO/userspace/mesa/$MESA_NEEDED" ]; then
        MESA_LIB="$REPO/userspace/mesa/$MESA_NEEDED"
    fi
fi
if [ -n "$MESA_LIB" ]; then
    [ -f "$MESA_LIB" ] || { echo "MESA_GALLIUM not found: $MESA_LIB" >&2; exit 1; }
    MESA_NAME=$(basename "$MESA_LIB")
    if command -v readelf >/dev/null 2>&1; then
        readelf -h "$MESA_LIB" 2>/dev/null | grep -q 'AArch64' || {
            echo "error: $MESA_LIB is not an AArch64 library" >&2
            exit 1
        }
        readelf -d "$MESA_LIB" 2>/dev/null | grep -q "SONAME.*\\[$MESA_NAME\\]" || {
            echo "error: $MESA_LIB does not have soname $MESA_NAME" >&2
            exit 1
        }
    fi
    if [ -f "$MNT/usr/lib/libEGL_mesa.so.0" ]; then
        if command -v readelf >/dev/null 2>&1; then
            readelf -d "$MNT/usr/lib/libEGL_mesa.so.0" 2>/dev/null |
                grep -q "NEEDED.*\\[$MESA_NAME\\]" || {
                echo "error: $MESA_NAME is not the libgallium that the rootfs libEGL_mesa needs" >&2
                exit 1
            }
        elif ! grep -aq "$MESA_NAME" "$MNT/usr/lib/libEGL_mesa.so.0"; then
            echo "error: $MESA_NAME does not match the rootfs libEGL_mesa" >&2
            exit 1
        fi
    fi
    echo "==> installing patched $MESA_NAME"
    install -Dm755 "$MESA_LIB" "$MNT/usr/local/lib/patched/$MESA_NAME"
    install -Dm755 "$MESA_LIB" "$MNT/usr/lib/$MESA_NAME"
else
    echo "WARNING: no patched libgallium provided; the image keeps the" >&2
    echo "         distro Mesa and the a512 glyph loss remains." >&2
    echo "         See userspace/mesa/README.md." >&2
fi

for u in tqftpserv pd-mapper diag-router rmtfs modem-uim-init usb-net-debug zram-swap; do
    install -Dm644 "$REPO/userspace/base/systemd/$u.service" "$MNT/etc/systemd/system/$u.service"
    ln -sf "/etc/systemd/system/$u.service" "$MNT/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || true
done

echo "==> installing ALSA UCM2 profile, WirePlumber format rule, and audio module list"
install -Dm644 "$REPO/userspace/audio/ucm2/conf.d/sdm660/sdm660.conf" \
    "$MNT/usr/share/alsa/ucm2/conf.d/sdm660/sdm660.conf"
install -Dm644 "$REPO/userspace/audio/ucm2/conf.d/sdm660/Xiaomi Redmi Note 7.conf" \
    "$MNT/usr/share/alsa/ucm2/conf.d/sdm660/Xiaomi Redmi Note 7.conf"
install -Dm644 "$REPO/userspace/audio/ucm2/Qualcomm/lavender/HiFi.conf" \
    "$MNT/usr/share/alsa/ucm2/Qualcomm/lavender/HiFi.conf"
install -Dm644 "$REPO/userspace/audio/ucm2/Qualcomm/lavender/Mic.conf" \
    "$MNT/usr/share/alsa/ucm2/Qualcomm/lavender/Mic.conf"
# PipeWire picks S24_LE for the front end, but the machine driver fixes the
# Primary MI2S backend at S16_LE; the DSP then passes only the low 16 bits to
# the amp and playback is ~48 dB quiet.  Force the speaker sink to S16LE.
install -Dm644 "$REPO/userspace/audio/wireplumber/wireplumber.conf.d/50-lavender-s16.conf" \
    "$MNT/etc/wireplumber/wireplumber.conf.d/50-lavender-s16.conf"
install -Dm644 "$REPO/userspace/audio/modules-load.d/sdm660-audio.conf" \
    "$MNT/etc/modules-load.d/sdm660-audio.conf"

# The captured image carries an asound.state with the old over-amplified
# Digital Volume (127 = +15.75 dB), which alsa-restore would put back at boot.
# Drop it: without a saved state the driver init values (the vendor defaults
# used by the UCM) stay in place, and the UCM re-applies them per stream.
rm -f "$MNT/var/lib/alsa/asound.state"

# The patched ModemManager lives in /usr/local/lib/patched so the pacman hook
# can restore it after a package upgrade.  Install it right away too.
if [ -f "$MNT/usr/local/lib/patched/ModemManager" ]; then
    install -Dm755 "$MNT/usr/local/lib/patched/ModemManager" "$MNT/usr/bin/ModemManager"
    install -Dm755 "$MNT/usr/local/lib/patched/ModemManager" "$MNT/usr/sbin/ModemManager"
fi

# Phosh is the default UI.  The phone boots to graphical.target on tty1;
# getty@tty2 stays available as a text-console fallback (Ctrl+Alt+F2), and
# SSH over USB/WiFi is unaffected.
echo "==> installing Phosh session and enabling graphical target"
install -Dm644 "$REPO/userspace/gui/systemd/phosh.service" "$MNT/etc/systemd/system/phosh.service"
install -Dm755 "$REPO/userspace/gui/bin/lavender-session-defaults" \
    "$MNT/usr/local/bin/lavender-session-defaults"
# s2idle is broken on this kernel and every failed cycle re-registers the
# sound card.  Refuse suspend requests at the systemd level as a backstop;
# the Phosh session script turns the GNOME/Phosh timers off as well.
install -Dm644 "$REPO/userspace/base/sleep.conf.d/10-lavender.conf" \
    "$MNT/etc/systemd/sleep.conf.d/10-lavender.conf"
mkdir -p "$MNT/etc/systemd/system/graphical.target.wants"
ln -sf /etc/systemd/system/phosh.service \
       "$MNT/etc/systemd/system/graphical.target.wants/phosh.service"

# Firefox needs the mobile config out of the box: touch density, a bottom URL
# bar, the tab counter and the shared/release theme sheets.  The payload is
# vendored (no first-boot network) and the autoconfig file is what turns it on.
# See userspace/firefox/README.md.
echo "==> installing Firefox mobile config"
sh "$REPO/userspace/firefox/install.sh" "$MNT"

# systemctl --root works without booting the image.
if command -v systemctl >/dev/null 2>&1 &&
   systemctl --root="$MNT" set-default graphical.target >/dev/null 2>&1; then
    for u in phosh seatd NetworkManager sshd getty@tty2 systemd-networkd; do
        systemctl --root="$MNT" enable "$u.service" >/dev/null 2>&1 || true
    done
else
    ln -sf /usr/lib/systemd/system/graphical.target "$MNT/etc/systemd/system/default.target"
    mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
    for u in seatd NetworkManager sshd systemd-networkd; do
        ln -sf "/usr/lib/systemd/system/$u.service" \
               "$MNT/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || true
    done
    mkdir -p "$MNT/etc/systemd/system/getty.target.wants"
    ln -sf /usr/lib/systemd/system/getty@.service \
           "$MNT/etc/systemd/system/getty.target.wants/getty@tty2.service" 2>/dev/null || true
fi

# Phosh owns tty1.  Keep getty off that VT so it cannot fight the compositor,
# and drop any stale headless keyboard unit from the captured image.
#
# Waydroid is optional and is not installed in the release base.  If a capture
# still carries it, do not start the container at boot and never ship
# /var/lib/waydroid (Android images/user data).  Users who want it install the
# package, run `waydroid init`, and enable waydroid-container.service.
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/waydroid-container.service" \
      "$MNT/etc/systemd/system/getty@tty1.service" \
      "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" \
      "$MNT/etc/systemd/system/multi-user.target.wants/getty@tty1.service" \
      "$MNT/etc/systemd/system/multi-user.target.wants/fbkeyboard.service"

# phosh.service uses PAMName=login, which refuses a locked account.  Both
# documented accounts use password `arch`; change them after first login.
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

# The captured image had a duplicate root-login drop-in with an unclear name.
# The overlay's 99-root-login.conf replaces it.
rm -f "$MNT/etc/ssh/sshd_config.d/99-lab-anyuser.conf"

# Never ship host keys or a machine id from the build host.
rm -f "$MNT"/etc/ssh/ssh_host_* 2>/dev/null || true
: > "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/systemd/random-seed" 2>/dev/null || true

# Refuse to ship an image that would boot without the audio stack or that
# cannot load the patched Mesa.  Both have silently regressed before: a rebuild
# dropped snd-soc-sm8250.ko.zst and the speaker went quiet, and a libgallium
# whose soname did not match libEGL_mesa made GTK fall back to cairo.  Failing
# here is far cheaper than flashing and debugging on the phone.
echo "==> verifying the staged image"
verify_fail=0

moddir="$MNT/usr/lib/modules/7.2.3-sdm660"
if [ -d "$moddir" ]; then
    for m in snd-soc-sm8250 snd-soc-max98937; do
        if [ -z "$(find "$moddir" -name "$m.ko*" -print -quit 2>/dev/null)" ]; then
            echo "error: $m is missing from $moddir" >&2
            verify_fail=1
        fi
    done
else
    echo "error: no module tree at $moddir" >&2
    verify_fail=1
fi
[ -f "$MNT/usr/share/alsa/ucm2/Qualcomm/lavender/HiFi.conf" ] || {
    echo "error: the lavender UCM2 profile is missing" >&2
    verify_fail=1
}
[ -f "$MNT/etc/wireplumber/wireplumber.conf.d/50-lavender-s16.conf" ] || {
    echo "error: the WirePlumber S16LE rule is missing" >&2
    verify_fail=1
}

# Every NEEDED soname of the shipped Mesa stack must resolve inside the image;
# a missing one means the GL driver cannot load and the UI drops to software.
for lib in "$MNT/usr/lib/libEGL_mesa.so.0" "$MNT/usr/lib/libgbm.so.1" \
           "$MNT/usr/lib/dri/libdril_dri.so" "$MNT"/usr/lib/libgallium-*.so; do
    [ -f "$lib" ] || continue
    command -v readelf >/dev/null 2>&1 || break
    for need in $(readelf -d "$lib" 2>/dev/null |
                  sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p'); do
        if [ ! -e "$MNT/usr/lib/$need" ] && [ ! -e "$MNT/lib/$need" ]; then
            echo "error: $need (needed by $(basename "$lib")) is missing" >&2
            verify_fail=1
        fi
    done
done

grep -q '^GSK_RENDERER=gl' "$MNT/etc/environment" || {
    echo "error: GSK_RENDERER=gl missing from /etc/environment" >&2
    verify_fail=1
}
grep -q '^FD_MESA_DEBUG=noubwc' "$MNT/etc/environment" || {
    echo "error: FD_MESA_DEBUG=noubwc missing from /etc/environment" >&2
    verify_fail=1
}
grep -q 'Environment=GSK_RENDERER=gl' "$MNT/etc/systemd/system/phosh.service" || {
    echo "error: GSK_RENDERER=gl missing from phosh.service" >&2
    verify_fail=1
}
grep -q 'Environment=FD_MESA_DEBUG=noubwc' "$MNT/etc/systemd/system/phosh.service" || {
    echo "error: FD_MESA_DEBUG=noubwc missing from phosh.service" >&2
    verify_fail=1
}

if [ "$verify_fail" -ne 0 ]; then
    echo "error: refusing to produce a broken image" >&2
    exit 1
fi
echo "==> staged image checks passed"

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