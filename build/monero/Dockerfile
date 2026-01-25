FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    wget bzip2 ca-certificates curl gettext-base \
    && rm -rf /var/lib/apt/lists/*

ARG MONERO_VERSION=v0.18.4.5
ARG MONERO_HASH=423b49f3658e29f70a1d971667dec924c7ee7a107cfc93440456e28500b471a6

RUN wget -O monero.tar.bz2 https://downloads.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2 \
    && echo "${MONERO_HASH}  monero.tar.bz2" | sha256sum -c - \
    && tar xvjf monero.tar.bz2 \
    && mv monero-*-linux-gnu-*/monerod /usr/local/bin/monerod \
    && chmod +x /usr/local/bin/monerod \
    && rm -rf monero*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]