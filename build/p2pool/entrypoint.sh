#!/bin/bash
set -euo pipefail

# tari.mode "off" (#1855, #1903): the host half (#1905) renders TARI_MODE=off and starts no Tari
# node, but this argv still carried `--merge-mine <url> <address>`, so P2Pool merge-mined against a
# node that was not there. Drop the triple, in either spelling (`--merge-mine URL ADDR`,
# `--merge-mine=URL ADDR`), BEFORE the Tor block below reads argv, so its merge-mine bridge cannot
# fire on it either. Only the literal "off" strips: unset (a 1.x .env that predates the key) or any
# other value leaves argv exactly as it arrived. A token starting with `-` in a value position is
# kept, the same rule _redact_argv applies: a malformed argv must not swallow the next flag NAME.
# Until #1905 lands nothing renders TARI_MODE, so at that tip this block strips nothing.
if [ "${TARI_MODE:-}" = off ]; then
    _args=() _drop=0 _dropped=0
    for _a in "$@"; do
        if [ "$_drop" -gt 0 ]; then
            case "$_a" in
            -*) _drop=0 ;;
            *)
                _drop=$((_drop - 1))
                continue
                ;;
            esac
        fi
        case "$_a" in
        --merge-mine) _drop=2 _dropped=1 ;;
        --merge-mine=*) _drop=1 _dropped=1 ;;
        *) _args+=("$_a") ;;
        esac
    done
    set -- "${_args[@]}"
    # Said only when something was removed: once the host also stops rendering the triple, an
    # unconditional line would claim a drop on every launch for the life of the container.
    [ "$_dropped" -eq 0 ] || echo "[p2pool-entrypoint] tari.mode off (#1903): not merge-mining, --merge-mine dropped from the launch."
fi

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

# Mask the secret VALUES on the launch line while keeping every flag NAME (#1586). #273 needs the
# applied flags to be VISIBLE — notably the #165 `--socks5` — and never needed their values, but the
# line printed both: the RPC login, both wallet addresses and the service onion. Two redactors
# downstream grew up cleaning after it (#1582 in the test harness, #1585 in `support-bundle`), which
# is the shape worth fixing at the source rather than a third time.
#
# Positional, and it has to be: the Tari address is a BARE argument after `--merge-mine <url>` (in
# EITHER spelling), so a name-keyed scrubber misses it by construction — how #1585 happened. Here the
# entrypoint knows which argument is which, so nothing has to guess. A token starting with `-` is
# passed through even in a value position: on a malformed argv that would otherwise swallow the next
# flag NAME, and a flag silently missing from this line is the one failure it exists to prevent.
_redact_argv() {
    local a out="" next=none
    for a in "$@"; do
        case "$next" in
        mask)
            next=none
            case "$a" in -*) : ;; *)
                out="$out [redacted]"
                continue
                ;;
            esac
            ;;
        mmurl) # the tari://host:port URL is routing, not a secret; the address AFTER it is
            out="$out $a"
            next=mask
            continue
            ;;
        esac
        case "$a" in
        --rpc-login | --wallet | --onion-address | --merge-mine=*)
            out="$out $a"
            next=mask
            ;;
        --rpc-login=* | --wallet=* | --onion-address=*) out="$out ${a%%=*}=[redacted]" ;;
        --merge-mine)
            out="$out $a"
            next=mmurl
            ;;
        *) out="$out $a" ;;
        esac
    done
    printf '%s' "${out# }"
}

# Log the FINAL launch command (#273): makes the applied flags — notably the #165 `--socks5` Tor
# routing — auditable in `docker logs p2pool`, so a stale image silently dropping P2POOL_FLAGS is
# visible here rather than leaking quietly. (`pithead doctor` catches the same staleness on its own,
# by reading the container's /proc/1/cmdline — `06-doctor.sh`; this line is the human-readable trail,
# not doctor's input.) After the #278 block above so it reflects the rewritten --host.
#
# Fold P2POOL_FLAGS in BEFORE both, so the line printed is provably the argv exec'd — one word-split,
# read twice — instead of a space-joined `$*` that only resembles it.
# shellcheck disable=SC2086  # intentional word-splitting of the space-separated flag string
set -- "$@" ${P2POOL_FLAGS:-}
echo "[p2pool-entrypoint] launching: p2pool $(_redact_argv "$@")"
exec p2pool "$@"
