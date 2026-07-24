#!/bin/bash
set -euo pipefail
install -D -m 644 "${RECIPE_DIR}/files/bootstrapping.toml" /etc/rugix/bootstrapping.toml
install -D -m 644 "${RECIPE_DIR}/files/state-data.toml" /etc/rugix/state/data.toml
install -D -m 644 "${RECIPE_DIR}/files/system.toml" /etc/rugix/system.toml
