# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

# Install system dependencies required for downloading, verifying, and configuring the node
# 'gettext-base' provides 'envsubst' for template processing in entrypoint.sh
RUN apt-get update && apt-get install -y \
    wget bzip2 ca-certificates curl gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Define Monero version and SHA256 hash for binary verification
# Refer to https://www.getmonero.org/downloads/hashes.txt for validation
ARG MONERO_VERSION=v0.18.5.1
ARG MONERO_HASH=22a7dda7b0cb699fdd6b7674c3b4a4465b337cc98a54983523b759e1e7cc9958

# Download, verify integrity, and install the Monero daemon (monerod) plus monero-wallet-rpc.
# monero-wallet-rpc ships in the SAME CLI tarball (already verified by the hash above), so the
# view-only payout-confirmation wallet (#381) reuses this image with no new download or pin.
RUN wget -O monero.tar.bz2 https://downloads.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2 \
    && echo "${MONERO_HASH}  monero.tar.bz2" | sha256sum -c - \
    && tar xvjf monero.tar.bz2 \
    && mv monero-*-linux-gnu-*/monerod /usr/local/bin/monerod \
    && mv monero-*-linux-gnu-*/monero-wallet-rpc /usr/local/bin/monero-wallet-rpc \
    && chmod +x /usr/local/bin/monerod /usr/local/bin/monero-wallet-rpc \
    && rm -rf monero*

# Configure the entrypoint script for runtime initialization
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Payout-confirmation wallet-rpc entrypoint + healthcheck (#381). Same image, distinct entrypoint;
# the view key is read from a file the entrypoint writes to tmpfs, never from the command line (#90).
COPY wallet-entrypoint.sh /usr/local/bin/wallet-entrypoint.sh
COPY wallet-healthcheck.sh /usr/local/bin/wallet-healthcheck.sh
RUN chmod +x /usr/local/bin/wallet-entrypoint.sh /usr/local/bin/wallet-healthcheck.sh

# RPC liveness healthcheck — reads creds from env so they stay off the compose command line (#90)
COPY healthcheck.sh /usr/local/bin/monerod-healthcheck.sh
RUN chmod +x /usr/local/bin/monerod-healthcheck.sh

# Run non-root (#255). Reuse ubuntu:24.04's built-in 'ubuntu' user (uid 1000) and keep monerod's
# data under that user's home — /home/ubuntu/.bitmonero, which is also monerod's native
# $HOME/.bitmonero default. pithead chowns the blockchain bind-mount to match. The wallets dir
# (#381) is created here owned by ubuntu so its named volume inherits uid-1000 ownership.
RUN install -d -o ubuntu -g ubuntu /home/ubuntu /home/ubuntu/wallets
WORKDIR /home/ubuntu
USER ubuntu
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
