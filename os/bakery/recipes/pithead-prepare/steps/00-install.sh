#!/bin/bash
# Chroot step on the real rootfs. The image is built by exporting a Docker container, which leaves
# artifacts that break a real PID-1 boot — most critically /.dockerenv, which makes systemd think
# it is a container and refuse to run as init ("Attempted to kill init" panic). Umbrel does the
# same. Also drop the container resolv.conf so systemd-resolved owns it.
set -euo pipefail
rm -f /.dockerenv
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
