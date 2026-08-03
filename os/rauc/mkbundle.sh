#!/usr/bin/env bash
# Build a RAUC update bundle from the shared rootfs tarball (bake-off candidate B).
# The Rugix equivalent is `run-bakery bake bundle`; here the slot image and manifest are ours.
#
#   os/rauc/mkbundle.sh [--dev] [OUT_PATH]
#
# Signing: a release bundle must name the key (PITHEAD_RAUC_CERT + PITHEAD_RAUC_KEY); --dev
# auto-generates a throwaway CN=pithead-dev key for local/bench work. See resolve_signing_material
# in populate-slot.sh and the custody runbook in docs/dev/release-server.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

# --dev marks the build as throwaway (auto-gen allowed); the first non-flag arg is the output path.
DEV=0
OUT=""
for arg in "$@"; do
    case "$arg" in
    --dev) DEV=1 ;;
    *) [ -z "$OUT" ] && OUT="$arg" ;;
    esac
done
OUT="${OUT:-os/rauc/build/update.raucb}"
TARBALL="os/build/pithead-root.tar"

# Compatibility metadata — the channel contract the update path reads back (docs/dev/appliance-release.md).
# Validated up front so a bad release input fails before the multi-minute image build, not after.
#   PITHEAD_DATA_MIGRATION=true  — this release runs a forward-only /data (lmdb) migration.
#   PITHEAD_MIN_OS_VERSION=X.Y.Z — the lowest OS version that can still read /data once it has.
# A migrating release MUST name that floor: without it a later rollback silently strands the
# migrated chain data (os-update reads the floor back to refuse exactly that).
OS_VERSION=$(tr -d ' \t\r\n' <VERSION)
DATA_MIGRATION=${PITHEAD_DATA_MIGRATION:-false}
case "$DATA_MIGRATION" in
true | false) ;;
*)
    echo "PITHEAD_DATA_MIGRATION must be 'true' or 'false', got '$DATA_MIGRATION'" >&2
    exit 2
    ;;
esac
MIN_OS_VERSION=${PITHEAD_MIN_OS_VERSION:-}
if [ -n "$MIN_OS_VERSION" ] && ! printf '%s' "$MIN_OS_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "PITHEAD_MIN_OS_VERSION must be X.Y.Z, got '$MIN_OS_VERSION'" >&2
    exit 2
fi
if [ "$DATA_MIGRATION" = true ] && [ -z "$MIN_OS_VERSION" ]; then
    echo "PITHEAD_DATA_MIGRATION=true needs PITHEAD_MIN_OS_VERSION=X.Y.Z — the floor below which the migrated /data cannot be read" >&2
    exit 2
fi
# shellcheck source=os/rauc/populate-slot.sh
. os/rauc/populate-slot.sh
WORK=$(mktemp -d)
trap 'umount "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ -s "$TARBALL" ] || {
    echo "missing $TARBALL — run os/build-image.sh first" >&2
    exit 2
}

# The bundle is signed with this key and RAUC verifies it against the keyring baked at image build.
# A release bundle must name the key explicitly; --dev auto-generates a labelled throwaway.
resolve_signing_material "$DEV" || exit $?

# A slot image is a filesystem image of the whole rootfs — RAUC replaces the inactive slot
# wholesale. 4 GiB to match the slot size (see mkimage.sh for why 4).
echo "==> building the slot filesystem image"
mkdir -p "$WORK/bundle" "$WORK/mnt"
truncate -s 4G "$WORK/rootfs.ext4"
mkfs.ext4 -q -L system "$WORK/rootfs.ext4"
mount -o loop "$WORK/rootfs.ext4" "$WORK/mnt"
tar -xf "$TARBALL" -C "$WORK/mnt"
populate_slot "$WORK/mnt"
# The build variant, read from the rootfs the bundle actually ships so the stamp cannot drift
# from the payload: debug (SSH baked) or release (shell-less). Carried as bundle metadata so
# `pithead os-update` can warn BEFORE a debug box replaces the SSH channel driving the install.
VARIANT=$(tr -d ' \t\r\n' 2>/dev/null <"$WORK/mnt/etc/pithead-variant" || echo release)
umount "$WORK/mnt"
mv "$WORK/rootfs.ext4" "$WORK/bundle/rootfs.ext4"

render_bundle_manifest "$OS_VERSION" "$VARIANT" "$DATA_MIGRATION" "$MIN_OS_VERSION" \
    >"$WORK/bundle/manifest.raucm"

echo "==> signing the bundle"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
rauc bundle --cert="$RAUC_CERT" --key="$RAUC_KEY" "$WORK/bundle" "$OUT"
echo "==> bundle: $OUT ($(du -h "$OUT" | cut -f1))"
