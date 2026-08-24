#!/bin/sh
# Tor bootstrap healthcheck.
#
# The old check (`nc -z localhost 9050`) only confirmed the SOCKS port was *open*,
# which happens within ~1s — long before Tor has built circuits. Dependent services
# (tari, monerod) then started against a Tor that couldn't yet route, producing
# "Connectivity is OFFLINE" / "0/N successful peer syncs" on cold start.
#
# This instead asks Tor directly whether it has finished bootstrapping, via the
# cookie-authenticated control port, and is only healthy once it reports TAG=done.

set -eu

# The cookie path is fixed in the container. TOR_COOKIE_FILE is the test seam (#1372) — the same
# shape as entrypoint.sh's TORRC_OUT, and for the same reason: the shell suite has to drive this
# script for real, and it cannot write /var/lib/tor. Nothing sets it in production, so what ships
# is the default; the suite asserts that default is still spelled exactly this way.
COOKIE_FILE=${TOR_COOKIE_FILE:-/var/lib/tor/control_auth_cookie}
CONTROL_HOST=127.0.0.1
CONTROL_PORT=9051

# Control port not up yet, or cookie not written -> not ready.
[ -r "$COOKIE_FILE" ] || exit 1

# Cookie auth requires the raw 32-byte cookie hex-encoded in the AUTHENTICATE command.
COOKIE_HEX=$(xxd -p -c 256 "$COOKIE_FILE" | tr -d '\n')
[ -n "$COOKIE_HEX" ] || exit 1

# Authenticate, query bootstrap phase, then close. Healthy only at TAG=done (100%).
printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' "$COOKIE_HEX" |
    nc -w 3 "$CONTROL_HOST" "$CONTROL_PORT" |
    grep -q 'TAG=done'
