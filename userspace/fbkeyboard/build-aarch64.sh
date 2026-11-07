#!/bin/sh
# Cross-compile fbkeyboard for the aarch64 Arch Linux ARM rootfs.
#
# Host dependencies (Debian/Ubuntu):
#   sudo dpkg --add-architecture arm64
#   sudo apt update
#   sudo apt install gcc-aarch64-linux-gnu libfreetype-dev:arm64
#
# Writes ../base/bin/fbkeyboard, which build-rootfs.sh installs into the image.
set -eu
cd "$(dirname "$0")"

aarch64-linux-gnu-gcc -O2 -Wall \
    -o ../base/bin/fbkeyboard \
    fbkeyboard.c \
    -I/usr/include/freetype2 \
    -L/usr/lib/aarch64-linux-gnu \
    -lfreetype -lm

file ../base/bin/fbkeyboard