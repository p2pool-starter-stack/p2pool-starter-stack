#!/usr/bin/env bash
# Build the pithead-os appliance image with RAUC as the updater (bake-off candidate B).
#
# This is the work Rugix Bakery does for us: RAUC is only an updater, so partitioning, filesystem
# creation, slot population, bootloader install and boot-state seeding are all ours. Consumes the
# SAME rootfs tarball as the Rugix candidate (os/build-image.sh stages it), so the comparison is
# updater-only.
#
#   os/rauc/mkimage.sh [--dev] [OUT_PATH]
#
# Signing: a release build must name the key (PITHEAD_RAUC_CERT + PITHEAD_RAUC_KEY); --dev
# auto-generates a throwaway CN=pithead-dev key for local/bench work. See resolve_signing_material
# in populate-slot.sh and the custody runbook in docs/dev/release-server.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

# --dev marks the build as throwaway (auto-gen allowed), mirroring build-image.sh --ssh for the
# debug variant; the first non-flag arg is the output path.
DEV=0
OUT=""
for arg in "$@"; do
    case "$arg" in
    --dev) DEV=1 ;;
    *) [ -z "$OUT" ] && OUT="$arg" ;;
    esac
done
OUT="${OUT:-os/rauc/build/system.img}"
# Only the ESP + slot A ship. systemd-repart creates slot B and /data on the target machine's
# real disk at first boot, so the image does not carry gigabytes of zeros and an /data sized
# for the image rather than the disk. 5 GiB covers 256M ESP + a 4 GiB slot + alignment.
#
# Slots are 4 GiB, and the number is load-bearing: repart is transactional, so a boot medium
# must fit ESP + BOTH slots + data's 4 GiB minimum or NOTHING is created and the machine drops
# to an emergency shell. At 4 GiB per slot the whole layout needs ~12.5 GiB — a real 16 GB
# stick (14.9 GiB) works. At 8 GiB it needed ~20.5 GiB and a 16 GB stick failed to boot.
SIZE_GIB="${PITHEAD_IMAGE_GIB:-5}"
TARBALL="os/build/pithead-root.tar"
# shellcheck source=os/rauc/populate-slot.sh
. os/rauc/populate-slot.sh

[ -s "$TARBALL" ] || {
    echo "missing $TARBALL — run os/build-image.sh first to stage the rootfs" >&2
    exit 2
}

# The keyring baked into slot A is the fleet's update trust root. Resolve it before anything heavy
# so a release build with no key stops immediately, not after minutes of imaging.
resolve_signing_material "$DEV" || exit $?
mkdir -p "$(dirname "$OUT")"

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
    -n 2:0:+4G -t 2:8300 -c 2:system-a "$OUT" >/dev/null

LOOP=$(losetup -Pf --show "$OUT")
cleanup() {
    umount -R /mnt/rauc-sys /mnt/rauc-esp 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# losetup -P returns before the kernel/udev publish the partition nodes, and the gap widens
# under loop-device churn (a KVM battery running beside a release build). Without this wait the
# first mkfs fails with "unable to open ${LOOP}p1: No such device or address" — and a plain
# retry succeeds, which is exactly how it stays invisible until release day. One guarded wait:
# settle udev, then poll briefly for both nodes.
udevadm settle 2>/dev/null || true
for _ in {1..25}; do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && break
    sleep 0.2
done
[ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] || {
    echo "partition nodes for $LOOP never appeared after losetup -P" >&2
    exit 1
}

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
        part_gpt fat ext2 normal linux echo search search_label configfile test loadenv regexp probe
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
