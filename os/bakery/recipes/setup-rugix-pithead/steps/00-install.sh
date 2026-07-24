#!/bin/bash
set -euo pipefail
apt-get install -y fdisk parted
install -D -m 644 "${RECIPE_DIR}/files/bootstrapping.toml" /etc/rugix/bootstrapping.toml
install -D -m 644 "${RECIPE_DIR}/files/state-data.toml" /etc/rugix/state/data.toml
