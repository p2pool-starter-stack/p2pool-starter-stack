#!/bin/bash
set -e

# Define paths for configuration management
TEMPLATE_PATH="/root/bitmonero.conf.template"
CONFIG_PATH="/root/.bitmonero/bitmonero.conf"

# Ensure the data directory exists
mkdir -p /root/.bitmonero

echo "Initializing Monero configuration from template..."

# Inject environment variables into the configuration template
# We explicitly list variables to avoid accidental substitution of system environment variables
envsubst '${MONERO_NODE_USERNAME}${MONERO_NODE_PASSWORD}${MONERO_ONION_ADDRESS}' < "$TEMPLATE_PATH" > "$CONFIG_PATH"

echo "Starting Monero Daemon (monerod)..."
# Execute the daemon process, replacing the current shell to ensure correct signal handling (SIGTERM)
exec monerod --config-file="$CONFIG_PATH" --non-interactive