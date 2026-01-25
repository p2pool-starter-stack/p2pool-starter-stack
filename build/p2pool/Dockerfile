FROM ubuntu:24.04
ARG P2POOL_VERSION=v4.13
RUN apt-get update && apt-get install -y wget ca-certificates libgomp1 && rm -rf /var/lib/apt/lists/*

RUN wget https://github.com/SChernykh/p2pool/releases/download/${P2POOL_VERSION}/p2pool-${P2POOL_VERSION}-linux-x64.tar.gz \
    && tar xzf p2pool-${P2POOL_VERSION}-linux-x64.tar.gz \
    && mv p2pool-${P2POOL_VERSION}-linux-x64/p2pool /usr/local/bin/p2pool \
    && chmod +x /usr/local/bin/p2pool \
    && rm -rf p2pool-*

WORKDIR /root
ENTRYPOINT ["p2pool"]
