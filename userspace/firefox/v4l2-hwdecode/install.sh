#!/bin/sh
# Install the Firefox venus V4L2-M2M hardware-decode configuration into a
# root filesystem.
#
# Usage: install.sh <rootfs-root>
#
# It installs three things:
#   * /usr/lib/firefox/defaults/pref/99-v4l2-hwdecode-prefs.js
#     Turns the V4L2 hardware-decode path on for every profile.
#   * /usr/local/bin/firefox
#     Wrapper that exports LD_LIBRARY_PATH=/opt/rpi-ffmpeg/lib (the patched
#     ffmpeg) and MOZ_DISABLE_RDD_SANDBOX=1, then execs the real binary.
#   * /home/alarm/.local/share/applications/firefox.desktop
#     A per-user launcher override so the Phosh entry point runs the wrapper.
#     The user-level entry wins over the packaged one and (unlike editing the
#     package's /usr/share/applications/firefox.desktop) survives a firefox
#     package upgrade.
#
# The patched ffmpeg libraries themselves are installed by build-rootfs.sh
# from RPI_FFMPEG_LIBDIR; see README.md.
set -eu

[ "$#" -eq 1 ] || { echo "usage: $0 <rootfs-root>" >&2; exit 2; }
DEST="$1"
SRC="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

echo "==> installing Firefox venus V4L2-M2M hardware decode"
install -Dm644 "$SRC/pref/99-v4l2-hwdecode-prefs.js" \
    "$DEST/usr/lib/firefox/defaults/pref/99-v4l2-hwdecode-prefs.js"
install -Dm755 "$SRC/bin/firefox" "$DEST/usr/local/bin/firefox"

# Per-user desktop override (alarm).  The packaged desktop file execs
# /usr/lib/firefox/firefox directly; rewrite only the Exec=/TryExec= lines.
DESK="$DEST/usr/share/applications/firefox.desktop"
if [ -f "$DESK" ]; then
    UID_A=$(awk -F: '$1 == "alarm" { print $3 }' "$DEST/etc/passwd" 2>/dev/null || true)
    GID_A=$(awk -F: '$1 == "alarm" { print $4 }' "$DEST/etc/passwd" 2>/dev/null || true)
    DIR="$DEST/home/alarm/.local/share/applications"
    install -d "$DIR"
    sed -e 's#^\(Exec=\|TryExec=\)/usr/lib/firefox/firefox#\1/usr/local/bin/firefox#' \
        "$DESK" > "$DIR/firefox.desktop"
    chmod 644 "$DIR/firefox.desktop"
    if [ -n "$UID_A" ] && [ -n "$GID_A" ] && [ "$(id -u)" -eq 0 ]; then
        chown -R "$UID_A:$GID_A" \
            "$DEST/home/alarm/.local/share" "$DIR" "$DIR/firefox.desktop" 2>/dev/null || true
    fi
    echo "    desktop override -> /home/alarm/.local/share/applications/firefox.desktop"
else
    echo "WARNING: $DESK not found; the Phosh launcher will bypass the wrapper" >&2
fi
