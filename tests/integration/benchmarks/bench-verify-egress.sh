#!/usr/bin/env bash
#
# bench-verify-egress.sh — prove each container's ACTUAL egress posture: a live, runtime privacy-leak
# check (and the gate for the #256 benchmark arms). It reads `/proc/net/tcp` from inside each container
# (root there, so no host sudo) and reports every ESTABLISHED connection to a **public** IP — i.e. one
# that bypasses the Tor SOCKS at <bridge>.25:9050 (a private 172.x address). Run ON the mining host.
#
#   tests/integration/benchmarks/bench-verify-egress.sh <tor|clearnet> \
#       [--dir STACK_DIR] [--prefix 172.28.0] [--polls N] [--interval S] [--min-hits K]
#
# It POLLS `--polls` times (default 4) `--interval` seconds apart (default 10) and only flags a
# foreign IP seen in `--min-hits` or more polls (default 2) — so a post-restart STARTUP TRANSIENT
# (e.g. a brief direct dial before Tor circuits build / before p2pool's `--socks5` connects) clears
# within a poll or two and does NOT false-positive. A real leak (a sustained peer connection) persists
# across polls and is reported. `--polls 1` gives a single instantaneous snapshot. (#274)
#
# Interpretation:
#   - `tor` arm  → EVERY app container must show 0 PERSISTENT public connections (all egress via Tor).
#                  Only the `tor` container should reach public IPs (Tor relays). A persistent app
#                  connection = LEAK → exit 1.
#   - `clearnet` → the mining-path containers (p2pool, xmrig-proxy while donating) SHOULD show direct
#                  public connections; monerod/tari staying at 0 confirms node-sync is still Tor
#                  (the benchmark holds those constant — see docs/benchmarks/tor-vs-clearnet.md).
#
# Ground-truth backstop (needs root, so run by hand): a WAN-interface capture should show NO mining
# traffic to non-Tor IPs in the tor arm —
#   sudo tcpdump -ni <wan> 'tcp and (port 18080 or portrange 37888-37890 or port 4247) and not host <tor-relays>'

set -uo pipefail

ARM="${1:-}"
case "$ARM" in tor | clearnet) shift ;; *)
    echo "usage: bench-verify-egress.sh <tor|clearnet> [--dir DIR] [--prefix P] [--polls N] [--interval S] [--min-hits K]" >&2
    exit 2
    ;;
esac
DIR="/srv/code/pithead"
PREFIX="172.28.0"
POLLS=4
INTERVAL=10
MIN_HITS=2
while [ $# -gt 0 ]; do
    case "$1" in
    --dir)
        DIR="$2"
        shift 2
        ;;
    --prefix)
        PREFIX="$2"
        shift 2
        ;;
    --polls)
        POLLS="$2"
        shift 2
        ;;
    --interval)
        INTERVAL="$2"
        shift 2
        ;;
    --min-hits)
        MIN_HITS="$2"
        shift 2
        ;;
    *)
        echo "unknown arg: $1" >&2
        exit 2
        ;;
    esac
done
[ "$POLLS" -ge 1 ] 2>/dev/null || {
    echo "--polls must be >= 1" >&2
    exit 2
}
[ "$MIN_HITS" -le "$POLLS" ] 2>/dev/null || MIN_HITS="$POLLS" # can't need more hits than polls
APPS="monerod p2pool tari xmrig-proxy"

# Established (st=01) foreign IPv4s for a container that are PUBLIC (skip loopback/private/bridge/
# link-local — the Tor SOCKS lives in the private 172.16/12 range, so SOCKS-routed traffic is skipped).
# /proc/net/tcp `rem_address` is little-endian hex "IIIIIIII:PPPP"; decode with bash arithmetic so we
# don't depend on gawk/strtonum inside minimal images (only `cat` runs in the container). IPv4-only by
# design — mining_net is IPv4 (matches the #270 firewall scope).
public_conns() { # <container-id>  → one "ip:port" per established public connection
    docker exec "$1" sh -c 'cat /proc/net/tcp 2>/dev/null' | while read -r _sl _local rem st _rest; do
        [ "$st" = "01" ] || continue
        local hip="${rem%:*}" hport="${rem#*:}" o1 o2 o3 o4
        o1=$((16#${hip:6:2}))
        o2=$((16#${hip:4:2}))
        o3=$((16#${hip:2:2}))
        o4=$((16#${hip:0:2}))
        case "$o1.$o2" in 10.* | 127.* | 0.* | 169.254 | 192.168) continue ;; esac
        { [ "$o1" = 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; } && continue
        printf '%d.%d.%d.%d:%d\n' "$o1" "$o2" "$o3" "$o4" "$((16#$hport))"
    done
}

cid_of() { (cd "$DIR" && docker compose ps -q "$1" 2>/dev/null | head -n1); }

echo "[verify-egress] arm=$ARM  stack=$DIR  tor-socks=${PREFIX}.25:9050  (polls=$POLLS interval=${INTERVAL}s, persistent>=$MIN_HITS)"

# Poll POLLS times; per poll record each app's UNIQUE public foreign IPs (drop the churning port). An
# (app, ip) pair seen in >= MIN_HITS distinct polls is a SUSTAINED connection, not a startup transient.
samples="$(mktemp)"
trap 'rm -f "$samples"' EXIT
p=1
while [ "$p" -le "$POLLS" ]; do
    for c in $APPS; do
        cid=$(cid_of "$c")
        [ -n "$cid" ] || continue
        public_conns "$cid" | sed 's/:.*//' | sort -u | sed "s/^/$c /" >>"$samples"
    done
    [ "$p" -lt "$POLLS" ] && sleep "$INTERVAL"
    p=$((p + 1))
done
# uniq -c over the per-poll-unique lines = #polls each (app,ip) appeared in; keep the persistent ones.
persistent=$(sort "$samples" | uniq -c | awk -v m="$MIN_HITS" '$1>=m {print $2" "$3" "$1}') # "app ip hits"

fail=0
for c in $APPS; do
    cid=$(cid_of "$c")
    [ -n "$cid" ] || {
        echo "  - $c: not running (skip)"
        continue
    }
    rows=$(printf '%s\n' "$persistent" | awk -v a="$c" -v P="$POLLS" '$1==a {print $2" ("$3"/"P" polls)"}')
    n=$(printf '%s' "$rows" | grep -c . || true)
    if [ "$ARM" = "tor" ]; then
        if [ "$n" -eq 0 ]; then
            echo "  ✓ $c: no persistent public connections — all egress via Tor"
        else
            echo "  ✗ $c: $n PERSISTENT PUBLIC connection(s) — CLEARNET LEAK:"
            printf '%s\n' "$rows" | sed 's/^/        /'
            fail=1
        fi
    else
        if [ "$n" -gt 0 ]; then
            echo "  ✓ $c: $n persistent public connection(s) — clearnet, as expected for this arm"
        else echo "  · $c: no persistent public connections (still Tor / idle — expected for monerod & tari)"; fi
    fi
done
tcid=$(cid_of tor)
tn=$(public_conns "$tcid" | sed 's/:.*//' | sort -u | grep -c . || true)
echo "  · tor: $tn external relay connection(s) (expected > 0 — this is the only container that should reach the internet)"

if [ "$ARM" = "tor" ] && [ "$fail" -ne 0 ]; then
    echo "[verify-egress] FAIL — persistent clearnet leak(s) above; the 'all-Tor' arm is not clean." >&2
    exit 1
fi
echo "[verify-egress] OK"
