#!/bin/bash
set -e

# Define paths for configuration management (overridable for testing).
TEMPLATE_PATH="${TEMPLATE_PATH:-/home/ubuntu/bitmonero.conf.template}"
CONFIG_PATH="${CONFIG_PATH:-/home/ubuntu/.bitmonero/bitmonero.conf}"
# Shared, dashboard-writable state dir (#234). The dashboard drops this marker once monerod has
# finished its clearnet initial sync and restarts the container; seeing it here means "the clearnet
# sync already completed — come up on Tor." Default matches the compose mount; overridable for tests.
CLEARNET_MARKER="${CLEARNET_MARKER:-/clearnet-state/monero.synced}"

# Optional clearnet initial sync (#183). DEFAULT OFF. For the fast clearnet sync window only, this
# makes monerod match the connectivity P2Pool v4.18 recommends for a clearnet node:
#   - strip the single `proxy=` line that forces ALL P2P over Tor → monerod dials its compiled-in
#     clearnet seed nodes (and the priority nodes below) directly, at clearnet speed instead of
#     crawling over bandwidth-capped Tor circuits.
#   - out-peers → 32 (P2Pool v4.18's clearnet recommendation; the Tor render uses 48, a circuit-
#     bandwidth workaround). in-peers stays 64 — the open-files cap, which is the rec we always honor.
#   - add P2Pool's recommended priority nodes for guaranteed-good peers + block templates. These are
#     CLEARNET hostnames, so they're added ONLY here: in Tor mode their resolution would leak a
#     clearnet DNS lookup tied to this host's IP (#161). Connections still arrive over clearnet,
#     which is exactly the exposure this opt-in window already accepts.
# `tx-proxy=tor,...` is LEFT IN PLACE so transaction broadcast stays on Tor (tx-origin privacy
# preserved) — and there's no tx broadcast during a sync anyway. The DNS blocklist / DNS
# checkpointing the rec also lists are MINING-time protections (bad-node bans, selfish-mining
# defense) that don't apply to a download-only sync; in Tor mining mode they'd leak DNS (#161), so
# we keep them off and rely on monerod's compiled-in checkpoints. The Tor render (the untouched
# template) restores every private default the moment the dashboard flips back.
# Kept as a function (portable sed, no in-place -e) so the shell test suite can exercise it directly.
apply_clearnet_initial_sync() {
    local cfg="$1" tmp="$1.tmp"
    sed -e '/^proxy=/d' -e 's/^out-peers=.*/out-peers=32/' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
    cat >>"$cfg" <<'PRIONODES'

# P2Pool v4.18 recommended priority nodes (clearnet sync window only — removed when flipped to Tor).
add-priority-node=p2pmd.xmrvsbeast.com:18080
add-priority-node=nodes.hashvault.pro:18080
PRIONODES
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
envsubst '${MONERO_NODE_USERNAME}${MONERO_NODE_PASSWORD}${MONERO_ONION_ADDRESS}${MONERO_PRUNE}${MONERO_PREP_THREADS}${MONERO_OUT_PEERS}${NETWORK_PREFIX}' <"$TEMPLATE_PATH" >"$CONFIG_PATH"

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
