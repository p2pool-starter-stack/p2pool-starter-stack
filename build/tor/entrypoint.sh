#!/bin/sh
# Render torrc from the template, substituting the configurable bridge-subnet prefix (#180), then
# exec Tor. NETWORK_PREFIX defaults to the standard 172.28.0 base; pithead derives it from
# network.subnet in config.json and docker-compose passes it into this container's environment.
# Rendered to /tmp because the unprivileged 'tor' user can't write /etc/tor; regenerated each start.
set -eu

: "${NETWORK_PREFIX:=172.28.0}"
# TORRC_TEMPLATE is a test seam so the shell suite can render against build/tor/torrc.template; the
# container always uses the baked-in default.  # ponytail: default unchanged, only overridden in tests
: "${TORRC_TEMPLATE:=/etc/tor/torrc.template}"
# TORRC_OUT is the matching seam for the RENDERED file (#1104). Without it the shell suite's tor
# stub reads a host-global /tmp/torrc, which is the only unsandboxed path in an ~8000-line suite
# where every other fixture gets its own mktemp -d — so two concurrent runs race on one file and
# produce a false RED in the hidden-service assertions, whose natural remedy is "re-run until green".
# The DEFAULT MUST STAY /tmp/torrc: tier-3 assertions in tests/integration/run.sh read this path
# inside the running container.  # ponytail: default unchanged, only overridden in tests
: "${TORRC_OUT:=/tmp/torrc}"

sed "s/__NETWORK_PREFIX__/${NETWORK_PREFIX}/g" "$TORRC_TEMPLATE" >"$TORRC_OUT"

# Node inbound hidden services (#103): the bundled monerod and Tari containers only start under
# their compose profiles, so publish each node's onion only then — in remote mode the onion would
# be an address with nothing behind it. The gate is the profile list itself (passed through from
# pithead's rendered .env by docker-compose.yml), so it cannot drift from which nodes actually run.
# Unset (a bare `docker compose` with no .env) means no profiles, so no bundled node and no onion.
case ",${COMPOSE_PROFILES:-}," in
*,local_node,*)
    cat >>"$TORRC_OUT" <<EOF

# Monero P2P Hidden Service
HiddenServiceDir /var/lib/tor/monero/
HiddenServicePort 18080 ${NETWORK_PREFIX}.26:18084
EOF
    ;;
esac
case ",${COMPOSE_PROFILES:-}," in
*,local_tari,*)
    cat >>"$TORRC_OUT" <<EOF

# Tari Base Node Hidden Service
HiddenServiceDir /var/lib/tor/tari/
HiddenServicePort 18189 ${NETWORK_PREFIX}.27:18189
EOF
    ;;
esac

# Dashboard hidden service (#343): opt-in, default off. Appended only when pithead sets the flag, so
# the default stack publishes exactly the three mining onions and nothing else. The target is the
# bridge gateway (NETWORK_PREFIX.1), where host-networked Caddy binds the auth-gated onion vhost —
# NOT the dashboard's raw :8000 (which has no auth of its own). Tor supplies the transport encryption.
# Two ports: 80 (plain HTTP) and 443 (HTTPS, self-signed) — Caddy serves both, so Tor Browser's
# default http->https upgrade lands on the working :443 instead of a refused connection (#343).
if [ "${DASHBOARD_ONION_ENABLED:-false}" = "true" ]; then
    cat >>"$TORRC_OUT" <<EOF

# Dashboard Hidden Service (#343)
HiddenServiceDir /var/lib/tor/dashboard/
HiddenServicePort 80 ${NETWORK_PREFIX}.1:80
HiddenServicePort 443 ${NETWORK_PREFIX}.1:443
EOF
fi

exec tor -f "$TORRC_OUT"
