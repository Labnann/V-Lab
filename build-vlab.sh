sudo podman build -t localhost/vlab-builder ./builder

mkdir -p output debootstrap-cache

sudo podman run --rm --privileged \
    -v /dev:/dev \
    -v "$PWD/output:/output:Z" \
    -v "$PWD/debootstrap-cache:/cache:Z" \
    localhost/vlab-builder
