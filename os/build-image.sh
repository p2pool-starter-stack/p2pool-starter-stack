#!/usr/bin/env bash
# Build the pithead-os appliance rootfs (#77 phase 2): the OS as a container build, exported to a
# tarball. os/rauc/mkimage.sh turns that tarball into a bootable image and os/rauc/mkbundle.sh
# turns it into an update bundle. Run from the repo root on a box with docker.
#   os/build-image.sh [--ssh [PUBKEY_FILE]] [--fresh-index]   -> os/build/pithead-root.tar
#
#   --ssh [FILE]   debug/bench variant: bake FILE (default: the builder's ~/.ssh/id_ed25519.pub,
#                  falling back to id_rsa.pub) as root's authorized key and enable sshd. Release
#                  builds omit it and stay shell-less. Sets the same PITHEAD_TEST_SSH_PUBKEY the
#                  env path always honored — the flag exists so the bench recipe is one word,
#                  not a rediscovered env var.
#   --fresh-index  bust ONLY the rootfs Dockerfile's apt-update layer (#929): a warm builder
#                  cache reuses that layer's apt index for weeks, and when the mirror rotates a
#                  package the stale index 404s on install. Later layers still cache normally.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

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
    --fresh-index)
        FRESH_INDEX=1
        ;;
    *)
        echo "unknown argument: $1 (usage: os/build-image.sh [--ssh [PUBKEY_FILE]] [--fresh-index])" >&2
        exit 1
        ;;
    esac
    shift
done

# apt_fetch_failure_hint (#929): given a build log tail, detect the stale-apt-index 404 signature
# and print the remedy. Split out so it's testable without docker (tests/stack/run.sh covers it).
apt_fetch_failure_hint() {
    if grep -qE '404  Not Found|Unable to fetch some archives' <<<"$1"; then
        echo "==> looks like a stale apt index (mirror rotated a package since the last build)." >&2
        echo "==> rerun with: os/build-image.sh --fresh-index" >&2
    fi
}

# Test seam: `PITHEAD_BUILD_IMAGE_TEST=1 source os/build-image.sh [args...]` parses args and
# defines apt_fetch_failure_hint above, then returns here instead of touching docker — lets
# tests/stack/run.sh exercise flag parsing and the remedy hint without a build.
if [ "${PITHEAD_BUILD_IMAGE_TEST:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Bake the wizard's container image into the appliance: first boot must reach the setup page
# without a registry (the operator may have no working network config yet, and the plan's
# offline-first-boot property depends on it). The rest of the release's images are pulled at
# provision time for now — baking the full set is tracked with the appliance-size work.
STACK_VERSION="v$(tr -d ' \t\r\n' <VERSION)"
WIZARD_IMAGE="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-dashboard:${STACK_VERSION}"
# A DEBUG build against a non-default registry pins that registry into the image's boot units
# and tells podman how to trust it — a CA file (PITHEAD_REGISTRY_CA) for a TLS registry, else an
# insecure (HTTP) entry (#1892). The wizard archive above is NAMED with the build-time
# registry and first boot re-derives the same name at runtime, so the two must agree, and nothing
# on the box sets the runtime half otherwise. Release builds never carry either file.
TEST_REGISTRY=""
if [ -n "${PITHEAD_TEST_SSH_PUBKEY:-}" ] && [ -n "${PITHEAD_REGISTRY:-}" ] &&
    [ "$PITHEAD_REGISTRY" != "ghcr.io/p2pool-starter-stack" ]; then
    TEST_REGISTRY="$PITHEAD_REGISTRY"
    if [ -n "${PITHEAD_REGISTRY_CA:-}" ]; then
        [ -s "$PITHEAD_REGISTRY_CA" ] || {
            echo "PITHEAD_REGISTRY_CA: $PITHEAD_REGISTRY_CA is not a readable file" >&2
            exit 1
        }
        echo "==> debug build: the image will provision from $TEST_REGISTRY (TLS, CA $PITHEAD_REGISTRY_CA)"
    else
        echo "==> debug build: the image will provision from $TEST_REGISTRY (insecure for podman)"
    fi
fi
mkdir -p os/rootfs/images
echo "==> staging wizard image $WIZARD_IMAGE"
if [ "${PITHEAD_WIZARD_FROM_REGISTRY:-0}" = "1" ]; then
    # Release path: the published image carries the wizard module.
    docker pull -q "$WIZARD_IMAGE" >/dev/null
else
    # No mtime cache, EVER. The old test compared the archive against dashboard — the
    # DIRECTORY, whose mtime only moves when a direct child is added or removed. Editing a file
    # deep inside it changes nothing, so the cache said "fresh" forever and stale wizards
    # reached three separate benches. Docker's own layer cache makes the rebuild cheap; a
    # correctness decision must not hang on directory-mtime semantics.
    # Development path, and the default until a release ships the wizard: mining_dashboard.wizard
    # only exists in this working tree, so a pulled image would start and immediately exit with
    # "No module named mining_dashboard.wizard". Build the image the appliance will actually run.
    docker build -q -t "$WIZARD_IMAGE" dashboard >/dev/null
fi
# Harness builds only: stamp the marker INTO the dashboard image, at a path the wizard serves
# (/static/os-test-marker.txt). The tag is identical across builds, so this is the only way a
# battery can tell which dashboard actually answers after an update or reinstall — the #798
# regression was precisely "new OS, old dashboard, every check green". Release builds set no
# marker and get no extra layer.
if [ -n "${PITHEAD_TEST_MARKER:-}" ]; then
    # USER root/pithead mirrors dashboard/Dockerfile: the runtime user cannot write /app.
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
# --fresh-index (#929) stamps a new value into the Dockerfile's APT_INDEX_STAMP ARG, which busts
# only the apt-update layer it precedes — every other layer still caches normally.
apt_index_stamp=0
[ "${FRESH_INDEX:-0}" = "1" ] && apt_index_stamp="$(date +%s)"
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
if ! docker build -f os/rootfs/Dockerfile -t "$ROOTFS_TAG" \
    --build-arg PITHEAD_TEST_SSH_PUBKEY="${PITHEAD_TEST_SSH_PUBKEY:-}" \
    --build-arg PITHEAD_TEST_MARKER="${PITHEAD_TEST_MARKER:-}" \
    --build-arg PITHEAD_UPDATER="${PITHEAD_UPDATER:-rauc}" \
    --build-arg APT_INDEX_STAMP="$apt_index_stamp" . 2>&1 | tee "$build_log"; then
    apt_fetch_failure_hint "$(cat "$build_log")"
    exit 1
fi
cid=$(docker create "$ROOTFS_TAG")
mkdir -p os/build
docker export --output os/build/pithead-root.tar "$cid"
docker rm "$cid" >/dev/null
if [ -n "$TEST_REGISTRY" ]; then
    # Appended to the exported rootfs rather than baked by the Dockerfile: the release rootfs is
    # then byte-identical to a build that never heard of a test registry. Leaf files only — a
    # directory entry would re-apply the staging dir's mode onto /etc on extraction.
    stage="$(mktemp -d)"
    for u in pithead-boot pithead-firstboot pithead-setup-again; do
        mkdir -p "$stage/etc/systemd/system/$u.service.d"
        printf '[Service]\nEnvironment=PITHEAD_REGISTRY=%s\n' "$TEST_REGISTRY" \
            >"$stage/etc/systemd/system/$u.service.d/pithead-test-registry.conf"
    done
    # An SSH shell running ./pithead by hand reads /etc/environment through PAM, never a unit's
    # drop-in (#1931): the pin goes there too, appended to the file the rootfs already carries
    # (PITHEAD_ENGINE, Dockerfile) so the later tar entry replaces it whole and loses nothing.
    tar -xOf os/build/pithead-root.tar etc/environment >"$stage/etc/environment" || {
        echo "build-image: the exported rootfs has no etc/environment to pin the registry into" >&2
        exit 1
    }
    printf 'PITHEAD_REGISTRY=%s\n' "$TEST_REGISTRY" >>"$stage/etc/environment"
    # containers/image reads /etc/containers/certs.d/<host:port>/ca.crt for a TLS registry; the
    # insecure entry is the HTTP fallback. One or the other, never both.
    if [ -n "${PITHEAD_REGISTRY_CA:-}" ]; then
        mkdir -p "$stage/etc/containers/certs.d/${TEST_REGISTRY%%/*}"
        cp "$PITHEAD_REGISTRY_CA" "$stage/etc/containers/certs.d/${TEST_REGISTRY%%/*}/ca.crt"
    else
        mkdir -p "$stage/etc/containers/registries.conf.d"
        printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "${TEST_REGISTRY%%/*}" \
            >"$stage/etc/containers/registries.conf.d/pithead-test-registry.conf"
    fi
    (cd "$stage" && find etc -type f) |
        tar --append -f os/build/pithead-root.tar --owner=0 --group=0 --mode=0644 -C "$stage" -T -
    rm -r "$stage"
fi
echo "==> rootfs: os/build/pithead-root.tar ($(du -h os/build/pithead-root.tar | cut -f1))"
