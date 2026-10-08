#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VLab image builder
#
# Produces:
#
#   /output/vlab-amd64.img
#   /output/vlab-amd64.img.zst
#   /output/SHA256SUMS
#
# The resulting image:
#
#   - boots using UEFI
#   - boots using legacy BIOS
#   - has a writable ext4 root filesystem
#   - automatically expands root on first boot
#   - contains Debian GNOME
#   - contains OS laboratory development tools
#
# ============================================================

IMAGE="/output/vlab-amd64.img"
IMAGE_SIZE="8G"

DEBIAN_SUITE="trixie"
DEBIAN_MIRROR="https://deb.debian.org/debian"
DEBIAN_SECURITY="https://security.debian.org/debian-security"

WORKDIR="/var/lib/vlab-build"

ROOTFS="$WORKDIR/rootfs"
MOUNT_ROOT="$WORKDIR/mnt"
MOUNT_EFI="$MOUNT_ROOT/boot/efi"

LOOPDEV=""

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

cleanup() {
    set +e

    echo
    echo "Cleaning up..."

    if mountpoint -q "$ROOTFS/dev/pts"; then
        umount "$ROOTFS/dev/pts"
    fi

    if mountpoint -q "$ROOTFS/dev"; then
        umount "$ROOTFS/dev"
    fi

    if mountpoint -q "$ROOTFS/proc"; then
        umount "$ROOTFS/proc"
    fi

    if mountpoint -q "$ROOTFS/sys"; then
        umount "$ROOTFS/sys"
    fi

    if mountpoint -q "$MOUNT_EFI"; then
        umount "$MOUNT_EFI"
    fi

    if mountpoint -q "$MOUNT_ROOT"; then
        umount "$MOUNT_ROOT"
    fi

    if [[ -n "$LOOPDEV" ]]; then
        losetup -d "$LOOPDEV" 2>/dev/null || true
    fi

    rm -rf "$WORKDIR"
}

trap cleanup EXIT

# ------------------------------------------------------------
# Prepare workspace
# ------------------------------------------------------------

rm -rf "$WORKDIR"

mkdir -p "$ROOTFS"
mkdir -p "$MOUNT_ROOT"

rm -f "$IMAGE"
rm -f "$IMAGE.zst"
rm -f "/output/SHA256SUMS"

# ------------------------------------------------------------
# Create image
# ------------------------------------------------------------

echo
echo "[1/10] Creating disk image..."

truncate -s "$IMAGE_SIZE" "$IMAGE"

# ------------------------------------------------------------
# Partition image
# ------------------------------------------------------------

echo
echo "[2/10] Creating partition table..."

#
# Layout:
#
# 1 MiB - 3 MiB       BIOS boot partition
# 3 MiB - 515 MiB     EFI System Partition
# 515 MiB - end       root
#

parted -s "$IMAGE" \
    mklabel gpt \
    mkpart BIOS 1MiB 3MiB \
    set 1 bios_grub on \
    mkpart ESP fat32 3MiB 515MiB \
    set 2 esp on \
    mkpart root ext4 515MiB 100%

# ------------------------------------------------------------
# Attach image
# ------------------------------------------------------------

echo
echo "[3/10] Attaching image..."

LOOPDEV=$(losetup --find --show --partscan "$IMAGE")

echo "Loop device: $LOOPDEV"

sleep 1

BIOS_PART="${LOOPDEV}p1"
EFI_PART="${LOOPDEV}p2"
ROOT_PART="${LOOPDEV}p3"

# ------------------------------------------------------------
# Format filesystems
# ------------------------------------------------------------

echo
echo "[4/10] Formatting filesystems..."

mkfs.vfat \
    -F32 \
    -n VLAB_EFI \
    "$EFI_PART"

mkfs.ext4 \
    -F \
    -L VLAB_ROOT \
    "$ROOT_PART"

# ------------------------------------------------------------
# Mount root
# ------------------------------------------------------------

mount "$ROOT_PART" "$MOUNT_ROOT"

mkdir -p "$MOUNT_EFI"

mount "$EFI_PART" "$MOUNT_EFI"

# ------------------------------------------------------------
# Bootstrap Debian
# ------------------------------------------------------------

echo
echo "[5/10] Bootstrapping Debian $DEBIAN_SUITE..."

debootstrap \
    --arch=amd64 \
    "$DEBIAN_SUITE" \
    "$ROOTFS" \
    "$DEBIAN_MIRROR"

# ------------------------------------------------------------
# Configure APT
# ------------------------------------------------------------

echo
echo "[6/10] Configuring Debian..."

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main contrib non-free non-free-firmware
deb $DEBIAN_SECURITY $DEBIAN_SUITE-security main contrib non-free non-free-firmware
EOF

# ------------------------------------------------------------
# Mount pseudo-filesystems
# ------------------------------------------------------------

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"

mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"

# ------------------------------------------------------------
# Get UUIDs outside chroot
# ------------------------------------------------------------

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"

echo "Root UUID: $ROOT_UUID"
echo "EFI UUID:  $EFI_UUID"

# ------------------------------------------------------------
# Write fstab
# ------------------------------------------------------------

cat > "$ROOTFS/etc/fstab" <<EOF
# VLab filesystem table

UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot/efi vfat umask=0077 0 1
EOF

# ------------------------------------------------------------
# Chroot installation
# ------------------------------------------------------------

cat > "$ROOTFS/root/vlab-install.sh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "Installing VLab packages..."

apt-get update

apt-get install -y \
    linux-image-amd64 \
    linux-headers-amd64 \
    systemd \
    systemd-sysv \
    dbus \
    sudo \
    network-manager \
    \
    firmware-linux \
    firmware-linux-free \
    firmware-iwlwifi \
    firmware-realtek \
    firmware-atheros \
    firmware-brcm80211 \
    firmware-mediatek \
    \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    grub-pc \
    grub-pc-bin \
    grub2-common \
    \
    efibootmgr \
    \
    task-gnome-desktop \
    gnome-terminal \
    \
    gcc \
    g++ \
    make \
    gdb \
    binutils \
    \
    cmake \
    pkg-config \
    git \
    \
    vim \
    nano \
    tmux \
    \
    strace \
    ltrace \
    \
    python3 \
    python3-pip \
    \
    nasm \
    \
    qemu-system-x86 \
    qemu-utils

# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

echo "vlab" > /etc/hostname

cat > /etc/hosts <<'HOSTS'
127.0.0.1       localhost
127.0.1.1       vlab

::1             localhost ip6-localhost ip6-loopback
HOSTS

# ------------------------------------------------------------
# Network
# ------------------------------------------------------------

systemctl enable NetworkManager

# ------------------------------------------------------------
# GNOME
# ------------------------------------------------------------

systemctl enable gdm

# ------------------------------------------------------------
# Student account
# ------------------------------------------------------------

useradd \
    --create-home \
    --shell /bin/bash \
    --groups sudo \
    student

#
# Don't configure a permanent password here.
#
# First boot will ask the student to configure one.
#

# ------------------------------------------------------------
# Sudo
# ------------------------------------------------------------

cat > /etc/sudoers.d/vlab <<'SUDO'
%sudo ALL=(ALL:ALL) NOPASSWD: ALL
SUDO

chmod 440 /etc/sudoers.d/vlab

# ------------------------------------------------------------
# First-boot root filesystem expansion
# ------------------------------------------------------------

cat > /usr/local/sbin/vlab-grow-root <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

ROOT_DEVICE="$(findmnt -n -o SOURCE /)"

#
# Resolve partition device.
#
ROOT_DEVICE="$(readlink -f "$ROOT_DEVICE")"

#
# Only operate on a partition.
#
if [[ "$ROOT_DEVICE" != /dev/*[0-9] ]]; then
    exit 0
fi

#
# Grow partition to the end of the disk.
#
growpart \
    "$(lsblk -no PKNAME "$ROOT_DEVICE" | head -n1 | sed 's/^/\/dev\//')" \
    "$(lsblk -no PARTN "$ROOT_DEVICE")"

#
# Grow ext4 filesystem.
#
resize2fs "$ROOT_DEVICE"
SCRIPT

chmod +x /usr/local/sbin/vlab-grow-root

#
# Install growpart.
#
apt-get install -y cloud-guest-utils

# ------------------------------------------------------------
# First boot service
# ------------------------------------------------------------

cat > /etc/systemd/system/vlab-grow-root.service <<'UNIT'
[Unit]
Description=Expand VLab root filesystem
After=local-fs.target
Before=getty.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vlab-grow-root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable vlab-grow-root.service

# ------------------------------------------------------------
# First boot password setup
# ------------------------------------------------------------

cat > /etc/systemd/system/vlab-firstboot.service <<'UNIT'
[Unit]
Description=VLab first boot initialization
After=network-pre.target
Before=getty.target
ConditionPathExists=!/var/lib/vlab/initialized

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vlab-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /var/lib/vlab

cat > /usr/local/sbin/vlab-firstboot <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

mkdir -p /var/lib/vlab

echo
echo "=============================================="
echo "Welcome to VLab"
echo "=============================================="
echo
echo "Set a password for the student account."
echo

passwd student

touch /var/lib/vlab/initialized
SCRIPT

chmod +x /usr/local/sbin/vlab-firstboot

systemctl enable vlab-firstboot.service

# ------------------------------------------------------------
# Disable unnecessary services
# ------------------------------------------------------------

systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true

# ------------------------------------------------------------
# Machine identity
# ------------------------------------------------------------

rm -f /etc/machine-id

# systemd will generate it on first boot.
touch /etc/machine-id

# ------------------------------------------------------------
# Clean package cache
# ------------------------------------------------------------

apt-get clean

rm -rf /var/lib/apt/lists/*

echo
echo "Debian installation complete."
EOF

chmod +x "$ROOTFS/root/vlab-install.sh"

chroot "$ROOTFS" /root/vlab-install.sh

rm "$ROOTFS/root/vlab-install.sh"

# ------------------------------------------------------------
# Install GRUB
# ------------------------------------------------------------

echo
echo "[7/10] Installing bootloaders..."

#
# Legacy BIOS GRUB.
#
chroot "$ROOTFS" \
    grub-install \
        --target=i386-pc \
        --recheck \
        /dev/loop0 2>/dev/null || true

#
# The loop device inside the container may not necessarily
# appear as /dev/loop0 in the chroot environment, so install
# BIOS GRUB from the builder environment as well.
#

grub-install \
    --target=i386-pc \
    --boot-directory="$ROOTFS/boot" \
    --recheck \
    "$LOOPDEV"

#
# UEFI GRUB.
#
grub-install \
    --target=x86_64-efi \
    --efi-directory="$MOUNT_EFI" \
    --boot-directory="$ROOTFS/boot" \
    --bootloader-id=VLab \
    --removable \
    --recheck

# ------------------------------------------------------------
# GRUB configuration
# ------------------------------------------------------------

chroot "$ROOTFS" update-grub

# ------------------------------------------------------------
# Cleanup mounts
# ------------------------------------------------------------

echo
echo "[8/10] Unmounting..."

umount "$ROOTFS/dev/pts"
umount "$ROOTFS/dev"
umount "$ROOTFS/proc"
umount "$ROOTFS/sys"

sync

umount "$MOUNT_EFI"
umount "$MOUNT_ROOT"

# ------------------------------------------------------------
# Detach image
# ------------------------------------------------------------

echo
echo "[9/10] Detaching image..."

losetup -d "$LOOPDEV"
LOOPDEV=""

sync

# ------------------------------------------------------------
# Compress
# ------------------------------------------------------------

echo
echo "[10/10] Compressing image..."

zstd \
    --threads=0 \
    --ultra \
    -22 \
    "$IMAGE" \
    -o "$IMAGE.zst"

sha256sum \
    "$IMAGE.zst" \
    > /output/SHA256SUMS

echo
echo "=============================================="
echo "VLab image created successfully"
echo "=============================================="
echo
echo "Raw image:"
echo
echo "  $IMAGE"
echo
echo "Compressed image:"
echo
echo "  $IMAGE.zst"
echo
echo "Checksum:"
echo
echo "  /output/SHA256SUMS"
echo
