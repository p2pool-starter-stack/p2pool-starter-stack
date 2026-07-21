#!/bin/sh
# monero-wallet-rpc health (#381, #718).
#
# RPC-up is the normal signal: a JSON-RPC get_version proves the server is answering. Credentials
# come from the environment, not argv, so `docker inspect` can't read them (#90).
#
# But during the INITIAL payout scan (#718) monero-wallet-rpc is single-threaded and heads-down for
# the whole scan — with the genesis default it is HOURS, and it refuses the RPC the entire time. A
# plain RPC check flaps unhealthy after the 2m start_period and spams stack-health alerts for the
# whole first scan. So: a marker file (`.payout-scanning`, written by the entrypoint on wallet
# creation, living in the volume so it survives recreates) means "still on the first scan" — while
# it exists, an unreachable RPC is treated as healthy. The first time the RPC answers, the scan has
# caught up, so we clear the marker and are strict from then on (a later RPC failure is a real
# fault, not scan tolerance).
set -u

WALLET_DIR="${WALLET_DIR:-/home/ubuntu/wallets}"
SCAN_MARKER="$WALLET_DIR/.payout-scanning"

rpc_up() {
    curl -fsS --digest \
        -u "${WALLET_RPC_USERNAME:-wallet}:${WALLET_RPC_PASSWORD:-}" \
        -o /dev/null \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_version"}' \
        http://localhost:18082/json_rpc
}

if rpc_up; then
    # Caught up and answering — retire the initial-scan grace so future RPC failures read as real.
    rm -f "$SCAN_MARKER" 2>/dev/null || true
    exit 0
fi

# RPC silent. Healthy only if we're still on the first scan (marker present); else it's a fault.
[ -f "$SCAN_MARKER" ] && exit 0
exit 1
