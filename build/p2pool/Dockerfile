# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64

ARG P2POOL_VERSION=v4.16
ARG P2POOL_HASH=1b03b2e4d4adfe488b2867eb85b57366fbaf8594a7f84cdbf13a3c8519159280

# Install runtime dependencies. socat (#278): the entrypoint bridges 127.0.0.1 -> the real monerod so
# p2pool's node RPC/ZMQ stay DIRECT while --socks5 routes only the sidechain over Tor (p2pool proxies
# everything but loopback when --socks5 is set).
RUN apt-get update && apt-get install -y \
    wget ca-certificates libgomp1 socat \
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