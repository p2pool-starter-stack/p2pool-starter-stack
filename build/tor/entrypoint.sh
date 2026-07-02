#!/bin/sh
# Render torrc from the template, substituting the configurable bridge-subnet prefix (#180), then
# exec Tor. NETWORK_PREFIX defaults to the standard 172.28.0 base; pithead derives it from
# network.subnet in config.json and docker-compose passes it into this container's environment.
# Rendered to /tmp because the unprivileged 'tor' user can't write /etc/tor; regenerated each start.
set -eu

: "${NETWORK_PREFIX:=172.28.0}"

sed "s/__NETWORK_PREFIX__/${NETWORK_PREFIX}/g" /etc/tor/torrc.template >/tmp/torrc

exec tor -f /tmp/torrc
