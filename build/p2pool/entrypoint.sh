#!/bin/bash
set -euo pipefail

# P2Pool launcher. (mDNS/.local resolution was removed — point p2pool at an IP or a
# DNS-resolvable hostname; on a home LAN, use a DHCP reservation or static IP.)
#
# Extra flags arrive via $P2POOL_FLAGS (rendered by pithead: the pool-type flag + the #165 Tor SOCKS
# routing — e.g. "--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor"). We word-split it HERE
# because Docker Compose passes a `- ${VAR}` command item as ONE argument (no word-splitting), which
# would hand p2pool a single mangled flag. An empty value expands to nothing (no stray empty arg).
# #278: p2pool's --socks5 (#165 Tor sidechain routing) ALSO proxies the monerod RPC/ZMQ connection
# unless the node address is exempt. Up to v4.16 only LOOPBACK was exempt (json_rpc_request.cpp /
# util.cpp is_localhost), so a private Docker node IP (e.g. 172.28.0.26) got dialled THROUGH Tor —
# which can't reach a private IP → "get_info ... empty response", no block template, no mining.
# v4.18 widened the RPC-leg exemption to any private address (json_rpc_request.cpp:250
# is_private_address, verified vs p2pool v4.18), which makes this bridge belt-and-braces for the
# node RPC/ZMQ — kept because the merge-mine leg below still needs its twin, and loopback stays
# exempt in every version, so the bridge costs nothing and survives an upstream narrowing. When the
# Tor proxy is on, bridge 127.0.0.1 -> the real node with socat and repoint --host at loopback: the
# node RPC/ZMQ then stay DIRECT (socat is a plain TCP forward, not p2pool's proxy) while the
# sidechain P2P still rides --socks5 over Tor. The socat hops (loopback -> node) are intra-stack,
# allowed by the #270 firewall (subnet -> 172.16/12).
if printf '%s' "${P2POOL_FLAGS:-}" | grep -q -- '--socks5'; then
    _node="" _rpc="18081" _zmq="18083" _prev=""
    for _a in "$@"; do
        case "$_prev" in --host) _node="$_a" ;; --rpc-port) _rpc="$_a" ;; --zmq-port) _zmq="$_a" ;; esac
        _prev="$_a"
    done
    case "$_node" in
    "" | 127.0.0.1 | ::1 | localhost) : ;; # already loopback (or p2pool's 127.0.0.1 default) — nothing to bridge
    *)
        echo "[p2pool-entrypoint] Tor on (#278): bridging 127.0.0.1 -> $_node for monerod RPC($_rpc)/ZMQ($_zmq) so the node stays DIRECT (p2pool only exempts loopback from --socks5)."
        socat "TCP-LISTEN:$_rpc,bind=127.0.0.1,fork,reuseaddr" "TCP:$_node:$_rpc" &
        socat "TCP-LISTEN:$_zmq,bind=127.0.0.1,fork,reuseaddr" "TCP:$_node:$_zmq" &
        _args=()
        _skip=0
        for _a in "$@"; do
            if [ "$_skip" = 1 ]; then
                _args+=("127.0.0.1")
                _skip=0
                continue
            fi
            _args+=("$_a")
            [ "$_a" = "--host" ] && _skip=1
        done
        set -- "${_args[@]}"
        ;;
    esac

    # Same trap, one leg further (#278 covered monerod only): p2pool's MergeMiningClientTari reaches
    # the Tari base node via TCPServer::connect_to_peer, which only skips the SOCKS5 proxy for a
    # LOOPBACK IP literal (no_proxy = m_addressType != DomainName && is_localhost(); verified vs
    # p2pool v4.18 src/tcp_server.cpp:425 — v4.18's private-address exemption covers the node RPC
    # leg only, NOT this one). So `--merge-mine tari://<private-docker-ip>:18142`
    # is dialled THROUGH Tor, which rejects RFC1918 ("Rejecting SOCKS request ... to private address")
    # → the gRPC channel_state sticks at TRANSIENT_FAILURE and no Tari is merge-mined. Same remedy:
    # bridge 127.0.0.1 -> the real node and rewrite the URL host to the 127.0.0.1 IP literal (NOT
    # "localhost" — that parses as a DomainName and would still be proxied). The merge-mine P2P egress
    # is unaffected; only this local gRPC leg is moved back onto loopback.
    _mm="" _prev=""
    for _a in "$@"; do
        [ "$_prev" = "--merge-mine" ] && {
            _mm="$_a"
            break
        }
        _prev="$_a"
    done
    case "$_mm" in
    tari://*)
        _mmhp="${_mm#tari://}" # HOST:PORT
        _mmhost="${_mmhp%:*}" _mmport="${_mmhp##*:}"
        case "$_mmhost" in
        "" | 127.0.0.1 | ::1 | localhost) : ;; # already loopback — nothing to bridge
        *)
            echo "[p2pool-entrypoint] Tor on (#278): bridging 127.0.0.1 -> $_mmhost for Tari merge-mine gRPC($_mmport) so it stays DIRECT (p2pool only exempts loopback from --socks5)."
            socat "TCP-LISTEN:$_mmport,bind=127.0.0.1,fork,reuseaddr" "TCP:$_mmhost:$_mmport" &
            _args=()
            for _a in "$@"; do
                if [ "$_a" = "$_mm" ]; then _args+=("tari://127.0.0.1:$_mmport"); else _args+=("$_a"); fi
            done
            set -- "${_args[@]}"
            ;;
        esac
        ;;
    esac
fi

# Log the FINAL launch command (#273): makes the applied flags — notably the #165 `--socks5` Tor
# routing — auditable in `docker logs p2pool`, so a stale image silently dropping P2POOL_FLAGS shows
# up here (and `pithead doctor` fails on it) rather than leaking quietly. After the #278 block above so
# it reflects the rewritten --host.
echo "[p2pool-entrypoint] launching: p2pool $* ${P2POOL_FLAGS:-}"
# shellcheck disable=SC2086  # intentional word-splitting of the space-separated flag string
exec p2pool "$@" ${P2POOL_FLAGS:-}
