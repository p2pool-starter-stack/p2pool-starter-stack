FROM ubuntu:24.04

ARG P2POOL_VERSION=v4.13
ARG P2POOL_HASH=d02361ee5f18e3e53af79436af6dc1772b71aa5ad8582ad88b0764ae2c9289c3

# Install dependencies, including avahi-utils for the resolve script
RUN apt-get update && apt-get install -y \
    wget ca-certificates libgomp1 \
    avahi-utils dbus \
    && rm -rf /var/lib/apt/lists/*

RUN wget -O p2pool.tar.gz https://github.com/SChernykh/p2pool/releases/download/${P2POOL_VERSION}/p2pool-${P2POOL_VERSION}-linux-x64.tar.gz \
    && echo "${P2POOL_HASH}  p2pool.tar.gz" | sha256sum -c - \
    && tar xzf p2pool.tar.gz \
    && mv p2pool-${P2POOL_VERSION}-linux-x64/p2pool /usr/local/bin/p2pool \
    && chmod +x /usr/local/bin/p2pool \
    && rm -rf p2pool*

# Copy the wrapper script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /root

# Use the wrapper script as the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]