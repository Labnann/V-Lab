#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VLab image builder
#
# Builds the complete bootable disk image using regular files
# only. No loop devices, host /dev, mounts, QEMU, KVM, or
# privileged container features are required.
# ============================================================

IMAGE_NAME="vlab-amd64.img"
IMAGE_SIZE_BYTES=$((8 * 1024 * 1024 * 1024))
IMAGE_SIZE_LABEL="8G"

DEBIAN_SUITE="trixie"
DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_SECURITY="http://deb.debian.org/debian-security"
DEBIAN_COMPONENTS_DEBOOTSTRAP="main,contrib,non-free,non-free-firmware"
DEBIAN_COMPONENTS_APT="main contrib non-free non-free-firmware"

OUTPUT_DIR="/output"
WORKDIR="/var/lib/vlab-build"
ROOTFS="$WORKDIR/rootfs"
ROOT_IMAGE="$WORKDIR/root.img"
EFI_IMAGE="$WORKDIR/efi.img"
EFI_GRUB="$WORKDIR/BOOTX64.EFI"
GRUB_CFG="$WORKDIR/grub.cfg"
BIOS_GRUB_DIR="$WORKDIR/bios-grub"

IMAGE="$OUTPUT_DIR/$IMAGE_NAME"
IMAGE_ZST="$OUTPUT_DIR/$IMAGE_NAME.zst"
CHECKSUMS="$OUTPUT_DIR/SHA256SUMS"

SECTOR_SIZE=512
BIOS_START=2048
BIOS_SIZE=4096                  # 2 MiB
EFI_START=6144
EFI_SIZE=1048576                # 512 MiB
ROOT_START=1054720

BIOS_PART_TYPE="21686148-6449-6E6F-744E-656564454649"
EFI_PART_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
ROOT_PART_TYPE="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

for cmd in \
    debootstrap chroot truncate stat dd python3 \
    mke2fs e2fsck mkfs.vfat fsck.fat \
    mcopy mmd grub-mkimage grub-mkstandalone \
    grub-file zstd uuidgen sha256sum blkid; do
    require_command "$cmd"
done

GRUB_BIOS_SETUP="/usr/lib/grub/i386-pc/grub-bios-setup"
[[ -x "$GRUB_BIOS_SETUP" ]] || fail "Required GRUB BIOS helper not found: $GRUB_BIOS_SETUP"

[[ "$(dpkg --print-architecture)" == "amd64" ]] || \
    fail "The builder must run as an amd64 Debian container because the target image is amd64."

mkdir -p "$OUTPUT_DIR"
rm -f "$IMAGE" "$IMAGE_ZST" "$CHECKSUMS"
rm -rf "$WORKDIR"
mkdir -p "$ROOTFS" "$BIOS_GRUB_DIR"

log "[1/10] Creating empty ${IMAGE_SIZE_LABEL} disk image..."
truncate -s "$IMAGE_SIZE_BYTES" "$IMAGE"

IMAGE_SECTORS=$((IMAGE_SIZE_BYTES / SECTOR_SIZE))
GPT_LAST_USABLE=$((IMAGE_SECTORS - 34))

(( ROOT_START < GPT_LAST_USABLE )) || fail "Image is too small for the selected partition layout."

log "[2/10] Writing GPT partition table directly into the image..."
# The image layout is fixed, so no partitioning utility or kernel block-device
# interface is necessary. Python writes the protective MBR, GPT header, and
# partition-entry arrays directly into the regular image file.
BIOS_GUID="$(uuidgen)"
EFI_GUID="$(uuidgen)"
ROOT_GUID="$(uuidgen)"
DISK_GUID="$(uuidgen)"

python3 - "$IMAGE" "$IMAGE_SECTORS" "$BIOS_START" "$BIOS_SIZE" "$EFI_START" "$EFI_SIZE" "$ROOT_START" "$GPT_LAST_USABLE" "$BIOS_PART_TYPE" "$EFI_PART_TYPE" "$ROOT_PART_TYPE" "$BIOS_GUID" "$EFI_GUID" "$ROOT_GUID" "$DISK_GUID" <<'PY'
import struct, sys, uuid, zlib

(
    image, total_sectors, bios_start, bios_size, efi_start, efi_size,
    root_start, last_usable, bios_type, efi_type, root_type,
    bios_guid, efi_guid, root_guid, disk_guid,
) = sys.argv[1:]

total_sectors = int(total_sectors)
bios_start = int(bios_start)
bios_size = int(bios_size)
efi_start = int(efi_start)
efi_size = int(efi_size)
root_start = int(root_start)
last_usable = int(last_usable)
SECTOR = 512
ENTRY_SIZE = 128
ENTRY_COUNT = 128
ENTRY_BYTES = ENTRY_SIZE * ENTRY_COUNT
GPT_ENTRIES_LBA = 2
BACKUP_ENTRIES_LBA = total_sectors - 33
BACKUP_HEADER_LBA = total_sectors - 1

def guid_bytes(s):
    u = uuid.UUID(s)
    return struct.pack('<IHH', u.time_low, u.time_mid, u.time_hi_version) + u.bytes[8:]

def entry(type_guid, part_guid, first, last, name):
    e = bytearray(ENTRY_SIZE)
    e[0:16] = guid_bytes(type_guid)
    e[16:32] = guid_bytes(part_guid)
    struct.pack_into('<QQQ', e, 32, first, last, 0)
    encoded = name.encode('utf-16le')
    e[56:56 + len(encoded)] = encoded
    return bytes(e)

entries = bytearray(ENTRY_BYTES)
for i, args in enumerate([
    (bios_type, bios_guid, bios_start, bios_start + bios_size - 1, 'BIOS'),
    (efi_type, efi_guid, efi_start, efi_start + efi_size - 1, 'EFI'),
    (root_type, root_guid, root_start, last_usable, 'VLabRoot'),
]):
    entries[i * ENTRY_SIZE:(i + 1) * ENTRY_SIZE] = entry(*args)

entries_crc = zlib.crc32(entries) & 0xffffffff

def gpt_header(current_lba, backup_lba, entries_lba):
    h = bytearray(SECTOR)
    h[0:8] = b'EFI PART'
    struct.pack_into('<I', h, 8, 0x00010000)
    struct.pack_into('<I', h, 12, 92)
    struct.pack_into('<I', h, 16, 0)
    struct.pack_into('<I', h, 20, 0)
    struct.pack_into('<QQQQ', h, 24, current_lba, backup_lba, 34, last_usable)
    h[56:72] = guid_bytes(disk_guid)
    struct.pack_into('<Q', h, 72, entries_lba)
    struct.pack_into('<I', h, 80, ENTRY_COUNT)
    struct.pack_into('<I', h, 84, ENTRY_SIZE)
    struct.pack_into('<I', h, 88, entries_crc)
    crc = zlib.crc32(h[:92]) & 0xffffffff
    struct.pack_into('<I', h, 16, crc)
    return bytes(h)

mbr = bytearray(SECTOR)
# Protective MBR partition: starts at LBA 1 and covers the image (clamped to
# the MBR's 32-bit sector-count field).
mbr[446:454] = bytes([0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF])
struct.pack_into('<I', mbr, 454, 1)
struct.pack_into('<I', mbr, 458, min(total_sectors - 1, 0xffffffff))
mbr[510:512] = b'\x55\xaa'

primary = gpt_header(1, BACKUP_HEADER_LBA, GPT_ENTRIES_LBA)
backup = gpt_header(BACKUP_HEADER_LBA, 1, BACKUP_ENTRIES_LBA)

with open(image, 'r+b') as f:
    f.seek(0)
    f.write(mbr)
    f.seek(GPT_ENTRIES_LBA * SECTOR)
    f.write(entries)
    f.seek(SECTOR)
    f.write(primary)
    f.seek(BACKUP_ENTRIES_LBA * SECTOR)
    f.write(entries)
    f.seek(BACKUP_HEADER_LBA * SECTOR)
    f.write(backup)
PY

ROOT_SECTORS=$((GPT_LAST_USABLE - ROOT_START + 1))
ROOT_BYTES=$((ROOT_SECTORS * SECTOR_SIZE))
EFI_BYTES=$((EFI_SIZE * SECTOR_SIZE))

(( ROOT_BYTES > 1024 * 1024 * 1024 )) || fail "Root partition is unexpectedly small."

log "Partition layout:"
printf '  BIOS:  sectors %d-%d\n' "$BIOS_START" "$((BIOS_START + BIOS_SIZE - 1))"
printf '  EFI:   sectors %d-%d\n' "$EFI_START" "$((EFI_START + EFI_SIZE - 1))"
printf '  ROOT:  sectors %d-%d\n' "$ROOT_START" "$GPT_LAST_USABLE"

log "[3/10] Bootstrapping Debian ${DEBIAN_SUITE} root filesystem..."
debootstrap \
    --arch=amd64 \
    --components="$DEBIAN_COMPONENTS_DEBOOTSTRAP" \
    --variant=minbase \
    "$DEBIAN_SUITE" \
    "$ROOTFS" \
    "$DEBIAN_MIRROR"

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
# Debian ${DEBIAN_SUITE}
deb ${DEBIAN_MIRROR} ${DEBIAN_SUITE} ${DEBIAN_COMPONENTS_APT}
deb ${DEBIAN_MIRROR} ${DEBIAN_SUITE}-updates ${DEBIAN_COMPONENTS_APT}
deb ${DEBIAN_SECURITY} ${DEBIAN_SUITE}-security ${DEBIAN_COMPONENTS_APT}
EOF

# Give chrooted apt a resolver without mounting anything from the host.
rm -f "$ROOTFS/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

printf 'vlab\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1       localhost
127.0.1.1       vlab
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Prevent daemon start attempts while packages are being installed in chroot.
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"

log "[4/10] Installing the VLab desktop and development environment..."
chroot "$ROOTFS" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C \
    apt-get update

chroot "$ROOTFS" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C \
    apt-get install -y \
        linux-image-amd64 \
        linux-headers-amd64 \
        systemd \
        systemd-sysv \
        dbus \
        sudo \
        network-manager \
        udev \
        firmware-linux-free \
        firmware-misc-nonfree \
        grub2-common \
        grub-pc-bin \
        grub-efi-amd64-bin \
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
        cloud-guest-utils \
        gdisk \
        ca-certificates

rm -f "$ROOTFS/usr/sbin/policy-rc.d"

log "[5/10] Configuring the installed system..."

# NetworkManager will provide the runtime resolver configuration.
rm -f "$ROOTFS/etc/resolv.conf"
ln -s /run/NetworkManager/resolv.conf "$ROOTFS/etc/resolv.conf"

# Student account: first boot asks for its permanent password.
chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo student
chroot "$ROOTFS" passwd -l student >/dev/null

cat > "$ROOTFS/etc/sudoers.d/vlab-student" <<'EOF'
student ALL=(ALL:ALL) NOPASSWD:ALL
EOF
chmod 440 "$ROOTFS/etc/sudoers.d/vlab-student"

mkdir -p "$ROOTFS/var/lib/vlab"

# Grow the root partition/filesystem when the image is written to a larger disk.
cat > "$ROOTFS/usr/local/sbin/vlab-grow-root" <<'EOF'
#!/bin/sh
set -eu

ROOT_DEVICE="$(findmnt -n -o SOURCE /)"
ROOT_PARENT="$(lsblk -no PKNAME "$ROOT_DEVICE")"
ROOT_PART="$(lsblk -no PARTN "$ROOT_DEVICE")"

[ -n "$ROOT_PARENT" ] || exit 0
[ -n "$ROOT_PART" ] || exit 0

ROOT_DISK="/dev/$ROOT_PARENT"

# A raw image written to a larger disk still carries its old GPT backup header.
# Relocate that backup header before enlarging the root partition.
if command -v sgdisk >/dev/null 2>&1; then
    sgdisk -e "$ROOT_DISK" >/dev/null 2>&1 || true
fi

set +e
growpart "$ROOT_DISK" "$ROOT_PART" >/tmp/vlab-growpart.log 2>&1
RC=$?
set -e

# growpart returns 1 for the normal "NOCHANGE" case.
if [ "$RC" -ne 0 ] && [ "$RC" -ne 1 ]; then
    cat /tmp/vlab-growpart.log >&2
    exit "$RC"
fi

resize2fs "$ROOT_DEVICE"
touch /var/lib/vlab/root-grown
rm -f /tmp/vlab-growpart.log
EOF
chmod 755 "$ROOTFS/usr/local/sbin/vlab-grow-root"

cat > "$ROOTFS/etc/systemd/system/vlab-grow-root.service" <<'EOF'
[Unit]
Description=Expand VLab root partition and filesystem on first boot
After=local-fs.target
Before=display-manager.service
ConditionPathExists=!/var/lib/vlab/root-grown

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vlab-grow-root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Ask for the student's password interactively on the first boot.
cat > "$ROOTFS/usr/local/sbin/vlab-firstboot" <<'EOF'
#!/bin/sh
set -eu

echo
printf '%s\n' 'VLab first boot setup'
printf '%s\n' 'Set a password for the student account.'
echo
passwd student

touch /var/lib/vlab/initialized
EOF
chmod 755 "$ROOTFS/usr/local/sbin/vlab-firstboot"

cat > "$ROOTFS/etc/systemd/system/vlab-firstboot.service" <<'EOF'
[Unit]
Description=VLab first boot student password setup
After=local-fs.target vlab-grow-root.service
Before=display-manager.service getty@tty1.service
ConditionPathExists=!/var/lib/vlab/initialized

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vlab-firstboot
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable expected services without trying to contact a running systemd daemon.
chroot "$ROOTFS" systemctl enable NetworkManager.service
chroot "$ROOTFS" systemctl enable gdm3.service
chroot "$ROOTFS" systemctl enable vlab-grow-root.service
chroot "$ROOTFS" systemctl enable vlab-firstboot.service
chroot "$ROOTFS" systemctl set-default graphical.target

# Keep first boot from immediately running Debian's apt timers.
chroot "$ROOTFS" systemctl disable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

cat > "$ROOTFS/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="VLab"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
EOF

# Give systemd a fresh machine-id on first real boot.
rm -f "$ROOTFS/etc/machine-id"
touch "$ROOTFS/etc/machine-id"

# Clean apt metadata but retain installed packages.
chroot "$ROOTFS" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C \
    apt-get clean
rm -rf "$ROOTFS/var/lib/apt/lists"/*

log "[6/10] Preparing GRUB configuration and BIOS modules..."
ROOT_UUID="$(uuidgen)"

cat > "$GRUB_CFG" <<EOF
set default=0
set timeout=5

menuentry 'VLab Debian ${DEBIAN_SUITE}' {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /vmlinuz root=UUID=${ROOT_UUID} ro quiet
    initrd /initrd.img
}
EOF

mkdir -p "$ROOTFS/boot/grub"
cp -a /usr/lib/grub/i386-pc "$ROOTFS/boot/grub/"
cp "$GRUB_CFG" "$ROOTFS/boot/grub/grub.cfg"

# GRUB's BIOS loader starts in the BIOS Boot Partition and then reads the
# modules/configuration from the ext4 root partition.
grub-mkimage \
    -O i386-pc \
    -d /usr/lib/grub/i386-pc \
    -o "$BIOS_GRUB_DIR/core.img" \
    -p '(hd0,gpt3)/boot/grub' \
    biosdisk part_gpt ext2 normal linux search search_fs_uuid configfile

cp /usr/lib/grub/i386-pc/boot.img "$BIOS_GRUB_DIR/boot.img"

cat > "$BIOS_GRUB_DIR/device.map" <<EOF
(hd0) $IMAGE
EOF

# grub-bios-setup is pointed at the regular disk image through device.map.
# GNU Guix uses the same disk-image approach for BIOS GRUB installation.
log "Installing BIOS GRUB directly into the image file..."
"$GRUB_BIOS_SETUP" \
    -m "$BIOS_GRUB_DIR/device.map" \
    -r '(hd0,gpt3)' \
    -d "$BIOS_GRUB_DIR" \
    --skip-fs-probe \
    "$IMAGE"

log "[7/10] Building the EFI System Partition as a FAT image..."
truncate -s "$EFI_BYTES" "$EFI_IMAGE"
mkfs.vfat -F 32 -n VLAB_EFI "$EFI_IMAGE" >/dev/null

mmd -i "$EFI_IMAGE" ::/EFI
mmd -i "$EFI_IMAGE" ::/EFI/BOOT

grub-mkstandalone \
    -O x86_64-efi \
    -o "$EFI_GRUB" \
    --disable-shim-lock \
    "boot/grub/grub.cfg=$GRUB_CFG"

mcopy -i "$EFI_IMAGE" "$EFI_GRUB" ::/EFI/BOOT/BOOTX64.EFI

log "[8/10] Creating and populating ext4 root filesystem image..."

mkdir -p "$ROOTFS/boot/efi"

# Read the FAT UUID and finalize fstab inside the tree.
EFI_UUID_ACTUAL="$(blkid -s UUID -o value "$EFI_IMAGE")"

cat > "$ROOTFS/etc/fstab" <<EOF
# VLab filesystems
UUID=${ROOT_UUID}       /           ext4  defaults  0 1
UUID=${EFI_UUID_ACTUAL} /boot/efi   vfat  umask=0077  0 2
EOF

# Recreate ext4 after final fstab configuration is present.
mke2fs \
    -t ext4 \
    -F \
    -U "$ROOT_UUID" \
    -L VLAB_ROOT \
    -d "$ROOTFS" \
    "$ROOT_IMAGE" >/tmp/vlab-mke2fs-final.log 2>&1

log "[9/10] Writing filesystem images into their GPT partitions..."
dd if="$EFI_IMAGE" \
    of="$IMAGE" \
    bs="$SECTOR_SIZE" \
    seek="$EFI_START" \
    conv=notrunc status=progress

dd if="$ROOT_IMAGE" \
    of="$IMAGE" \
    bs="$SECTOR_SIZE" \
    seek="$ROOT_START" \
    conv=notrunc status=progress

sync

log "[10/10] Verifying the generated image..."

e2fsck -fn "$ROOT_IMAGE" >/tmp/vlab-e2fsck.log 2>&1 || {
    cat /tmp/vlab-e2fsck.log >&2
    fail "ext4 filesystem verification failed."
}

fsck.fat -vn "$EFI_IMAGE" >/tmp/vlab-fsckfat.log 2>&1 || {
    cat /tmp/vlab-fsckfat.log >&2
    fail "EFI FAT filesystem verification failed."
}

grub-file --is-x86_64-efi "$EFI_GRUB"

python3 - "$IMAGE" "$IMAGE_SECTORS" "$BIOS_START" "$BIOS_SIZE" "$EFI_START" "$EFI_SIZE" "$ROOT_START" "$GPT_LAST_USABLE" <<'PY'
import struct, sys, zlib
image = sys.argv[1]
total = int(sys.argv[2])
bios_start, bios_size = int(sys.argv[3]), int(sys.argv[4])
efi_start, efi_size = int(sys.argv[5]), int(sys.argv[6])
root_start, last_usable = int(sys.argv[7]), int(sys.argv[8])
SECTOR = 512
ENTRY_SIZE = 128
ENTRY_COUNT = 128
with open(image, 'rb') as f:
    f.seek(SECTOR)
    h = f.read(SECTOR)
    if h[:8] != b'EFI PART': raise SystemExit('GPT signature missing')
    header_size = struct.unpack_from('<I', h, 12)[0]
    stored_crc = struct.unpack_from('<I', h, 16)[0]
    chk = bytearray(h[:header_size])
    struct.pack_into('<I', chk, 16, 0)
    if (zlib.crc32(chk) & 0xffffffff) != stored_crc: raise SystemExit('GPT header CRC mismatch')
    current, backup, first, last = struct.unpack_from('<QQQQ', h, 24)
    entries_lba = struct.unpack_from('<Q', h, 72)[0]
    count, size = struct.unpack_from('<II', h, 80)
    if current != 1 or backup != total - 1 or first != 34 or last != last_usable: raise SystemExit('GPT geometry mismatch')
    if count != ENTRY_COUNT or size != ENTRY_SIZE: raise SystemExit('Unexpected GPT entry geometry')
    f.seek(entries_lba * SECTOR)
    entries = f.read(count * size)
    if (zlib.crc32(entries) & 0xffffffff) != struct.unpack_from('<I', h, 88)[0]: raise SystemExit('GPT partition-entry CRC mismatch')
    expected = [
        (bios_start, bios_start + bios_size - 1),
        (efi_start, efi_start + efi_size - 1),
        (root_start, last_usable),
    ]
    for idx, (want_start, want_end) in enumerate(expected):
        e = entries[idx * size:(idx + 1) * size]
        if e[:16] == b'\x00' * 16: raise SystemExit(f'GPT partition {idx + 1} is empty')
        got_start, got_end = struct.unpack_from('<QQ', e, 32)
        if (got_start, got_end) != (want_start, want_end): raise SystemExit(f'GPT partition {idx + 1} geometry mismatch')
PY

BOOT_SIG="$(dd if="$IMAGE" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d '[:space:]')"
[[ "$BOOT_SIG" == "55aa" ]] || fail "MBR boot signature is missing."

# Show the final layout once more for the build log.
printf '  BIOS:  sectors %d-%d\n' "$BIOS_START" "$((BIOS_START + BIOS_SIZE - 1))"
printf '  EFI:   sectors %d-%d\n' "$EFI_START" "$((EFI_START + EFI_SIZE - 1))"
printf '  ROOT:  sectors %d-%d\n' "$ROOT_START" "$GPT_LAST_USABLE"

log "Compressing image with zstd..."
zstd --threads=0 --ultra -22 -f "$IMAGE" -o "$IMAGE_ZST"

log "Writing SHA-256 checksums..."
(
    cd "$OUTPUT_DIR"
    sha256sum "$IMAGE_NAME" "${IMAGE_NAME}.zst"
) > "$CHECKSUMS"

log "Build complete."
echo
printf 'Image:      %s\n' "$IMAGE"
printf 'Compressed: %s\n' "$IMAGE_ZST"
printf 'Checksums:  %s\n' "$CHECKSUMS"
printf '\nThe builder itself does not access /dev, loop devices, mounts, QEMU, or KVM.\n'
