#!/usr/bin/env bash
set -euo pipefail

COMPRESS=0

for arg in "$@"; do
    case "$arg" in
        --compress)
            COMPRESS=1
            ;;
        *)
            echo "Usage: $0 [--compress]" >&2
            exit 2
            ;;
    esac
done

sudo podman build -t localhost/vlab-builder ./builder

mkdir -p output debootstrap-cache

sudo podman run --rm --privileged \
    -v /dev:/dev \
    -v "$PWD/output:/output:Z" \
    -v "$PWD/debootstrap-cache:/cache:Z" \
    localhost/vlab-builder

if (( COMPRESS )); then
    IMAGE="$PWD/output/vlab-amd64.img"
    COMPRESSED="$IMAGE.zst"
    CHECKSUMS="$PWD/output/SHA256SUMS"

    echo "Compressing image on host..."

    zstd --threads=0 --ultra -22 "$IMAGE" -o "$COMPRESSED"

    sha256sum "$IMAGE" "$COMPRESSED" > "$CHECKSUMS"
fi
