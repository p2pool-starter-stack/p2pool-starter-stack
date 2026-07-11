#!/bin/sh
# Reach the stack's dashboard onion from an INDEPENDENT Tor client and report whether Caddy answered.
#
# A remote-user black-box probe: this container's tor builds its own circuits and reaches the onion
# over the public Tor network — it uses none of the stack's SOCKS proxy or plumbing. Getting an HTTP
# status back at all proves the full inbound path (hidden service -> Caddy) is live from outside; a
# 401 (Caddy's basic-auth challenge) counts as reachable, since we deliberately don't hold the
# dashboard login. Client auth is required to even establish the rendezvous when the onion is
# client-auth'd, so a green result also proves the client key is accepted.
#
# Env:
#   ONION_ADDR    the .onion hostname, no scheme          (required)
#   AUTH_FILE     path to a mounted client-auth line       (optional; enables client-auth)
#                 "<onion>:descriptor:x25519:<privkey>"    — as `pithead onion-client-key` emits
#   EXPECT_CODES  pipe-separated HTTP codes that count as reachable (default "200|401")
#   SCHEME        http|https                                (default https — the onion serves TLS, #360)
#   BOOT_TIMEOUT  seconds to wait for tor bootstrap         (default 120)
#   FETCH_TIMEOUT seconds to keep retrying the fetch        (default 120)
#
# Exit: 0 reachable (prints PROBE-OK), 1 unreachable (PROBE-FAIL), 2 tor never bootstrapped.
# Never prints the client key.
set -eu

: "${ONION_ADDR:?ONION_ADDR required}"
EXPECT_CODES="${EXPECT_CODES:-200|401}"
SCHEME="${SCHEME:-https}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-120}"

DATA="$(mktemp -d)"
chmod 700 "$DATA"
mkdir -p "$DATA/auth"
CFG="$DATA/torrc"
{
    echo "SocksPort 9050"
    echo "DataDirectory $DATA"
    echo "ClientOnionAuthDir $DATA/auth"
    echo "Log notice stdout"
} >"$CFG"

# Provision the client-auth private key (if the onion needs it) into ClientOnionAuthDir. Preferred
# path is stdin (AUTH_STDIN=1): it keeps the key out of `docker inspect` and off any shared
# filesystem, and works whatever uid the container runs as. AUTH_FILE is the mounted-file fallback.
# The key is never echoed; the file is 600.
AUTHF="$DATA/auth/dashboard.auth_private"
if [ "${AUTH_STDIN:-0}" = "1" ]; then
    head -n1 >"$AUTHF"
    chmod 600 "$AUTHF"
elif [ -n "${AUTH_FILE:-}" ] && [ -s "$AUTH_FILE" ]; then
    cp "$AUTH_FILE" "$AUTHF"
    chmod 600 "$AUTHF"
fi

tor -f "$CFG" >"$DATA/tor.log" 2>&1 &
TORPID=$!
trap 'kill "$TORPID" 2>/dev/null || true' EXIT INT TERM

# Wait for a fully-bootstrapped client before any fetch — a partial bootstrap can't reach an onion.
waited=0
while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
    grep -q "Bootstrapped 100%" "$DATA/tor.log" && break
    sleep 2
    waited=$((waited + 2))
done
if ! grep -q "Bootstrapped 100%" "$DATA/tor.log"; then
    echo "PROBE-FAIL: tor did not bootstrap within ${BOOT_TIMEOUT}s"
    grep -iE "err|warn" "$DATA/tor.log" | tail -3 || true
    exit 2
fi

# Onion rendezvous can take a few attempts even once bootstrapped — retry until a code matches or we
# run out the clock. -k: the onion address itself authenticates the service; we're testing
# reachability, not the TLS chain (cert validity is a separate concern).
code=000
waited=0
while [ "$waited" -lt "$FETCH_TIMEOUT" ]; do
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 25 \
        --socks5-hostname 127.0.0.1:9050 "${SCHEME}://${ONION_ADDR}/" 2>/dev/null || echo 000)"
    case "$code" in
    000) : ;; # not reachable yet — keep retrying
    *) echo "$code" | grep -qE "^(${EXPECT_CODES})$" && break ;;
    esac
    sleep 5
    waited=$((waited + 5))
done

if echo "$code" | grep -qE "^(${EXPECT_CODES})$"; then
    echo "PROBE-OK: ${ONION_ADDR} reachable over Tor -> HTTP ${code}"
    exit 0
fi
echo "PROBE-FAIL: ${ONION_ADDR} -> HTTP ${code} (wanted ${EXPECT_CODES})"
exit 1
