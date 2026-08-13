#!/bin/bash
# XvB delivery experiment v2 (2026-08) — see README.md beside this script for the methodology.
# One self-contained poll per cron firing; every fetch fails independently and is recorded as
# its own *_err field, so a Tor hiccup degrades one field, never the record. Wallet-bearing
# fetches ride the stack Tor SOCKS (#163).
docker exec -i dashboard python3 - <<'EOF' >>"$HOME/xvb-experiment/log.jsonl" 2>>"$HOME/xvb-experiment/err.log"
import json, os, re, time, requests, urllib.request

addr = os.environ["MONERO_WALLET_ADDRESS"]
proxy = os.environ.get("TOR_SOCKS_PROXY", "socks5h://tor:9050")
S = requests.Session()
S.proxies = {"http": proxy, "https": proxy}
rec = {"t": round(time.time())}

def grab(key, fn):
    try:
        rec[key] = fn()
    except Exception as e:
        rec[key + "_err"] = str(e)[:60]

# 1. Delivered work, on-chain: our newest p2pool-main shares (height/ts/difficulty).
grab("shares", lambda: [
    {"h": x.get("side_height"), "ts": x.get("timestamp"), "d": x.get("difficulty")}
    for x in S.get(f"https://p2pool.observer/api/shares?miner={addr}&limit=10", timeout=50).json()
])
# 2. Collection, on-chain: which main blocks paid us, how much, when.
grab("payouts", lambda: [
    {"h": x.get("main_height"), "ts": x.get("timestamp"), "a": x.get("coinbase_reward")}
    for x in S.get(f"https://p2pool.observer/api/payouts/{addr}?search_limit=10", timeout=50).json()
])
# 3. Conversion context: pool hashrate + sidechain difficulty at this instant (expected-share math).
def _pool():
    p = S.get("https://p2pool.observer/api/pool_info", timeout=50).json()
    side = p.get("sidechain", {})
    return {"diff": (side.get("difficulty")), "height": side.get("height"),
            "mainchain_diff": (p.get("mainchain", {}) or {}).get("difficulty")}
grab("pool", _pool)
# 4. Our credited averages + fail count from XvB — the termination-margin timeline.
def _cred():
    h = S.get("https://xmrvsbeast.com/cgi-bin/p2pool_bonus_history.cgi",
              params={"address": addr}, timeout=50).text
    out = {}
    m = re.search(r"1hr avg:\s*([\d.]+\s*[kKmM]?H/s)", h)
    out["1h"] = m.group(1) if m else None
    m = re.search(r"24hr avg:\s*([\d.]+\s*[kKmM]?H/s)", h)
    out["24h"] = m.group(1) if m else None
    m = re.search(r"Fail Count:\s*(\d+)", h)
    out["fail"] = int(m.group(1)) if m else None
    return out
grab("cred", _cred)
# 5. The round schedule + advertised prize: top rows of XvB's winners file. A new row appears
#    when a round is drawn, so a 2-min cadence bounds every round start (ours AND the next
#    round's — which bounds OUR round's true end) to ±2 min, with the advertised bonus HR.
grab("rounds", lambda: S.get(
    "https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt", timeout=50
).text.splitlines()[:3])
# 6. Our own side of the ledger, locally: what the proxy is actually routing and the mode —
#    distinguishes "our donation sagged" from "XvB delivered less" without inference.
def _local():
    d = json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/state", timeout=10))
    hr = d.get("hashrate", {})
    return {"mode": hr.get("mode_name"), "routed_1h": hr.get("xvb_routed_1h"),
            "p2p_1h": hr.get("p2p_1h"), "total": hr.get("total"),
            "cred_1h": hr.get("xvb_1h"), "stale": hr.get("xvb_stale"),
            "sw": (d.get("shares_window") or {}).get("count"),
            "xmr_price": (d.get("energy") or {}).get("xmr_price")}
grab("local", _local)
# 7. The regime this record was taken under, from the container env itself — analysis needs no
#    external timeline to know which donation configuration produced each observation.
grab("cfg", lambda: {"level": os.environ.get("XVB_DONATION_LEVEL"),
                     "frac": os.environ.get("XVB_MAX_DONATION_FRACTION", "0.85")})

print(json.dumps(rec))
EOF
