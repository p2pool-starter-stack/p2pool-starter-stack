#!/bin/bash
# Daily full winners-file snapshot: preserves the complete round schedule + qualifier counts
# beyond the file's ~45-day rolling window (via the stack Tor SOCKS; the file carries no wallet).
docker exec -i dashboard python3 /dev/stdin >"$HOME/xvb-experiment/archive/winners-$(date -u +%Y%m%d).txt" 2>>"$HOME/xvb-experiment/err.log" <<'PY'
import os, requests
proxy = os.environ.get("TOR_SOCKS_PROXY", "socks5h://tor:9050")
S = requests.Session()
S.proxies = {"http": proxy, "https": proxy}
print(S.get("https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt", timeout=60).text, end="")
PY
