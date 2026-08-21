# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG P2POOL_VERSION=v4.16
ARG P2POOL_HASH=1b03b2e4d4adfe488b2867eb85b57366fbaf8594a7f84cdbf13a3c8519159280

# Install runtime dependencies. socat (#278): the entrypoint bridges 127.0.0.1 -> the real monerod
# (node RPC/ZMQ) and the Tari base node (merge-mine gRPC) so those intra-stack legs stay DIRECT while
# --socks5 routes only the sidechain/merge-mine P2P over Tor (p2pool proxies everything but loopback
# when --socks5 is set, so a private Docker IP would otherwise be dialled through Tor and rejected).
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

# Run non-root (#255). Reuse ubuntu:24.04's built-in 'ubuntu' user (uid 1000) and keep p2pool's data
# under that user's home; pithead chowns the ${P2POOL_DATA_DIR} bind-mount (mapped to /home/ubuntu)
# + /stats to match, so the cache and data-api writes succeed as uid 1000. The IPC_LOCK/SYS_NICE
# caps granted in compose are not effective for a non-root process, but p2pool only needs them for
# mlock (covered by the unlimited memlock ulimit) and best-effort thread priority — neither is fatal.
RUN install -d -o ubuntu -g ubuntu /home/ubuntu
WORKDIR /home/ubuntu
USER ubuntu

# Use the wrapper script as the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
