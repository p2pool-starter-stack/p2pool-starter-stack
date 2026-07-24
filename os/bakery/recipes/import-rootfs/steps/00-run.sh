#!/usr/bin/env bash
# Host-side step: RUGIX_ROOT_DIR is the empty system root; the tarball is the docker-exported
# rootfs staged by os/build-image.sh at <project>/build/pithead-root.tar.
set -euo pipefail
tar -xf "$RUGIX_PROJECT_DIR/build/pithead-root.tar" -C "$RUGIX_ROOT_DIR"
# docker export omits the pseudo-filesystem mount points; the bakery bind-mounts onto them.
mkdir -p "$RUGIX_ROOT_DIR/dev" "$RUGIX_ROOT_DIR/proc" "$RUGIX_ROOT_DIR/sys" "$RUGIX_ROOT_DIR/run" "$RUGIX_ROOT_DIR/tmp"
