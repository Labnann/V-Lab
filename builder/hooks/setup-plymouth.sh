
#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?Usage: setup-plymouth.sh ROOTFS}"

if [[ ! -d "$ROOTFS" ]]; then
    echo "Error: ROOTFS does not exist: $ROOTFS" >&2
    exit 1
fi

THEMES_DIR="$ROOTFS/usr/share/plymouth/themes"

# Configure the spinner theme.
if [[ -d "$THEMES_DIR/spinner" ]]; then
    mkdir -p "$ROOTFS/etc/plymouth"

    cat > "$ROOTFS/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=spinner
EOF

    echo "Plymouth spinner theme configured."
else
    echo "Warning: spinner theme not found; skipping theme configuration." >&2
fi

# Hide routine kernel messages and enable the splash screen.
GRUB_DEFAULT="$ROOTFS/etc/default/grub"

if [[ -f "$GRUB_DEFAULT" ]]; then
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT"; then
        sed -i \
            's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' \
            "$GRUB_DEFAULT"
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> "$GRUB_DEFAULT"
    fi

    echo "GRUB configured for quiet splash boot."
else
    echo "Warning: $GRUB_DEFAULT not found; skipping GRUB configuration." >&2
fi

