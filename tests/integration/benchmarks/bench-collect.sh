#!/usr/bin/env bash
#
# bench-collect.sh — Tor-vs-clearnet mining benchmark collector (#256).
#
# Snapshots p2pool's yield + latency/connectivity metrics and the Tor daemon's overhead into a JSONL
# file, ONE line per interval, until killed. Read-only: it only reads the `/stats/*` files p2pool
# already writes (its --local-api / --data-api) and `docker stats`. Runs ON the mining host (gouda),
# typically detached for days per arm. Metrics + sources are documented in
# docs/benchmarks/tor-vs-clearnet.md.
#
# Usage (on the box, in or near the stack dir):
#   tests/integration/benchmarks/bench-collect.sh <arm-label> [options]
#   nohup .../bench-collect.sh clearnet --interval 300 >/dev/null 2>&1 &   # detached, survives logout
#
# Options:
#   --interval N   seconds between snapshots (default 300 = 5 min)
#   --out FILE     JSONL output path (default ~/pithead-bench/<arm>.jsonl; appended to)
#   --p2pool NAME  p2pool container name (default: p2pool — the pinned compose project)
#   --tor NAME     tor container name (default: tor)
#   --once         take a single snapshot to stdout and exit (smoke test)
#
# Analyse later, e.g. the per-arm mean reward share:
#   jq -s 'map(.reward_share|numbers)|add/length' clearnet.jsonl

set -uo pipefail

ARM="${1:-}"; shift || true
case "$ARM" in ""|-*) echo "usage: bench-collect.sh <arm-label> [--interval N] [--out FILE] [--once]" >&2; exit 2;; esac

INTERVAL=300; OUT=""; P2POOL="p2pool"; TOR="tor"; ONCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --p2pool)   P2POOL="$2"; shift 2 ;;
        --tor)      TOR="$2"; shift 2 ;;
        --once)     ONCE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || OUT="$HOME/pithead-bench/${ARM}.jsonl"

# Read a /stats file out of the p2pool container as compact JSON, or `null` on any error/garbage.
pstat() { docker exec "$P2POOL" cat "/stats/$1" 2>/dev/null | jq -c . 2>/dev/null || true; }

snapshot() {
    local now strat p2p pool tor_line tor_cpu tor_mem
    now=$(date -u +%s)
    strat=$(pstat local/stratum); [ -n "$strat" ] || strat=null
    p2p=$(pstat local/p2p);       [ -n "$p2p" ]   || p2p=null
    pool=$(pstat pool/stats);     [ -n "$pool" ]  || pool=null
    # Tor daemon overhead under sustained mining traffic.
    tor_line=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "$TOR" 2>/dev/null)
    tor_cpu=$(printf '%s' "$tor_line" | awk -F'|' '{gsub(/%/,"",$1); print ($1==""?"null":$1+0)}')
    tor_mem=$(printf '%s' "$tor_line" | awk -F'|' '{split($2,a," / "); print a[1]}')   # e.g. "12.3MiB"
    [ -n "$tor_cpu" ] || tor_cpu=null

    jq -cn --arg arm "$ARM" --argjson ts "$now" \
        --argjson strat "$strat" --argjson p2p "$p2p" --argjson pool "$pool" \
        --argjson tor_cpu "$tor_cpu" --arg tor_mem "${tor_mem:-}" '
        {
            ts: $ts, arm: $arm,
            # --- primary: yield ---
            reward_share:   ($strat.block_reward_share_percent),
            avg_effort:     ($strat.average_effort),
            cur_effort:     ($strat.current_effort),
            # --- secondary: hashrate / share cadence ---
            hashrate_1h:    ($strat.hashrate_1h),
            hashrate_24h:   ($strat.hashrate_24h),
            shares_found:   ($strat.shares_found),
            shares_failed:  ($strat.shares_failed),
            last_share:     ($strat.last_share_found_time),
            # --- secondary: sidechain connectivity (the Tor-latency mechanism) ---
            peers_out:      ($p2p.connections),
            peers_in:       ($p2p.incoming_connections),
            peer_list:      ($p2p.peer_list_size),
            pool_hr:        ($pool.pool_statistics.hashRate),
            sidechain_diff: ($pool.pool_statistics.sidechainDifficulty),
            # --- Tor overhead ---
            tor_cpu_pct:    $tor_cpu,
            tor_mem:        $tor_mem
        }'
}

if [ "$ONCE" = "1" ]; then snapshot; exit 0; fi

mkdir -p "$(dirname "$OUT")"
echo "[bench] arm=$ARM interval=${INTERVAL}s out=$OUT started=$(date -u +%FT%TZ)" >&2
while :; do
    line=$(snapshot 2>/dev/null) && [ -n "$line" ] && printf '%s\n' "$line" >> "$OUT"
    sleep "$INTERVAL"
done
