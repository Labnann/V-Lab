mkdir -p "$ROOTFS/etc/plymouth"

cat > "$ROOTFS/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=spinner
EOF
