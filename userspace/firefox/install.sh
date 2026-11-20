#!/bin/sh
# Install mobile-config-firefox (postmarketOS / NuraOS) into a root filesystem.
#
# Usage: install.sh <rootfs-root>
#
# The payload is a vendored copy of the upstream project so the image stays
# plug-and-play.  It has two parts:
#
#   /usr/lib/firefox/distribution/policies.json          enterprise policies
#   /usr/lib/firefox/defaults/pref/mobile-config-prefs.js autoconfig + touch prefs
#   /usr/lib/firefox/mobile-config-autoconfig.js          autoconfig bootstrapper
#   /usr/lib/mobile-config-firefox/                       system modules + themes
#
# The autoconfig file registers /usr/lib/mobile-config-firefox/chrome.manifest
# and imports boot.sys.mjs, which sets the mobile default preferences
# (touch density, toolkit.legacyUserProfileCustomizations.stylesheets, ...) and
# loads the shared + release theme sheets.  See
# userspace/firefox/README.md.
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <rootfs-root>" >&2
    exit 2
fi

DEST="$1"
SRC="$(cd "$(dirname "$0")" && pwd)/src"

install -Dm644 "$SRC/policies.json" \
    "$DEST/usr/lib/firefox/distribution/policies.json"
install -Dm644 "$SRC/mobile-config-prefs.js" \
    "$DEST/usr/lib/firefox/defaults/pref/mobile-config-prefs.js"
install -Dm644 "$SRC/mobile-config-autoconfig.js" \
    "$DEST/usr/lib/firefox/mobile-config-autoconfig.js"

mkdir -p "$DEST/usr/lib/mobile-config-firefox/themes"
# Do not use `cp -a` here: it preserves the source owner, so a build run from a
# checkout owned by uid 1000 would leave the shipped payload owned by 1000.
# The image must stay root-owned (setuid helpers, sshd, and pacman all care).
cp -R "$SRC/modules/." "$DEST/usr/lib/mobile-config-firefox/"
cp -R "$SRC/themes/." "$DEST/usr/lib/mobile-config-firefox/themes/"
# Make the ownership deterministic when the installer runs privileged.
if [ "$(id -u)" -eq 0 ]; then
    chown -R 0:0 "$DEST/usr/lib/mobile-config-firefox"
fi

install -Dm644 "$(cd "$(dirname "$0")" && pwd)/metainfo/eco.nura.mobile_config_firefox.metainfo.xml" \
    "$DEST/usr/share/metainfo/eco.nura.mobile_config_firefox.metainfo.xml"
