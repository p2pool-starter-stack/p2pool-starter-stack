#!/usr/bin/env bash
#
# bench-verify-egress.sh — prove each container's ACTUAL egress posture for the #256 benchmark
# (and as a live privacy-leak check generally). It reads `/proc/net/tcp` from inside each container
# (root there, so no host sudo) and reports every ESTABLISHED connection to a **public** IP — i.e. one
# that bypasses the Tor SOCKS at <bridge>.25:9050 (a private 172.x address). Run ON the mining host.
#
#   tests/integration/benchmarks/bench-verify-egress.sh <tor|clearnet> [--dir STACK_DIR] [--prefix 172.28.0]
#
# Interpretation:
#   - `tor` arm  → EVERY app container must show 0 public connections (all egress via Tor). Only the
#                  `tor` container should reach public IPs (Tor relays). A non-zero app count = LEAK.
#   - `clearnet` → the mining-path containers (p2pool, xmrig-proxy while donating) SHOULD show direct
#                  public connections; monerod/tari staying at 0 confirms node-sync is still Tor
#                  (the benchmark holds those constant — see docs/benchmarks/tor-vs-clearnet.md).
#
# Ground-truth backstop (needs root, so run by hand): a WAN-interface capture should show NO mining
# traffic to non-Tor IPs in the tor arm —
#   sudo tcpdump -ni <wan> 'tcp and (port 18080 or portrange 37888-37890 or port 4247) and not host <tor-relays>'

set -uo pipefail

ARM="${1:-}"; case "$ARM" in tor|clearnet) shift ;; *) echo "usage: bench-verify-egress.sh <tor|clearnet> [--dir DIR] [--prefix P]" >&2; exit 2 ;; esac
DIR="/srv/code/pithead"; PREFIX="172.28.0"
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    DIR="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
APPS="monerod p2pool tari xmrig-proxy"

# Established (st=01) foreign IPv4s for a container that are PUBLIC (skip loopback/private/bridge/
# link-local — the Tor SOCKS lives in the private 172.16/12 range, so SOCKS-routed traffic is skipped).
# /proc/net/tcp `rem_address` is little-endian hex "IIIIIIII:PPPP"; decode with bash arithmetic so we
# don't depend on gawk/strtonum inside minimal images (only `cat` runs in the container).
public_conns() {  # <container-id>
    docker exec "$1" sh -c 'cat /proc/net/tcp 2>/dev/null' | while read -r _sl _local rem st _rest; do
        [ "$st" = "01" ] || continue
        local hip="${rem%:*}" hport="${rem#*:}" o1 o2 o3 o4
        o1=$((16#${hip:6:2})); o2=$((16#${hip:4:2})); o3=$((16#${hip:2:2})); o4=$((16#${hip:0:2}))
        case "$o1.$o2" in 10.*|127.*|0.*|169.254|192.168) continue ;; esac
        { [ "$o1" = 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; } && continue
        printf '%d.%d.%d.%d:%d\n' "$o1" "$o2" "$o3" "$o4" "$((16#$hport))"
    done
}

cid_of() { ( cd "$DIR" && docker compose ps -q "$1" 2>/dev/null | head -n1 ); }

echo "[verify-egress] arm=$ARM  stack=$DIR  tor-socks=${PREFIX}.25:9050"
fail=0
for c in $APPS; do
    cid=$(cid_of "$c"); [ -n "$cid" ] || { echo "  - $c: not running (skip)"; continue; }
    pub=$(public_conns "$cid" | sort -u); n=$(printf '%s' "$pub" | grep -c . || true)
    if [ "$ARM" = "tor" ]; then
        if [ "$n" -eq 0 ]; then echo "  ✓ $c: 0 direct public connections — all egress via Tor"
        else echo "  ✗ $c: $n DIRECT PUBLIC connection(s) — CLEARNET LEAK:"; printf '%s\n' "$pub" | sed 's/^/        /'; fail=1; fi
    else
        if [ "$n" -gt 0 ]; then echo "  ✓ $c: $n direct public connection(s) — clearnet, as expected for this arm"
        else echo "  · $c: 0 direct public connections (still Tor / idle — expected for monerod & tari)"; fi
    fi
done
tcid=$(cid_of tor); tn=$(public_conns "$tcid" | sort -u | grep -c . || true)
echo "  · tor: $tn external relay connection(s) (expected > 0 — this is the only container that should reach the internet)"

if [ "$ARM" = "tor" ] && [ "$fail" -ne 0 ]; then
    echo "[verify-egress] FAIL — clearnet leak(s) above; the 'all-Tor' arm is not clean." >&2; exit 1
fi
echo "[verify-egress] OK"
