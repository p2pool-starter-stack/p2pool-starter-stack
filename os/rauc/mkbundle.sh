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

cat >"$WORK/bundle/manifest.raucm" <<EOF
[update]
compatible=pithead-amd64
version=$(tr -d ' \t\r\n' <VERSION)

[meta.pithead]
variant=$VARIANT

[image.rootfs]
filename=rootfs.ext4
EOF

echo "==> signing the bundle"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
rauc bundle --cert="$RAUC_CERT" --key="$RAUC_KEY" "$WORK/bundle" "$OUT"
echo "==> bundle: $OUT ($(du -h "$OUT" | cut -f1))"
