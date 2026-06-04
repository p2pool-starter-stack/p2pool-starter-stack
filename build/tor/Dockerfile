# Pinned by digest (#135). NOTE: still the floating `latest` tag — a follow-up could move this to a
# specific alpine version; the digest already makes the build reproducible regardless.
FROM alpine:latest@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

# Install Tor plus the tools the bootstrap healthcheck needs: netcat (talk to the
# control port) and xxd (hex-encode the auth cookie). --no-cache keeps the image small.
RUN apk add --no-cache tor netcat-openbsd xxd

# Copy the custom Tor configuration file
COPY torrc /etc/tor/torrc

# Control-port bootstrap healthcheck (see docker-compose.yml healthcheck)
COPY healthcheck.sh /usr/local/bin/tor-healthcheck.sh
RUN chmod +x /usr/local/bin/tor-healthcheck.sh

# Create the data directory and ensure the 'tor' user has ownership
# This is critical because we switch to a non-root user below
RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor

# Switch to the non-root 'tor' user for enhanced security
USER tor

# Set the container entrypoint to the Tor executable
ENTRYPOINT ["tor"]
# Default arguments: Use the specified configuration file
CMD ["-f", "/etc/tor/torrc"]
