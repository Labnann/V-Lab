#!/bin/bash
set -euo pipefail

IMAGE="/output/vlab-amd64.img"
COMPRESSED="/output/vlab-amd64.img.zst"
CHECKSUMS="/output/SHA256SUMS"

IMAGE_SIZE="8G"

DEBIAN_RELEASE="trixie"
DEBIAN_MIRROR="https://deb.debian.org/debian"
DEBIAN_SECURITY="https://security.debian.org/debian-security"

WORKDIR="/var/lib/vlab-build"
ROOTFS="$WORKDIR/rootfs"
MOUNT_ROOT="$WORKDIR/mnt"
MOUNT_EFI="$MOUNT_ROOT/boot/efi"

LOOPDEV=""

cleanup() {
    echo
    echo "Cleaning up..."

    set +e

    umount "$MOUNT_ROOT/dev/pts" 2>/dev/null || true
    umount "$MOUNT_ROOT/dev" 2>/dev/null || true
    umount "$MOUNT_ROOT/proc" 2>/dev/null || true
    umount "$MOUNT_ROOT/sys" 2>/dev/null || true
    umount "$MOUNT_EFI" 2>/dev/null || true
    umount "$MOUNT_ROOT" 2>/dev/null || true

    if [[ -n "$LOOPDEV" ]]; then
        losetup -d "$LOOPDEV" 2>/dev/null || true
    fi

    rm -rf "$ROOTFS" "$MOUNT_ROOT"

    set -e
}

trap cleanup EXIT

mkdir -p "$WORKDIR"
rm -rf "$ROOTFS" "$MOUNT_ROOT"
mkdir -p "$ROOTFS" "$MOUNT_ROOT"

echo "[1/10] Creating 8G disk image..."

rm -f "$IMAGE" "$COMPRESSED" "$CHECKSUMS"

truncate -s "$IMAGE_SIZE" "$IMAGE"

parted -s "$IMAGE" \
    mklabel gpt \
    mkpart BIOS 1MiB 3MiB \
    set 1 bios_grub on \
    mkpart EFI fat32 3MiB 515MiB \
    set 2 esp on \
    mkpart ROOT ext4 515MiB 100%

parted "$IMAGE" unit MiB print

echo "[2/10] Attaching loop device..."

LOOPDEV="$(losetup --find --show --partscan "$IMAGE")"

echo "Loop device: $LOOPDEV"

for _ in {1..50}; do
    if [[ -b "${LOOPDEV}p1" &&
          -b "${LOOPDEV}p2" &&
          -b "${LOOPDEV}p3" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -b "${LOOPDEV}p1" ||
      ! -b "${LOOPDEV}p2" ||
      ! -b "${LOOPDEV}p3" ]]; then
    echo "ERROR: loop partition devices did not appear."
    exit 1
fi

BIOS_PART="${LOOPDEV}p1"
EFI_PART="${LOOPDEV}p2"
ROOT_PART="${LOOPDEV}p3"

echo "BIOS partition: $BIOS_PART"
echo "EFI partition:  $EFI_PART"
echo "ROOT partition: $ROOT_PART"

echo "[3/10] Creating EFI filesystem..."

mkfs.vfat -F 32 "$EFI_PART"

echo "[4/10] Creating ext4 root filesystem..."

mkfs.ext4 -F "$ROOT_PART"

echo "[5/10] Mounting root filesystem..."

mount "$ROOT_PART" "$MOUNT_ROOT"

mkdir -p "$MOUNT_EFI"

echo "[6/10] Mounting EFI filesystem..."

mount "$EFI_PART" "$MOUNT_EFI"

echo "[7/10] Installing Debian base system..."

DEBOOTSTRAP_CACHE="/cache/debootstrap-${DEBIAN_RELEASE}-amd64-minbase"

if [ ! -f "$DEBOOTSTRAP_CACHE/.debootstrap-done" ]; then
    mkdir -p "$DEBOOTSTRAP_CACHE"

    debootstrap \
        --arch=amd64 \
        --variant=minbase \
        "$DEBIAN_RELEASE" \
        "$DEBOOTSTRAP_CACHE" \
        "$DEBIAN_MIRROR"

    touch "$DEBOOTSTRAP_CACHE/.debootstrap-done"
fi

cp -a "$DEBOOTSTRAP_CACHE/." "$ROOTFS/"

echo "[8/10] Configuring Debian..."

rsync -aHAX "$ROOTFS/" "$MOUNT_ROOT/"

mkdir -p \
    "$MOUNT_ROOT/dev/pts" \
    "$MOUNT_ROOT/proc" \
    "$MOUNT_ROOT/sys" \
    "$MOUNT_ROOT/run"

mount --bind /dev "$MOUNT_ROOT/dev"
mount --bind /dev/pts "$MOUNT_ROOT/dev/pts"
mount -t proc proc "$MOUNT_ROOT/proc"
mount -t sysfs sysfs "$MOUNT_ROOT/sys"

cp -L /etc/resolv.conf "$MOUNT_ROOT/etc/resolv.conf"

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"

cat > "$MOUNT_ROOT/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot/efi vfat umask=0077 0 1
EOF

cat > "$MOUNT_ROOT/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free non-free-firmware
deb $DEBIAN_SECURITY $DEBIAN_RELEASE-security main contrib non-free non-free-firmware
EOF

chroot "$MOUNT_ROOT" /bin/bash <<'CHROOT'
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    linux-image-amd64 \
    linux-headers-amd64 \
    systemd \
    systemd-sysv \
    dbus \
    sudo \
    network-manager \
    firmware-linux \
    firmware-linux-free \
    firmware-linux-nonfree \
    firmware-iwlwifi \
    firmware-realtek \
    firmware-atheros \
    firmware-brcm80211 \
    firmware-mediatek \
    firmware-libertas \
    firmware-misc-nonfree \
    grub-efi-amd64 \
    grub2-common \
    efibootmgr \
    task-gnome-desktop \
    gnome-terminal \
    gcc \
    g++ \
    make \
    gdb \
    binutils \
    cmake \
    pkg-config \
    git \
    vim \
    nano \
    tmux \
    strace \
    ltrace \
    python3 \
    python3-pip \
    nasm \
    qemu-system-x86 \
    qemu-utils \
    cloud-guest-utils

echo "vlab" > /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 vlab

::1 localhost ip6-localhost ip6-loopback
EOF

systemctl enable NetworkManager
systemctl enable gdm

useradd -m -s /bin/bash -G sudo student

cat > /etc/sudoers.d/student <<EOF
student ALL=(ALL) NOPASSWD:ALL
EOF

chmod 440 /etc/sudoers.d/student

cat > /usr/local/sbin/vlab-grow-root <<'EOF'
#!/bin/bash
set -e

ROOT_DEV="$(findmnt -n -o SOURCE /)"

growpart "$ROOT_DEV" 3 || true
resize2fs "$ROOT_DEV" || true
EOF

chmod +x /usr/local/sbin/vlab-grow-root

cat > /etc/systemd/system/vlab-grow-root.service <<EOF
[Unit]
Description=Grow VLab root filesystem
After=local-fs.target
Before=getty.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vlab-grow-root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable vlab-grow-root.service

cat > /usr/local/sbin/vlab-firstboot <<'EOF'
#!/bin/bash

if [[ -f /var/lib/vlab/initialized ]]; then
    exit 0
fi

echo
echo "======================================"
echo " VLab first boot"
echo " Set the password for user: student"
echo "======================================"
echo

passwd student

mkdir -p /var/lib/vlab
touch /var/lib/vlab/initialized

systemctl disable vlab-firstboot.service
EOF

chmod +x /usr/local/sbin/vlab-firstboot

cat > /etc/systemd/system/vlab-firstboot.service <<EOF
[Unit]
Description=VLab first boot password setup
After=network.target
Before=gdm.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vlab-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable vlab-firstboot.service

systemctl disable apt-daily.timer || true
systemctl disable apt-daily-upgrade.timer || true

rm -f /etc/machine-id
touch /etc/machine-id

apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

echo "[9/10] Installing GRUB..."

grub-install \
    --target=i386-pc \
    --boot-directory="$MOUNT_ROOT/boot" \
    --recheck \
    "$LOOPDEV"

grub-install \
    --target=x86_64-efi \
    --efi-directory="$MOUNT_EFI" \
    --boot-directory="$MOUNT_ROOT/boot" \
    --bootloader-id=VLab \
    --removable \
    --recheck

chroot "$MOUNT_ROOT" update-grub

echo "[10/10] Finalizing..."

sync

umount "$MOUNT_ROOT/dev/pts"
umount "$MOUNT_ROOT/dev"
umount "$MOUNT_ROOT/proc"
umount "$MOUNT_ROOT/sys"
umount "$MOUNT_EFI"
umount "$MOUNT_ROOT"

losetup -d "$LOOPDEV"
LOOPDEV=""


echo
echo "======================================"
echo " VLab image created successfully"
echo "======================================"
echo
echo "Raw image:      $IMAGE"
echo

ls -lh \
    "$IMAGE" 
