import json, os, time, urllib.request, sqlite3

# Wallet from the container env (never printed in full); Tor SOCKS from the same config the
# dashboard's own XvB client uses — the query carries the wallet, so clearnet would correlate
# IP <-> wallet (#163).
addr = os.environ.get("MONERO_WALLET_ADDRESS", "")
proxy = os.environ.get("TOR_SOCKS_PROXY", "socks5h://tor:9050")
print("wallet:", addr[:8] + "..." + addr[-8:], "| proxy:", proxy)

import requests  # available in the dashboard image

S = requests.Session()
S.proxies = {"http": proxy, "https": proxy}
BASE = "https://p2pool.observer/api"

info = S.get(f"{BASE}/miner_info/{addr}", timeout=60)
print("miner_info HTTP", info.status_code)
mi = info.json() if info.status_code == 200 else {}
print("main-chain miner id:", mi.get("id"), "| shares total:", json.dumps(mi.get("shares")))

# All recorded main-chain shares for this wallet (observer caps page size; ask big).
sh = S.get(f"{BASE}/shares?miner={addr}&limit=200", timeout=60)
print("shares HTTP", sh.status_code)
shares = sh.json() if sh.status_code == 200 else []
print("shares returned:", len(shares))
for s in shares[:50]:
    ts = s.get("timestamp")
    print("  share:", time.strftime("%m-%d %H:%M", time.localtime(ts)),
          "| height", s.get("side_height"), "| diff", s.get("difficulty"),
          "| uncle" if s.get("parent") else "")
