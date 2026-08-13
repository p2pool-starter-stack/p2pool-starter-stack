"""Public-winners generalization crawl (runs inside the dashboard container on prod, via Tor).

For a sample of OTHER winners' recent rounds: resolve masked winner -> full address by matching
against miners who found main-chain shares inside the winner's own slot; then measure each
resolved winner's three-chain in-slot delivered work vs their own out-of-slot baseline.
Writes JSON progress to stdout lines; final result as one JSON object on the last line.
Polite: ~1 request / 1.6 s, sequential, cached.
"""
import json, os, re, time, urllib.request, random
import requests

ADDR = os.environ["MONERO_WALLET_ADDRESS"]
PROXY = os.environ.get("TOR_SOCKS_PROXY", "socks5h://tor:9050")
S = requests.Session()
S.proxies = {"http": PROXY, "https": PROXY}
BASES = {"main": "https://p2pool.observer", "mini": "https://mini.p2pool.observer",
         "nano": "https://nano.p2pool.observer"}
STATE = "/tmp/winners_crawl_state.json"
_last = [0.0]

def get(url, timeout=60):
    wait = 1.6 + random.random() * 0.6 - (time.time() - _last[0])
    if wait > 0:
        time.sleep(wait)
    _last[0] = time.time()
    for attempt in (1, 2, 3):
        try:
            r = S.get(url, timeout=timeout)
            if r.status_code == 200:
                return r.json()
            if r.status_code == 404:
                return None
        except Exception:
            pass
        time.sleep(3 * attempt)
    return None

# ---- 1. winner sample from the on-box winners archives ---------------------------------
import glob, datetime
rows = {}
for path in glob.glob("/data/crawl-archives/winners-*.txt"):
    for line in open(path):
        f = line.split()
        if len(f) < 9:
            continue
        try:
            ts = datetime.datetime.fromisoformat(f[1] + " " + f[2]).replace(
                tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            continue
        rows[round(ts)] = (ts, f[0], float(f[3].replace("kH/s", "")) * 1e3, f[8])
sched = sorted(rows.values())
draws = [r[0] for r in sched]
now = time.time()
OUR = ADDR[:8]
cands = {}
for i, (ts, who, adv, typ) in enumerate(sched):
    if who.startswith(OUR) or now - ts > 30 * 86400 or now - ts < 8 * 3600:
        continue
    if typ not in ("donor_whale", "donor_mega", "donor_vip"):
        continue
    nxt = draws[i + 1] if i + 1 < len(draws) else None
    if not nxt:
        continue
    cands.setdefault(who, []).append({"ts": ts, "slot": nxt - ts, "adv": adv, "typ": typ})
# winners with >=2 recent slots, biggest first; cap winners and slots for politeness
sample = sorted(((w, sl) for w, sl in cands.items() if len(sl) >= 2),
                key=lambda x: -len(x[1]))[:14]
sample = [(w, sorted(sl, key=lambda s: -s["ts"])[:6]) for w, sl in sample]
print(json.dumps({"progress": "sample", "winners": len(sample),
                  "slots": sum(len(s) for _, s in sample)}), flush=True)

# ---- 2. time -> main side-height anchors from our own shares ----------------------------
mine = get(f"{BASES['main']}/api/shares?miner={ADDR}&limit=100")
anchors = sorted((s["timestamp"], s["side_height"]) for s in mine)
t0, h0 = anchors[0]
t1, h1 = anchors[-1]
rate = (h1 - h0) / (t1 - t0)  # side blocks per second (~0.1)
def height_at(ts):
    return int(h0 + (ts - t0) * rate)

# ---- 3. resolve masked winners via in-slot main share miners ----------------------------
id_addr = {}
def resolve_id(mid):
    if mid in id_addr:
        return id_addr[mid]
    mi = get(f"{BASES['main']}/api/miner_info/{mid}")
    a = (mi or {}).get("address") or ""
    id_addr[mid] = a
    return a

def mask(a):
    return f"{a[:8]}...{a[-8:]}" if len(a) > 16 else None

resolved = {}
for who, slots in sample:
    full = None
    for sl in slots:
        hs = height_at(sl["ts"]) - 6
        span = int(sl["slot"] * rate) + 12
        blocks = get(f"{BASES['main']}/api/side_blocks_in_window?window={min(span, 900)}&from={hs + min(span, 900)}")
        if not isinstance(blocks, list):
            continue
        miners = []
        for b in blocks:
            mid = b.get("miner")
            if mid is not None and mid not in miners:
                miners.append(mid)
        # frequency-ascending: rare in-slot miners are likelier the bonus target
        for mid in sorted(miners, key=lambda m: sum(1 for b in blocks if b.get("miner") == m)):
            a = resolve_id(mid)
            if a and mask(a) == who:
                full = a
                break
        if full:
            break
    resolved[who] = full
    print(json.dumps({"progress": "resolve", "winner": who, "resolved": bool(full),
                      "cache": len(id_addr)}), flush=True)
    json.dump({"resolved": resolved}, open(STATE, "w"))

# ---- 4. per resolved winner: three-chain history, in-slot vs baseline -------------------
results = []
for who, slots in sample:
    full = resolved.get(who)
    if not full:
        results.append({"winner": who, "resolved": False, "n_slots": len(slots)})
        continue
    hist = {}
    for ch, base in BASES.items():
        sh = get(f"{base}/api/shares?miner={full}&limit=500")
        hist[ch] = [{"ts": x.get("timestamp"), "d": x.get("difficulty")} for x in (sh or [])]
    span_lo = min((s["ts"] for ch in hist.values() for s in ch), default=None)
    per_slots = []
    for sl in slots:
        inw = 0.0
        for ch, shares in hist.items():
            inw += sum(s["d"] for s in shares if s["ts"] and sl["ts"] - 60 <= s["ts"] <= sl["ts"] + sl["slot"])
        per_slots.append({"ts": sl["ts"], "adv_work": sl["adv"] * min(sl["slot"], 3600),
                          "in_work": inw, "slot": sl["slot"], "typ": sl["typ"]})
    # baseline: winner's own out-of-slot share rate over their covered span (per chain summed)
    slot_ivals = [(sl["ts"] - 60, sl["ts"] + sl["slot"]) for sl in slots]
    def in_any_slot(ts):
        return any(a <= ts <= b for a, b in slot_ivals)
    out_work = sum(s["d"] for ch in hist.values() for s in ch
                   if s["ts"] and not in_any_slot(s["ts"]))
    cover = {ch: (max((s["ts"] for s in shares), default=0) - min((s["ts"] for s in shares), default=0))
             for ch, shares in hist.items() if shares}
    span = max(cover.values(), default=0)
    base_rate = (out_work / span) if span > 3600 else 0.0  # H/s equivalent
    for ps in per_slots:
        ps["baseline_work"] = base_rate * ps["slot"]
        ps["excess"] = max(0.0, ps["in_work"] - ps["baseline_work"])
        ps["R"] = ps["excess"] / ps["adv_work"]
    results.append({"winner": who, "resolved": True, "address_len": len(full),
                    "base_rate_Hs": round(base_rate), "slots": per_slots})
    print(json.dumps({"progress": "measured", "winner": who,
                      "R_slots": [round(p["R"], 3) for p in per_slots]}), flush=True)
    json.dump({"resolved": resolved, "results": results}, open(STATE, "w"))

print(json.dumps({"final": True, "results": results}), flush=True)
