#!/bin/sh
# monerod RPC liveness check (#90).
#
# Reads the RPC credentials from the container's environment instead of taking them as
# arguments, so they are NOT baked into the compose `healthcheck.test` — where they would
# otherwise be readable via `docker inspect`. monerod serves RPC on localhost:18081 and requires
# digest auth when MONERO_NODE_USERNAME/MONERO_NODE_PASSWORD are set.
set -eu

curl -fsS --digest \
  -u "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
  -o /dev/null \
  http://localhost:18081/get_info
