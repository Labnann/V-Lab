mkdir -p output

podman build -t vlab-builder ./builder

podman run --rm \
    -v "$PWD/output:/output:Z" --privileged \
    vlab-builder
