#!/bin/bash
# Chroot step: the kernel/initrd symlinks live in the rootfs; the A/B boot partitions carry the
# actual files plus the second-stage script Rugix's first-stage GRUB chainloads.
set -euo pipefail
BOOT_DIR="${RUGIX_LAYER_DIR}/roots/boot"
mkdir -p "${BOOT_DIR}"
cp -L /vmlinuz "${BOOT_DIR}"
cp -L /initrd.img "${BOOT_DIR}"
cp "${RECIPE_DIR}/files/grub.cfg" "${BOOT_DIR}"
