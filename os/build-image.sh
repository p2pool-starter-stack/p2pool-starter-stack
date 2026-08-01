#!/usr/bin/env bash
# Build the pithead-os appliance rootfs (#77 phase 2): the OS as a container build, exported to a
# tarball. os/rauc/mkimage.sh turns that tarball into a bootable image and os/rauc/mkbundle.sh
# turns it into an update bundle. Run from the repo root on a box with docker.
#   os/build-image.sh [--ssh [PUBKEY_FILE]]   -> os/build/pithead-root.tar
#
#   --ssh [FILE]   debug/bench variant: bake FILE (default: the builder's ~/.ssh/id_ed25519.pub,
#                  falling back to id_rsa.pub) as root's authorized key and enable sshd. Release
#                  builds omit it and stay shell-less. Sets the same PITHEAD_TEST_SSH_PUBKEY the
#                  env path always honored — the flag exists so the bench recipe is one word,
#                  not a rediscovered env var.
set -euo pipefail
cd "$(dirname "$0")/.."

while [ $# -gt 0 ]; do
    case "$1" in
    --ssh)
        keyfile=""
        # An optional value: `--ssh path/to/key.pub` or bare `--ssh` for the builder's own key.
        if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then
            keyfile="$2"
            shift
        else
            for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
                [ -s "$k" ] && keyfile="$k" && break
            done
        fi
        [ -s "${keyfile:-}" ] || {
            echo "--ssh: no public key found (looked for ~/.ssh/id_ed25519.pub, ~/.ssh/id_rsa.pub); pass one explicitly" >&2
            exit 1
        }
        PITHEAD_TEST_SSH_PUBKEY="$(head -n1 "$keyfile")"
        export PITHEAD_TEST_SSH_PUBKEY
        echo "==> debug build: sshd enabled, key from $keyfile"
        ;;
    *)
        echo "unknown argument: $1 (usage: os/build-image.sh [--ssh [PUBKEY_FILE]])" >&2
        exit 1
        ;;
    esac
    shift
done

# Bake the wizard's container image into the appliance: first boot must reach the setup page
# without a registry (the operator may have no working network config yet, and the plan's
# offline-first-boot property depends on it). The rest of the release's images are pulled at
# provision time for now — baking the full set is tracked with the appliance-size work.
STACK_VERSION="v$(tr -d ' \t\r\n' <VERSION)"
WIZARD_IMAGE="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-dashboard:${STACK_VERSION}"
mkdir -p os/rootfs/images
echo "==> staging wizard image $WIZARD_IMAGE"
if [ "${PITHEAD_WIZARD_FROM_REGISTRY:-0}" = "1" ]; then
    # Release path: the published image carries the wizard module.
    docker pull -q "$WIZARD_IMAGE" >/dev/null
else
    # No mtime cache, EVER. The old test compared the archive against build/dashboard — the
    # DIRECTORY, whose mtime only moves when a direct child is added or removed. Editing a file
    # deep inside it changes nothing, so the cache said "fresh" forever and stale wizards
    # reached three separate benches. Docker's own layer cache makes the rebuild cheap; a
    # correctness decision must not hang on directory-mtime semantics.
    # Development path, and the default until a release ships the wizard: mining_dashboard.wizard
    # only exists in this working tree, so a pulled image would start and immediately exit with
    # "No module named mining_dashboard.wizard". Build the image the appliance will actually run.
    docker build -q -t "$WIZARD_IMAGE" build/dashboard >/dev/null
fi
# Harness builds only: stamp the marker INTO the dashboard image, at a path the wizard serves
# (/static/os-test-marker.txt). The tag is identical across builds, so this is the only way a
# battery can tell which dashboard actually answers after an update or reinstall — the #798
# regression was precisely "new OS, old dashboard, every check green". Release builds set no
# marker and get no extra layer.
if [ -n "${PITHEAD_TEST_MARKER:-}" ]; then
    # USER root/pithead mirrors build/dashboard/Dockerfile: the runtime user cannot write /app.
    printf 'FROM %s\nUSER root\nRUN printf %%s "%s" >/app/mining_dashboard/web/static/os-test-marker.txt\nUSER pithead\n' \
        "$WIZARD_IMAGE" "$PITHEAD_TEST_MARKER" | docker build -q -t "$WIZARD_IMAGE" - >/dev/null
fi
docker save "$WIZARD_IMAGE" | gzip -1 >os/rootfs/images/dashboard.tar.gz

# Stamp the commit into the image. A release build once shipped a dashboard two commits stale
# because it pulled from an intermediate clone, and nothing in the artifact could reveal it —
# the image looked correct and behaved like the previous build. verify-image asserts this.
BUILD_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BUILD_DIRTY=""
git diff --quiet 2>/dev/null || BUILD_DIRTY="-dirty"
printf '%s%s\n' "$BUILD_COMMIT" "$BUILD_DIRTY" >os/rootfs/BUILD_COMMIT
echo "==> building from commit ${BUILD_COMMIT}${BUILD_DIRTY}"

# Overridable so a parallel release build cannot collide with a harness build on the same host.
# It is an env var and NOT an edit to this file: the build stamps its own commit, and a sed
# against the working tree would mark every release image "-dirty" and fail its own gate.
ROOTFS_TAG="${PITHEAD_ROOTFS_TAG:-pithead-os-rootfs}"

echo "==> rootfs: container build + export"
docker build -f os/rootfs/Containerfile -t "$ROOTFS_TAG" \
    --build-arg PITHEAD_TEST_SSH_PUBKEY="${PITHEAD_TEST_SSH_PUBKEY:-}" \
    --build-arg PITHEAD_TEST_MARKER="${PITHEAD_TEST_MARKER:-}" \
    --build-arg PITHEAD_UPDATER="${PITHEAD_UPDATER:-rauc}" .
cid=$(docker create "$ROOTFS_TAG")
mkdir -p os/build
docker export --output os/build/pithead-root.tar "$cid"
docker rm "$cid" >/dev/null
echo "==> rootfs: os/build/pithead-root.tar ($(du -h os/build/pithead-root.tar | cut -f1))"
