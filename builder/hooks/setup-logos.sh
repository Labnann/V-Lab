#!/bin/sh
set -eu

ROOTFS="${1:?Usage: setup-logos.sh ROOTFS}"
DEST="/usr/share/desktop-base/vlab-logos"

# Do nothing if the VLab logo directory does not exist.
if [ ! -d "$ROOTFS$DEST" ]; then
    echo "VLab logos not found; keeping Debian defaults."
    exit 0
fi

chroot "$ROOTFS" update-alternatives --install \
    /usr/share/images/vendor-logos \
    vendor-logos \
    "$DEST" 100

chroot "$ROOTFS" update-alternatives --set \
    vendor-logos "$DEST"

echo "VLab logos enabled."
