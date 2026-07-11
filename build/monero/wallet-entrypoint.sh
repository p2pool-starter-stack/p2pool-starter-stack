#!/bin/bash
# View-only payout-confirmation wallet (#381).
#
# Runs monero-wallet-rpc against the LOCAL monerod, scan-only: the wallet is generated from the
# operator's PRIVATE VIEW KEY with an empty spend key, so it can see incoming payouts but CANNOT
# spend. The view key is written to a JSON file on tmpfs and handed to --generate-from-json — it is
# NEVER put on the command line, where `docker inspect` / `ps` would expose it (#90 discipline,
# same as monerod's RPC creds). First run creates the wallet from keys at PAYOUT_SCAN_HEIGHT; later
# runs reopen the existing wallet file from the named volume.
set -eu

WALLET_DIR="${WALLET_DIR:-/home/ubuntu/wallets}"
WALLET_FILE="$WALLET_DIR/payout-wallet"
GEN_JSON="${GEN_JSON:-/tmp/gen.json}" # tmpfs; holds the view key for the create-from-keys step only
DAEMON_ADDRESS="${MONERO_NODE_HOST:-127.0.0.1}:${MONERO_RPC_PORT:-18081}"

# Resolve the restore height: an explicit number is used verbatim; "auto"/empty means "start at the
# daemon's current height" (fetched via get_info) so a fresh wallet doesn't rescan years of chain
# for payout history that predates the feature. A pruned node scans fine — outputs are never pruned.
resolve_scan_height() {
    local want="${PAYOUT_SCAN_HEIGHT:-auto}"
    case "$want" in
    '' | auto)
        curl -fsS --digest -u "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
            "http://$DAEMON_ADDRESS/get_info" 2>/dev/null |
            grep -o '"height": *[0-9]*' | grep -o '[0-9]*' | head -1
        ;;
    *) printf '%s\n' "$want" ;;
    esac
}

# When sourced by the shell test harness, expose the functions and stop — don't render or exec.
if [ "${PITHEAD_TEST_SOURCE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

mkdir -p "$WALLET_DIR"

# Shared server flags. --rpc-login (dashboard→wallet-rpc) authenticates the loopback-published RPC so
# even a mining-net peer that reaches the bridge IP can't read payout history; --daemon-login is the
# monerod RPC cred (same value p2pool already passes on its command line). Bind 0.0.0.0 so the
# 127.0.0.1:18082 host publish works; the rpc-login + loopback-only publish is the access control.
set -- \
    --daemon-address "$DAEMON_ADDRESS" \
    --daemon-login "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
    --trusted-daemon \
    --rpc-bind-ip 0.0.0.0 --confirm-external-bind \
    --rpc-bind-port 18082 \
    --rpc-login "${WALLET_RPC_USERNAME:-wallet}:${WALLET_RPC_PASSWORD:-}" \
    --password "" \
    --log-level 0 \
    --non-interactive

if [ ! -f "$WALLET_FILE" ]; then
    height="$(resolve_scan_height)"
    [ -n "$height" ] || height=0
    echo "Creating view-only payout wallet at restore height $height (#381)..."
    # The view key lives ONLY in this tmpfs file, never on argv. umask 077 so it's owner-only.
    (
        umask 077
        cat >"$GEN_JSON" <<EOF
{
  "version": 1,
  "filename": "$WALLET_FILE",
  "scan_from_height": $height,
  "password": "",
  "address": "${MONERO_WALLET_ADDRESS:-}",
  "viewkey": "${MONERO_VIEW_KEY:-}",
  "spendkey": ""
}
EOF
    )
    # --generate-from-json creates + opens the wallet, then keeps serving the RPC.
    exec monero-wallet-rpc "$@" --generate-from-json "$GEN_JSON"
fi

echo "Opening existing view-only payout wallet (#381)..."
exec monero-wallet-rpc "$@" --wallet-file "$WALLET_FILE"
