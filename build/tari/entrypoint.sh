#!/bin/bash
set -e
#
# Pithead Tari entrypoint wrapper (#183/#234).
#
# pithead renders the canonical *Tor* config (build/tari/config.toml, bind-mounted read-only-ish at
# $TARI_CONFIG_SRC). This wrapper produces the RUNTIME config the node actually uses, then chains to
# the upstream start_tari_app.sh (which honours WAIT_FOR_TOR and the base-path exactly as before).
#
# It NEVER mutates the canonical config — it copies it to a runtime path and, ONLY when an optional
# clearnet initial sync is active, transforms the copy. "Active" = the flag is on AND the dashboard's
# auto-transition marker is absent (#234); once the chain has synced over clearnet the dashboard
# drops that marker and restarts the container, so this start (and every later one) uses the
# untouched Tor config — the node returns to Tor on its own and stays there.
#
# Clearnet transform: flip the transport tor → tcp, re-enable the seeds.tari.com DNS seed (the
# bundled onion peer_seeds are unreachable without Tor), and stop advertising the onion. The host's
# IP is briefly visible to the Tari P2P network during the sync window.

TARI_CONFIG_SRC="${TARI_CONFIG_SRC:-/var/tari/config/config.toml}"
TARI_CONFIG_RUNTIME="${TARI_CONFIG_RUNTIME:-/tmp/tari-runtime-config.toml}"
CLEARNET_MARKER="${CLEARNET_MARKER:-/clearnet-state/tari.synced}"

# Apply the clearnet transform in place to an already-rendered (Tor) config copy. Portable sed
# (no in-place -e) so the shell test suite can exercise it directly.
apply_clearnet_initial_sync() {
    local cfg="$1" tmp="$1.tmp"
    sed -e 's/^type = "tor"/type = "tcp"/' \
        -e 's/^dns_seeds = \[\]/dns_seeds = ["seeds.tari.com"]/' \
        -e 's#^public_addresses = .*#public_addresses = []#' \
        "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# True when Tari should sync over clearnet NOW: flag on AND the auto-transition marker absent (#234).
clearnet_sync_active() {
    [ "${TARI_CLEARNET_SYNC:-false}" = "true" ] && [ ! -f "$CLEARNET_MARKER" ]
}

# Render the runtime config from the canonical Tor config, applying clearnet only while active.
render_tari_runtime_config() {
    local src="$1" runtime="$2"
    mkdir -p "$(dirname "$runtime")"
    cp "$src" "$runtime"
    if clearnet_sync_active; then
        apply_clearnet_initial_sync "$runtime"
    fi
}

# Sourced by the test harness (PITHEAD_TEST_SOURCE=1): expose the functions, render nothing, exec
# nothing. `return` works when sourced; the `|| exit` guards a direct run.
if [ "${PITHEAD_TEST_SOURCE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

render_tari_runtime_config "$TARI_CONFIG_SRC" "$TARI_CONFIG_RUNTIME"

if clearnet_sync_active; then
    echo "=========================================================================="
    echo "WARNING: TARI CLEARNET INITIAL SYNC IS ACTIVE (#183)"
    echo "  Tari P2P is running over CLEARNET (TCP + seeds.tari.com DNS seed) to sync"
    echo "  faster — this host's IP is visible to the Tari P2P network for the sync"
    echo "  window. The dashboard switches Tari back to Tor automatically once the"
    echo "  chain is synced (#234)."
    echo "=========================================================================="
elif [ "${TARI_CLEARNET_SYNC:-false}" = "true" ]; then
    echo "Tari clearnet initial sync already completed (#234) — starting Tor-only."
fi

# Hand off to the upstream entrypoint, pointing it at our runtime config. Everything else
# (WAIT_FOR_TOR, base-path, user handling) is unchanged.
export TARI_CONFIG="$TARI_CONFIG_RUNTIME"
exec start_tari_app.sh "$@"
