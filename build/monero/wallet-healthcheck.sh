#!/bin/sh
# monero-wallet-rpc liveness check (#381).
#
# Reads the RPC credentials from the container's environment instead of taking them as arguments,
# so they are NOT baked into the compose `healthcheck.test` — where `docker inspect` could read
# them (#90). A JSON-RPC `get_version` proves the server is up and answering; it succeeds during
# the initial scan too, so the long start_period in compose tolerates first-run blockchain scanning
# without flapping unhealthy.
set -eu

curl -fsS --digest \
  -u "${WALLET_RPC_USERNAME:-wallet}:${WALLET_RPC_PASSWORD:-}" \
  -o /dev/null \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"0","method":"get_version"}' \
  http://localhost:18082/json_rpc
