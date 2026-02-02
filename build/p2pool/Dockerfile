FROM ubuntu:24.04

# Define P2Pool version and SHA256 hash for binary verification
# Refer to https://github.com/SChernykh/p2pool/releases for validation
ARG P2POOL_VERSION=v4.13
ARG P2POOL_HASH=d02361ee5f18e3e53af79436af6dc1772b71aa5ad8582ad88b0764ae2c9289c3

# Install runtime dependencies
# 'libgomp1' is required for OpenMP support (multi-threading optimization)
RUN apt-get update && apt-get install -y \
    wget ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Download, verify integrity, and install the P2Pool binary
RUN wget -O p2pool.tar.gz https://github.com/SChernykh/p2pool/releases/download/${P2POOL_VERSION}/p2pool-${P2POOL_VERSION}-linux-x64.tar.gz \
    && echo "${P2POOL_HASH}  p2pool.tar.gz" | sha256sum -c - \
    && tar xzf p2pool.tar.gz \
    && mv p2pool-${P2POOL_VERSION}-linux-x64/p2pool /usr/local/bin/p2pool \
    && chmod +x /usr/local/bin/p2pool \
    && rm -rf p2pool*

WORKDIR /root
ENTRYPOINT ["p2pool"]
