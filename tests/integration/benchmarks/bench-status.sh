#!/usr/bin/env bash
#
# bench-status.sh — one-screen status of the Tor-vs-clearnet benchmark (#256), for checking over
# Tailscale: `ssh gouda bench-status`. Read-only; prints status.json + the recent event/health tail.
#
#   bench-status.sh [--json]     (--json: dump the raw status.json instead of the pretty view)

set -uo pipefail
BENCH_DIR="${BENCH_DIR:-$HOME/pithead-bench}"
S="$BENCH_DIR/status.json"

[ "${1:-}" = --json ] && { cat "$S" 2>/dev/null || echo '{}'; exit 0; }
[ -f "$S" ] || { echo "No benchmark status yet ($S missing). Is the run started?"; exit 0; }

jq -r '
  "Tor-vs-clearnet benchmark  (pool=\(.pool))",
  "  arm:        \(.arm | ascii_upcase)\(if .settling then "   (SETTLING — excluded)" else "" end)",
  "  block:      \(.block)/\(.blocks)     day \(.day)",
  "  block shares: \(.block_shares)",
  "  verdict:    \(.health.verdict // "?")   hashrate \(.health.hashrate_khs // "?")kH/s   peers \(.health.peers // "?")   egress \(.health.egress // "?")",
  (if (.health.problems // "") != "" then "  problems:   \(.health.problems)" else empty end),
  (if (.health.warns // "")    != "" then "  warns:      \(.health.warns)"    else empty end),
  "  updated:    \(.updated)\(if .stopped then "   [STOPPED]" else "" end)"
' "$S" 2>/dev/null || cat "$S"

echo "  ---"
echo "  recent events:"
tail -n 5 "$BENCH_DIR/events.log" 2>/dev/null | sed 's/^/    /' || true
echo "  collector lines: tor=$(wc -l < "$BENCH_DIR/tor.jsonl" 2>/dev/null || echo 0)  clearnet=$(wc -l < "$BENCH_DIR/clearnet.jsonl" 2>/dev/null || echo 0)"
