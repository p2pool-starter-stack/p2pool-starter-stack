#!/bin/bash
set -e
GEN_CONFIG="/root/.bitmonero/bitmonero.conf"

echo "Generating bitmonero.conf from template..."
mkdir -p /root/.bitmonero

envsubst '${MONERO_NODE_USERNAME}${MONERO_NODE_PASSWORD}${MONERO_ONION_ADDRESS}' < /root/bitmonero.conf.template > "$GEN_CONFIG"

echo "Starting Monerod with config at $GEN_CONFIG..."
exec monerod --config-file="$GEN_CONFIG" --non-interactive