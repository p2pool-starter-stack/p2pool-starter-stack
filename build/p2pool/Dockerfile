# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:24.04@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54

ARG P2POOL_VERSION=v4.15.1
ARG P2POOL_HASH=efd8b23579774711a5b86743da980e0936b7c220894063296719116d7f9ba254

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    wget ca-certificates libgomp1 \
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

# Stratum-port liveness healthcheck (#90)
COPY healthcheck.sh /usr/local/bin/p2pool-healthcheck.sh
RUN chmod +x /usr/local/bin/p2pool-healthcheck.sh

WORKDIR /root

# Use the wrapper script as the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]