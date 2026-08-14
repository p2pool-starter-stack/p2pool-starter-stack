#!/bin/sh
# Snapshot the public XvB winners feed — the full round schedule and qualifier counts — before
# its ~45-day rolling window drops the oldest rounds. The fetch runs inside the dashboard
# container so it rides the stack's Tor SOCKS (TOR_SOCKS_PROXY); the file is public and carries
# no wallet. See docs/operations.md ("Archiving the XvB winners feed").
set -eu

usage() {
    cat <<EOF
usage: xvb-winners-archive.sh [output-dir]

Saves https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt to
<output-dir>/winners-YYYYMMDD.txt (UTC date), fetched over the stack's Tor
SOCKS from inside the running dashboard container.

output-dir defaults to xvb-winners-archive/ in the stack directory.
EOF
}

case "${1:-}" in
-h | --help)
    usage
    exit 0
    ;;
esac

stack_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${1:-"$stack_dir/xvb-winners-archive"}
out_file="$out_dir/winners-$(date -u +%Y%m%d).txt"

mkdir -p -- "$out_dir"
tmp="$out_file.tmp"
trap 'rm -f -- "$tmp"' EXIT

docker exec -i dashboard python3 /dev/stdin >"$tmp" <<'PY'
import os, requests

proxy = os.environ.get("TOR_SOCKS_PROXY", "socks5h://tor:9050")
s = requests.Session()
s.proxies = {"http": proxy, "https": proxy}
print(s.get("https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt", timeout=60).text, end="")
PY

mv -- "$tmp" "$out_file"
echo "archived $out_file"
