#!/bin/sh
set -eu

# Optional stratum-miner auth (#152). Compose's command LIST can't omit an element: a
# `${PROXY_STRATUM_PASSWORD:+--access-password=...}` item renders a stray '' positional arg when the
# password is unset (xmrig-proxy logs `unsupported non-option argument ''`). So the flag is passed as
# an env var and appended HERE instead — an empty/unset value appends nothing, no stray arg. Mirrors
# p2pool's entrypoint word-splitting of $P2POOL_FLAGS.
if [ -n "${PROXY_STRATUM_PASSWORD:-}" ]; then
    set -- "$@" "--access-password=$PROXY_STRATUM_PASSWORD"
fi

exec xmrig-proxy "$@"
