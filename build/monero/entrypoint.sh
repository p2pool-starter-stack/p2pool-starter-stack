#!/bin/bash
set -e

# Define paths for configuration management (overridable for testing).
TEMPLATE_PATH="${TEMPLATE_PATH:-/root/bitmonero.conf.template}"
CONFIG_PATH="${CONFIG_PATH:-/root/.bitmonero/bitmonero.conf}"

# Optional clearnet initial sync (#183). DEFAULT OFF. Transforms an already-rendered config:
#   - strip the single `proxy=` line that forces ALL P2P over Tor → monerod then dials its
#     compiled-in clearnet seed nodes directly, so the initial block download runs at clearnet
#     speed instead of crawling over bandwidth-capped Tor circuits.
#   - lower out-peers from the Tor-tuned 48 to a clearnet-friendly 16 (48 was a circuit-bandwidth
#     workaround; on clearnet it over-connects and can stress home routers).
# `tx-proxy=tor,...` is intentionally LEFT IN PLACE, so transaction broadcast stays on Tor
# (tx-origin privacy preserved) — and there is no tx broadcast during a sync anyway. The only
# exposure is node-existence: this host's IP is briefly visible to the Monero P2P network.
# Kept as a function (portable sed, no in-place -e) so the shell test suite can exercise it
# directly without envsubst or a running monerod.
apply_clearnet_initial_sync() {
    local cfg="$1" tmp="$1.tmp"
    sed -e '/^proxy=/d' -e 's/^out-peers=.*/out-peers=16/' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# When sourced by the test harness (PITHEAD_TEST_SOURCE=1), expose the functions and stop —
# don't render or exec. `return` works when sourced; the `|| exit` guards a direct run.
if [ "${PITHEAD_TEST_SOURCE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Ensure the data directory exists
mkdir -p "$(dirname "$CONFIG_PATH")"

echo "Initializing Monero configuration from template..."

# Inject environment variables into the configuration template
# We explicitly list variables to avoid accidental substitution of system environment variables
envsubst '${MONERO_NODE_USERNAME}${MONERO_NODE_PASSWORD}${MONERO_ONION_ADDRESS}${MONERO_PRUNE}${MONERO_PREP_THREADS}${NETWORK_PREFIX}' < "$TEMPLATE_PATH" > "$CONFIG_PATH"

# Apply the optional clearnet initial-sync transform (#183) and warn loudly while it's active.
if [ "${MONERO_CLEARNET_SYNC:-false}" = "true" ]; then
    echo "=========================================================================="
    echo "WARNING: MONERO CLEARNET INITIAL SYNC IS ACTIVE (#183)"
    echo "  monerod P2P is running over CLEARNET to sync faster — this host's IP is"
    echo "  visible to the Monero P2P network for the sync window. Transaction"
    echo "  broadcast STAYS on Tor (tx-proxy), and wallets are never exposed."
    echo "  Set monero.clearnet_initial_sync=false and re-run './pithead apply'"
    echo "  once synced to return all P2P to Tor."
    echo "=========================================================================="
    apply_clearnet_initial_sync "$CONFIG_PATH"
fi

echo "Starting Monero Daemon (monerod)..."
# Execute the daemon process, replacing the current shell to ensure correct signal handling (SIGTERM)
exec monerod --config-file="$CONFIG_PATH" --non-interactive
