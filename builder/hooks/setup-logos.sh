
#!/bin/sh
set -eu

ROOTFS="${1:?Usage: setup-logos.sh ROOTFS}"
SOURCE="/usr/local/share/vlab/assets/vlab-logos"
DEST="/usr/share/desktop-base/vlab-logos"

mkdir -p "$ROOTFS$DEST"
cp -a "$SOURCE/." "$ROOTFS$DEST/"

chroot "$ROOTFS" update-alternatives --install \
    /usr/share/images/vendor-logos \
    vendor-logos \
    "$DEST" 100

chroot "$ROOTFS" update-alternatives --set \
    vendor-logos "$DEST"

echo "VLab logos enabled."

