
#!/bin/sh
set -eu

ROOTFS="${1:?Usage: setup-logos.sh ROOTFS}"
SOURCE="/usr/local/share/vlab/assets/vlab-logos"
DEST="$ROOTFS/usr/share/desktop-base/debian-logos"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SOURCE/." "$DEST/"

echo "VLab logos installed as debian-logos."

