#!/bin/bash
set -euo pipefail
install -D -m 644 "${RECIPE_DIR}/files/bootstrapping.toml" /etc/rugix/bootstrapping.toml
install -D -m 644 "${RECIPE_DIR}/files/state-data.toml" /etc/rugix/state/data.toml
# rugix-ctrl (this recipe's dependency) drops an initramfs hook; rebuild the initrd so the copied
# /initrd.img carries the A/B boot integration, not the rootfs-build-time initrd.
update-initramfs -u -k all
