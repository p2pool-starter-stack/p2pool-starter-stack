# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

# Install system dependencies required for downloading, verifying, and configuring the node
# 'gettext-base' provides 'envsubst' for template processing in entrypoint.sh
RUN apt-get update && apt-get install -y \
    wget bzip2 ca-certificates curl gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Define Monero version and SHA256 hash for binary verification
# Refer to https://www.getmonero.org/downloads/hashes.txt for validation
ARG MONERO_VERSION=v0.18.5.0
ARG MONERO_HASH=166ad93036f95f5abeba24c8670061be022c9238dba2e6a7587611a1d759e294

# Download, verify integrity, and install the Monero daemon (monerod)
RUN wget -O monero.tar.bz2 https://downloads.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2 \
    && echo "${MONERO_HASH}  monero.tar.bz2" | sha256sum -c - \
    && tar xvjf monero.tar.bz2 \
    && mv monero-*-linux-gnu-*/monerod /usr/local/bin/monerod \
    && chmod +x /usr/local/bin/monerod \
    && rm -rf monero*

# Configure the entrypoint script for runtime initialization
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# RPC liveness healthcheck — reads creds from env so they stay off the compose command line (#90)
COPY healthcheck.sh /usr/local/bin/monerod-healthcheck.sh
RUN chmod +x /usr/local/bin/monerod-healthcheck.sh

# Run non-root (#255). Reuse ubuntu:24.04's built-in 'ubuntu' user (uid 1000) and keep monerod's
# data under that user's home — /home/ubuntu/.bitmonero, which is also monerod's native
# $HOME/.bitmonero default. pithead chowns the blockchain bind-mount to match.
RUN install -d -o ubuntu -g ubuntu /home/ubuntu
WORKDIR /home/ubuntu
USER ubuntu
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
