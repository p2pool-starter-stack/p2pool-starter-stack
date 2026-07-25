#!/usr/bin/env bash
# Build the pithead-os appliance image with RAUC as the updater (bake-off candidate B).
#
# This is the work Rugix Bakery does for us: RAUC is only an updater, so partitioning, filesystem
# creation, slot population, bootloader install and boot-state seeding are all ours. Consumes the
# SAME rootfs tarball as the Rugix candidate (os/build-image.sh stages it), so the comparison is
# updater-only.
#
#   os/rauc/mkimage.sh [--out PATH] [--size GiB]
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${1:-os/rauc/build/system.img}"
# Only the ESP + slot A ship. systemd-repart creates slot B and /data on the target machine's
# real disk at first boot, so the image does not carry 8 GiB of zeros and an /data sized for
# the image rather than the disk. 9 GiB covers 256M ESP + 8 GiB slot A + alignment.
SIZE_GIB="${PITHEAD_IMAGE_GIB:-9}"
TARBALL="os/bakery/build/pithead-root.tar"
# shellcheck source=os/rauc/populate-slot.sh
. os/rauc/populate-slot.sh
CERT_DIR="os/rauc/certs"

[ -s "$TARBALL" ] || {
    echo "missing $TARBALL — run os/build-image.sh first to stage the rootfs" >&2
    exit 2
}
mkdir -p "$(dirname "$OUT")" "$CERT_DIR"

# Dev signing material. RAUC refuses unsigned bundles, so a keypair is mandatory even to spike.
if [ ! -s "$CERT_DIR/cert.pem" ]; then
    echo "==> generating a development signing keypair"
    openssl req -x509 -newkey rsa:4096 -nodes -keyout "$CERT_DIR/key.pem" \
        -out "$CERT_DIR/cert.pem" -days 3650 -subj "/CN=pithead-dev" 2>/dev/null
fi

echo "==> creating a ${SIZE_GIB} GiB image with the A/B layout"
rm -f "$OUT"
truncate -s "${SIZE_GIB}G" "$OUT"
# Same shape as the Rugix layout: EFI + two system slots + data. Boot files live inside each slot
# (GRUB reads them by partlabel), so there is no separate boot partition to keep in sync.
sgdisk -Z "$OUT" >/dev/null
# Slot B and data are NOT created here — /usr/lib/repart.d declares them and systemd-repart
# builds them on the target's real disk at first boot. Creating them here would size /data to the
# image instead of the machine, which is what blocked install-to-disk.
sgdisk -n 1:0:+256M -t 1:ef00 -c 1:esp \
    -n 2:0:+8G -t 2:8300 -c 2:system-a "$OUT" >/dev/null

LOOP=$(losetup -Pf --show "$OUT")
cleanup() {
    umount -R /mnt/rauc-sys /mnt/rauc-esp 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> filesystems"
mkfs.vfat -n ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L system-a "${LOOP}p2"

echo "==> populating slot A from the shared rootfs tarball"
mkdir -p /mnt/rauc-sys /mnt/rauc-esp
mount "${LOOP}p2" /mnt/rauc-sys
tar -xf "$TARBALL" -C /mnt/rauc-sys
populate_slot /mnt/rauc-sys

echo "==> bootloader"
mount "${LOOP}p1" /mnt/rauc-esp
mkdir -p /mnt/rauc-esp/EFI/BOOT /mnt/rauc-esp/grub
cp /mnt/rauc-sys/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /mnt/rauc-esp/EFI/BOOT/BOOTX64.EFI 2>/dev/null ||
    grub-mkimage -O x86_64-efi -o /mnt/rauc-esp/EFI/BOOT/BOOTX64.EFI -p /grub \
        part_gpt fat ext2 normal linux echo search search_label configfile test loadenv regexp
install -m 644 os/rauc/grub.cfg /mnt/rauc-esp/grub/grub.cfg
# Seed boot state: slot A good, B empty. RAUC rewrites these on every install/mark.
# The env block MUST live in GRUB's prefix directory: bare `load_env` reads $prefix/grubenv, and
# our BOOTX64.EFI is built with -p /grub. Putting it at the ESP root instead makes `load_env` a
# silent no-op — ORDER keeps its built-in "A B" with both _OK=0, nothing is selectable, and every
# boot falls to the default entry. RAUC writes the file correctly and the machine still ignores it.
grub-editenv /mnt/rauc-esp/grub/grubenv create
grub-editenv /mnt/rauc-esp/grub/grubenv set ORDER="A B" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0

# The /var overlay directories cannot be seeded here any more — /data does not exist until
# systemd-repart creates it. pithead-dataprep.service makes them on first boot, before anything
# that needs a writable /var.

sync
echo "==> image: $OUT ($(du -h "$OUT" | cut -f1))"
