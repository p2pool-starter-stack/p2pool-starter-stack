#!/bin/bash
set -euo pipefail

# P2Pool launcher. (mDNS/.local resolution was removed — point p2pool at an IP or a
# DNS-resolvable hostname; on a home LAN, use a DHCP reservation or static IP.)
#
# Extra flags arrive via $P2POOL_FLAGS (rendered by pithead: the pool-type flag + the #165 Tor SOCKS
# routing — e.g. "--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor"). We word-split it HERE
# because Docker Compose passes a `- ${VAR}` command item as ONE argument (no word-splitting), which
# would hand p2pool a single mangled flag. An empty value expands to nothing (no stray empty arg).
# Log the FINAL launch command (#273): makes the applied flags — notably the #165 `--socks5` Tor
# routing — auditable in `docker logs p2pool`, so a stale image silently dropping P2POOL_FLAGS shows
# up here (and `pithead doctor` fails on it) rather than leaking quietly.
echo "[p2pool-entrypoint] launching: p2pool $* ${P2POOL_FLAGS:-}"
# shellcheck disable=SC2086  # intentional word-splitting of the space-separated flag string
exec p2pool "$@" ${P2POOL_FLAGS:-}
