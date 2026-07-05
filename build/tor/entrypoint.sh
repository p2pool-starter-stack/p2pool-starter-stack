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

sed "s/__NETWORK_PREFIX__/${NETWORK_PREFIX}/g" "$TORRC_TEMPLATE" >/tmp/torrc

# Dashboard hidden service (#343): opt-in, default off. Appended only when pithead sets the flag, so
# the default stack publishes exactly the three mining onions and nothing else. The target is the
# bridge gateway (NETWORK_PREFIX.1), where host-networked Caddy binds the auth-gated onion vhost —
# NOT the dashboard's raw :8000 (which has no auth of its own). Tor supplies the transport encryption.
# Two ports: 80 (plain HTTP) and 443 (HTTPS, self-signed) — Caddy serves both, so Tor Browser's
# default http->https upgrade lands on the working :443 instead of a refused connection (#343).
if [ "${DASHBOARD_ONION_ENABLED:-false}" = "true" ]; then
    cat >>/tmp/torrc <<EOF

# Dashboard Hidden Service (#343)
HiddenServiceDir /var/lib/tor/dashboard/
HiddenServicePort 80 ${NETWORK_PREFIX}.1:80
HiddenServicePort 443 ${NETWORK_PREFIX}.1:443
EOF
fi

exec tor -f /tmp/torrc
