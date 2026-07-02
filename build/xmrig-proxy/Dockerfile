# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:24.04@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54

# Define XMRig Proxy version and SHA256 hash for binary verification
# Refer to https://github.com/xmrig/xmrig-proxy/releases for validation
ARG XMRIG_PROXY_VERSION=6.26.0
ARG XMRIG_PROXY_HASH=73cceb10be474ba8ce20faddb9d2c6af0cb50bce84e72f7d36a326f7147c01c4

# Install system dependencies required for downloading and verifying the binary
RUN apt-get update && apt-get install -y \
    wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download, verify integrity, and install the XMRig Proxy binary
RUN wget -O xmrig-proxy.tar.gz https://github.com/xmrig/xmrig-proxy/releases/download/v${XMRIG_PROXY_VERSION}/xmrig-proxy-${XMRIG_PROXY_VERSION}-linux-static-x64.tar.gz \
    && echo "${XMRIG_PROXY_HASH}  xmrig-proxy.tar.gz" | sha256sum -c - \
    && tar xzf xmrig-proxy.tar.gz \
    && mv xmrig-proxy-${XMRIG_PROXY_VERSION}/xmrig-proxy /usr/local/bin/xmrig-proxy \
    && chmod +x /usr/local/bin/xmrig-proxy \
    && rm -rf xmrig-proxy*

# Run non-root (#255) — the easy win: pure network proxy, no bind-mounts, already cap_drop:[ALL]
# + no-new-privileges in compose. Reuse ubuntu:24.04's 'ubuntu' user (uid 1000) and give it a
# writable home as the cwd in case xmrig-proxy drops a config/log there.
RUN install -d -o ubuntu -g ubuntu /home/ubuntu
WORKDIR /home/ubuntu
USER ubuntu
ENTRYPOINT ["xmrig-proxy"]
