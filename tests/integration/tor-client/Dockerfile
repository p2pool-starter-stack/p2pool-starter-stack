# Independent Tor client for black-box onion-reachability tests (tier-4).
#
# Shares NOTHING with the stack: its own tor daemon, its own circuits, its own image. It reaches the
# stack's published onion over the REAL Tor network exactly as a remote user's Tor Browser would —
# so a green result proves the whole inbound path (tor hidden service -> Caddy -> client-auth ->
# dashboard) works from outside the trust boundary, using none of the stack's own tooling.
#
# Base pinned by digest (supply-chain policy, #282). Not a release image — built on the bench by the
# tier-4 harness, never pushed.
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

# tor: the client daemon. curl: speaks SOCKS5 natively (--socks5-hostname resolves the .onion
# through Tor). ca-certificates: validate the onion's HTTPS chain when we don't pass -k.
RUN apk add --no-cache tor curl ca-certificates

COPY probe.sh /usr/local/bin/probe.sh
RUN chmod 0755 /usr/local/bin/probe.sh

# Drop privileges — the probe needs no root (tor runs fine as an unprivileged user with a tmpdir).
USER tor
ENTRYPOINT ["/usr/local/bin/probe.sh"]
