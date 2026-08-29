# Pinned to a named minor version by digest (#135, #373). The digest is authoritative; the tag
# names the Alpine minor line (3.24) so Dependabot's patch-update policy has a real version to track.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# Install Tor plus the tools the bootstrap healthcheck needs: netcat (talk to the
# control port) and xxd (hex-encode the auth cookie). --no-cache keeps the image small.
# --upgrade names the base's own openssl libs so they follow the distro's security repo: the
# digest-pinned base can lag a published fix until upstream rebuilds the image, and that lag
# closed the CVE gate base-wide on 2026-08-28 (CVE-2026-14456, #1438).
RUN apk add --no-cache --upgrade libcrypto3 libssl3 tor netcat-openbsd xxd

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
