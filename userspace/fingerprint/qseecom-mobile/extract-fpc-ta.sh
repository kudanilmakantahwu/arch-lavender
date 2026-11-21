#!/bin/sh
# Extract the vendor-signed FPC fingerprint Trusted Application from the stock
# Android firmware, so it can be placed in /lib/firmware/ for the
# qcom_qseecom_mobile transport to load into TrustZone.
#
# The blobs are NOT part of this repository (they are Xiaomi-signed proprietary
# firmware); extract them from your own device's vendor image. This script only
# reads a raw ext image with 7z, so no root and no loop mount are needed.
#
# Usage:
#   ./extract-fpc-ta.sh /path/to/vendor.raw.img [outdir]
#
# The TA lives in the vendor image under firmware/ as the split-ELF set
#   fpctzappfingerprint.mdt fpctzappfingerprint.b00 .. .b07
# Copy them to the device with:
#   scp fpctzappfingerprint.* root@<device>:/lib/firmware/
set -eu

IMG="${1:-}"
OUT="${2:-./fpc-ta}"
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "usage: $0 <vendor.raw.img> [outdir]" >&2; exit 2; }
command -v 7z >/dev/null || { echo "need 7z (p7zip)" >&2; exit 1; }

mkdir -p "$OUT"
for f in fpctzappfingerprint.mdt \
         fpctzappfingerprint.b00 fpctzappfingerprint.b01 fpctzappfingerprint.b02 \
         fpctzappfingerprint.b03 fpctzappfingerprint.b04 fpctzappfingerprint.b05 \
         fpctzappfingerprint.b06 fpctzappfingerprint.b07; do
	7z e -y -o"$OUT" "$IMG" "firmware/$f" >/dev/null
done

echo "extracted to $OUT:"
ls -l "$OUT"
sha256sum "$OUT"/*
