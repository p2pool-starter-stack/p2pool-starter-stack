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

# Stratum-over-TLS (#261): with the cert flags present, xmrig-proxy autodetects TLS vs cleartext
# per-connection on the same bind — no second port. Same append-here pattern as the password.
# TLS_MOUNT is fixed by the compose mount; the override exists so the shell suite can exercise
# this branch against a temp dir instead of a root-owned /tls.
TLS_MOUNT="${PROXY_TLS_MOUNT:-/tls}"
if [ "${PROXY_STRATUM_TLS:-false}" = "true" ] && [ -f "$TLS_MOUNT/cert.pem" ] && [ -f "$TLS_MOUNT/key.pem" ]; then
    set -- "$@" "--tls-cert=$TLS_MOUNT/cert.pem" "--tls-cert-key=$TLS_MOUNT/key.pem"
fi

exec xmrig-proxy "$@"
