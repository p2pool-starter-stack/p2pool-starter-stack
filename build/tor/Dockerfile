FROM alpine:latest

# Install Tor and Netcat (useful for health checks and debugging)
# We use --no-cache to keep the image size minimal
RUN apk add --no-cache tor netcat-openbsd

# Copy the custom Tor configuration file
COPY torrc /etc/tor/torrc

# Create the data directory and ensure the 'tor' user has ownership
# This is critical because we switch to a non-root user below
RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor

# Switch to the non-root 'tor' user for enhanced security
USER tor

# Set the container entrypoint to the Tor executable
ENTRYPOINT ["tor"]
# Default arguments: Use the specified configuration file
CMD ["-f", "/etc/tor/torrc"]
