#!/usr/bin/env bash
# Build the pithead-os appliance image (#77 phase 2): rootfs as a container build, exported and
# fed to Rugix Bakery (the Umbrel pattern). Run from the repo root on a box with docker.
#   os/build-image.sh              -> os/bakery/build/pithead-os-amd64/system.img
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned Bakery. The 0.9 line is the one proven in the field (umbrelOS); bump deliberately.
RUGIX_BAKERY_VERSION="${RUGIX_BAKERY_VERSION:-v0.9.3}"
export RUGIX_BAKERY_IMAGE="${RUGIX_BAKERY_IMAGE:-ghcr.io/rugix/rugix-bakery:${RUGIX_BAKERY_VERSION}}"

echo "==> rootfs: container build + export"
docker build -f os/rootfs/Containerfile -t pithead-os-rootfs .
cid=$(docker create pithead-os-rootfs)
mkdir -p os/bakery/build
docker export --output os/bakery/build/pithead-root.tar "$cid"
docker rm "$cid" >/dev/null

echo "==> bakery: bake the EFI image"
cd os/bakery
# The layer cache does not track the imported tarball's content — a rebuilt rootfs would bake
# against the stale cached root. Builds are infrequent; correctness beats cache.
rm -rf .rugix
if [ ! -x ./run-bakery ]; then
    curl -sfSO "https://raw.githubusercontent.com/rugix/rugix-bakery/${RUGIX_BAKERY_VERSION}/container/run-bakery"
    chmod +x ./run-bakery
fi
./run-bakery bake image pithead-os-amd64
echo "==> image: $(ls -lh build/pithead-os-amd64/system.img 2>/dev/null | awk '{print $5, $9}')"
