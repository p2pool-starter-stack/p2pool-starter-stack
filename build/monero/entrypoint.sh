#!/bin/bash
set -e

# Define paths for configuration management (overridable for testing).
TEMPLATE_PATH="${TEMPLATE_PATH:-/root/bitmonero.conf.template}"
CONFIG_PATH="${CONFIG_PATH:-/root/.bitmonero/bitmonero.conf}"
# Shared, dashboard-writable state dir (#234). The dashboard drops this marker once monerod has
# finished its clearnet initial sync and restarts the container; seeing it here means "the clearnet
# sync already completed — come up on Tor." Default matches the compose mount; overridable for tests.
CLEARNET_MARKER="${CLEARNET_MARKER:-/clearnet-state/monero.synced}"

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

# True when monerod should sync over clearnet NOW: the flag is on AND the auto-transition marker is
# absent (#234). Once the dashboard marks the clearnet sync complete, this is false and monerod
# comes back up Tor-only — and stays there across restarts/`apply`, so a node is never silently
# re-exposed. Kept as a function for direct unit testing.
clearnet_sync_active() {
    [ "${MONERO_CLEARNET_SYNC:-false}" = "true" ] && [ ! -f "$CLEARNET_MARKER" ]
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
if clearnet_sync_active; then
    echo "=========================================================================="
    echo "WARNING: MONERO CLEARNET INITIAL SYNC IS ACTIVE (#183)"
    echo "  monerod P2P is running over CLEARNET to sync faster — this host's IP is"
    echo "  visible to the Monero P2P network for the sync window. Transaction"
    echo "  broadcast STAYS on Tor, and wallets are never exposed. The dashboard"
    echo "  switches monerod back to Tor automatically once the chain is synced (#234)."
    echo "=========================================================================="
    apply_clearnet_initial_sync "$CONFIG_PATH"
elif [ "${MONERO_CLEARNET_SYNC:-false}" = "true" ]; then
    echo "Monero clearnet initial sync already completed (#234) — starting Tor-only."
fi

echo "Starting Monero Daemon (monerod)..."
# Execute the daemon process, replacing the current shell to ensure correct signal handling (SIGTERM)
exec monerod --config-file="$CONFIG_PATH" --non-interactive
