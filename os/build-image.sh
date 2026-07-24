#!/usr/bin/env bash
# Build the pithead-os appliance image (#77 phase 2): rootfs as a container build, exported and
# fed to Rugix Bakery (the Umbrel pattern). Run from the repo root on a box with docker.
#   os/build-image.sh              -> os/bakery/build/pithead-os-amd64/system.img
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned Bakery. The 0.9 line is the one proven in the field (umbrelOS); bump deliberately.
RUGIX_BAKERY_VERSION="${RUGIX_BAKERY_VERSION:-v0.9.3}"
export RUGIX_BAKERY_IMAGE="${RUGIX_BAKERY_IMAGE:-ghcr.io/rugix/rugix-bakery:${RUGIX_BAKERY_VERSION}}"

# Bake the wizard's container image into the appliance: first boot must reach the setup page
# without a registry (the operator may have no working network config yet, and the plan's
# offline-first-boot property depends on it). The rest of the release's images are pulled at
# provision time for now — baking the full set is tracked with the appliance-size work.
STACK_VERSION="v$(tr -d ' \t\r\n' <VERSION)"
WIZARD_IMAGE="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-dashboard:${STACK_VERSION}"
mkdir -p os/rootfs/images
if [ ! -s os/rootfs/images/dashboard.tar.gz ]; then
    echo "==> staging wizard image $WIZARD_IMAGE"
    docker pull -q "$WIZARD_IMAGE" >/dev/null
    docker save "$WIZARD_IMAGE" | gzip -1 >os/rootfs/images/dashboard.tar.gz
fi

echo "==> rootfs: container build + export"
docker build -f os/rootfs/Containerfile -t pithead-os-rootfs \
    --build-arg PITHEAD_TEST_SSH_PUBKEY="${PITHEAD_TEST_SSH_PUBKEY:-}" \
    --build-arg PITHEAD_TEST_MARKER="${PITHEAD_TEST_MARKER:-}" .
cid=$(docker create pithead-os-rootfs)
mkdir -p os/bakery/build
docker export --output os/bakery/build/pithead-root.tar "$cid"
docker rm "$cid" >/dev/null

echo "==> bakery: bake the EFI image"
cd os/bakery
# The layer cache does not track the imported tarball's content — a rebuilt rootfs would bake
# against the stale cached root. Builds are infrequent; correctness beats cache. The bakery
# writes cache files as root (container), so the wipe needs sudo.
sudo rm -rf .rugix build/pithead-os-amd64
if [ ! -x ./run-bakery ]; then
    curl -sfSO "https://raw.githubusercontent.com/rugix/rugix-bakery/${RUGIX_BAKERY_VERSION}/container/run-bakery"
    chmod +x ./run-bakery
fi
ARTIFACT="${PITHEAD_BAKE_ARTIFACT:-image}" # image | bundle (tests/os builds update bundles)
./run-bakery bake "$ARTIFACT" pithead-os-amd64
echo "==> baked $ARTIFACT: $(find build/pithead-os-amd64 -newer rugix-bakery.toml -name 'system.*' -o -name '*.rugixb' 2>/dev/null | head -2 | tr '\n' ' ')"
