#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$ROOT/output"

mkdir -p "$OUTPUT"

if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: Podman is required."
    echo
    echo "Install Podman using your distribution's package manager."
    exit 1
fi

echo "=============================================="
echo "VLab image builder"
echo "=============================================="
echo

echo "[1/2] Building builder container..."

podman build \
    --tag vlab-builder \
    "$ROOT/builder"

echo
echo "[2/2] Building VLab image..."

podman run \
    --rm \
    --privileged \
    -v "$OUTPUT:/output:Z" \
    vlab-builder

echo
echo "=============================================="
echo "Build complete"
echo "=============================================="
echo
echo "Output:"
echo
echo "  $OUTPUT/vlab-amd64.img"
echo "  $OUTPUT/vlab-amd64.img.zst"
echo "  $OUTPUT/SHA256SUMS"
echo
