# Pinned to a named minor version by digest (#135, #373). The digest is authoritative; the tag
# names the Alpine minor line (3.24) so Dependabot's patch-update policy has a real version to track.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# Install Tor plus netcat, which the bootstrap healthcheck needs to talk to the control port.
# Deliberately NOT xxd: the healthcheck's `xxd -p -c 256` is served by busybox's own applet, so
# `apk add xxd` bought nothing but vim's CVE stream (#1372). --no-cache keeps the image small.
RUN apk add --no-cache tor netcat-openbsd

# Copy the Tor config TEMPLATE + the entrypoint that renders it: the bridge subnet prefix is
# substituted at container start (#180). The rendered torrc lands in /tmp (the unprivileged 'tor'
# user can't write /etc/tor).
COPY torrc.template /etc/tor/torrc.template
COPY entrypoint.sh /usr/local/bin/tor-entrypoint.sh
RUN chmod +x /usr/local/bin/tor-entrypoint.sh

# Control-port bootstrap healthcheck (see docker-compose.yml healthcheck)
COPY healthcheck.sh /usr/local/bin/tor-healthcheck.sh
RUN chmod +x /usr/local/bin/tor-healthcheck.sh

# Create the data directory and ensure the 'tor' user has ownership
# This is critical because we switch to a non-root user below
RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor

# Switch to the non-root 'tor' user for enhanced security
USER tor

# Render torrc from the template (subnet-prefix substitution), then exec Tor — see entrypoint.sh.
ENTRYPOINT ["/usr/local/bin/tor-entrypoint.sh"]
