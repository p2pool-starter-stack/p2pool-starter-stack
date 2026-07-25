#!/usr/bin/env bash
# Build a RAUC update bundle from the shared rootfs tarball (bake-off candidate B).
# The Rugix equivalent is `run-bakery bake bundle`; here the slot image and manifest are ours.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${1:-os/rauc/build/update.raucb}"
TARBALL="os/bakery/build/pithead-root.tar"
CERT_DIR="os/rauc/certs"
WORK=$(mktemp -d)
trap 'umount "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ -s "$TARBALL" ] || {
    echo "missing $TARBALL — run os/build-image.sh first" >&2
    exit 2
}
[ -s "$CERT_DIR/key.pem" ] || {
    echo "missing signing key — run os/rauc/mkimage.sh first" >&2
    exit 2
}

# A slot image is a filesystem image of the whole rootfs — RAUC replaces the inactive slot
# wholesale. 8 GiB to match the slot size.
echo "==> building the slot filesystem image"
mkdir -p "$WORK/bundle" "$WORK/mnt"
truncate -s 8G "$WORK/rootfs.ext4"
mkfs.ext4 -q -L system "$WORK/rootfs.ext4"
mount -o loop "$WORK/rootfs.ext4" "$WORK/mnt"
tar -xf "$TARBALL" -C "$WORK/mnt"
rm -f "$WORK/mnt/.dockerenv"
mkdir -p "$WORK/mnt"/{dev,proc,sys,run,tmp,data,boot/efi}
install -D -m 644 os/rauc/system.conf "$WORK/mnt/etc/rauc/system.conf"
install -D -m 644 "$CERT_DIR/cert.pem" "$WORK/mnt/etc/rauc/keyring.pem"
umount "$WORK/mnt"
mv "$WORK/rootfs.ext4" "$WORK/bundle/rootfs.ext4"

cat >"$WORK/bundle/manifest.raucm" <<EOF
[update]
compatible=pithead-amd64
version=$(tr -d ' \t\r\n' <VERSION)

[image.rootfs]
filename=rootfs.ext4
EOF

echo "==> signing the bundle"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
rauc bundle --cert="$CERT_DIR/cert.pem" --key="$CERT_DIR/key.pem" "$WORK/bundle" "$OUT"
echo "==> bundle: $OUT ($(du -h "$OUT" | cut -f1))"
