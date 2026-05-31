FROM ubuntu:24.04

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

WORKDIR /root
ENTRYPOINT ["xmrig-proxy"]