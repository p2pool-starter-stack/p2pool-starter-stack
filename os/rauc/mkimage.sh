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
SIZE_GIB="${PITHEAD_IMAGE_GIB:-20}"
TARBALL="os/bakery/build/pithead-root.tar"
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
sgdisk -n 1:0:+256M -t 1:ef00 -c 1:esp \
    -n 2:0:+8G -t 2:8300 -c 2:system-a \
    -n 3:0:+8G -t 3:8300 -c 3:system-b \
    -n 4:0:0 -t 4:8300 -c 4:data "$OUT" >/dev/null

LOOP=$(losetup -Pf --show "$OUT")
cleanup() {
    umount -R /mnt/rauc-sys /mnt/rauc-esp 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> filesystems"
mkfs.vfat -n ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L system-a "${LOOP}p2"
mkfs.ext4 -q -L system-b "${LOOP}p3"
mkfs.ext4 -q -L data -m 0.5 "${LOOP}p4"

echo "==> populating slot A from the shared rootfs tarball"
mkdir -p /mnt/rauc-sys /mnt/rauc-esp
mount "${LOOP}p2" /mnt/rauc-sys
tar -xf "$TARBALL" -C /mnt/rauc-sys
# Same docker-export fixes the Rugix candidate needs — systemd refuses PID 1 with /.dockerenv,
# and the export omits the pseudo-filesystem mount points.
rm -f /mnt/rauc-sys/.dockerenv
mkdir -p /mnt/rauc-sys/{dev,proc,sys,run,tmp,data,boot/efi}
# State: RAUC has no persist/state model, so mounting the data partition is ours. Rugix does this
# from a two-line [[persist]] declaration; here it is an fstab entry we write and own, and the
# "what survives a slot replacement" question is still unanswered (/etc changes in a slot are
# lost when RAUC overwrites it, whereas Rugix keeps an /etc overlay on the data partition).
printf 'LABEL=data /data ext4 defaults,noatime 0 2\nLABEL=ESP /boot/efi vfat umask=0077 0 1\n' \
    >>/mnt/rauc-sys/etc/fstab
install -D -m 644 os/rauc/system.conf /mnt/rauc-sys/etc/rauc/system.conf
install -D -m 644 "$CERT_DIR/cert.pem" /mnt/rauc-sys/etc/rauc/keyring.pem

echo "==> bootloader"
mount "${LOOP}p1" /mnt/rauc-esp
mkdir -p /mnt/rauc-esp/EFI/BOOT /mnt/rauc-esp/grub
cp /mnt/rauc-sys/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /mnt/rauc-esp/EFI/BOOT/BOOTX64.EFI 2>/dev/null ||
    grub-mkimage -O x86_64-efi -o /mnt/rauc-esp/EFI/BOOT/BOOTX64.EFI -p /grub \
        part_gpt fat ext2 normal linux echo search search_label configfile test loadenv
install -m 644 os/rauc/grub.cfg /mnt/rauc-esp/grub/grub.cfg
# Seed boot state: slot A good, B empty. RAUC rewrites these on every install/mark.
grub-editenv /mnt/rauc-esp/grubenv create
grub-editenv /mnt/rauc-esp/grubenv set ORDER="A B" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0

sync
echo "==> image: $OUT ($(du -h "$OUT" | cut -f1))"
