
#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?Usage: setup-plymouth.sh ROOTFS}"

cat > "$ROOTFS/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=spinner
EOF

sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' \
    "$ROOTFS/etc/default/grub"

