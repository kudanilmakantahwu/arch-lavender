#!/bin/bash
# Build the Qualcomm userspace helpers needed for the modem and DIAG.
#
# These are the binaries that the base (headless) install uses:
#   qrtr-lookup  (libqrtr + tools)
#   tqftpserv    (serves /usr/lib/firmware to the modem)
#   rmtfs        (modem EFS storage)
#   pd-mapper    (protection-domain mapping, reads /usr/lib/firmware/*.jsn)
#   diag-router  (QRTR diagnostic router)
#
# Run this on the phone itself (Arch Linux ARM) as root, or in an aarch64
# chroot.  It needs: git, curl, meson, ninja, gcc/make, and the usual headers.
set -e

mkdir -p /root/qcomsrc
cd /root/qcomsrc
G=https://github.com/linux-msm

fetch() {
    [ -d "$2" ] && return 0
    curl -fL -o "$1.tar.gz" "$3"
    tar xzf "$1.tar.gz"
}

# 1) qrtr (libqrtr + tools)
fetch qrtr qrtr-1.2 "$G/qrtr/archive/refs/tags/v1.2.tar.gz"
(
    cd qrtr-1.2
    meson setup build --prefix=/usr --buildtype=release
    meson compile -C build
    meson install -C build
)

# 2) tqftpserv (serves /usr/lib/firmware to the modem)
fetch tqftpserv tqftpserv-1.2 "$G/tqftpserv/archive/refs/tags/v1.2.tar.gz"
(
    cd tqftpserv-1.2
    meson setup build --prefix=/usr --buildtype=release
    meson compile -C build
    meson install -C build
)

# 3) rmtfs (modem EFS storage)
fetch rmtfs rmtfs-1.2 "$G/rmtfs/archive/refs/tags/v1.2.tar.gz"
(
    cd rmtfs-1.2
    make prefix=/usr
    make prefix=/usr DESTDIR=/ install
)

# 4) pd-mapper (protection domain mapping)
fetch pd-mapper pd-mapper-1.1 "$G/pd-mapper/archive/refs/tags/v1.1.tar.gz"
(
    cd pd-mapper-1.1
    make prefix=/usr
    make prefix=/usr DESTDIR=/ install
)

# 5) diag-router (QRTR diagnostics)
fetch diag diag-master "$G/diag/archive/refs/heads/master.tar.gz"
(
    cd diag-master
    make
    install -Dm755 diag-router /usr/bin/diag-router
)

echo "=== installed binaries ==="
for b in qrtr-lookup rmtfs tqftpserv pd-mapper diag-router; do
    printf '%-14s ' "$b"
    command -v "$b" || echo MISSING
done