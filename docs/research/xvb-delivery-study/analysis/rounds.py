#!/usr/bin/env python3
"""Canonical per-round delivery analysis — THE single source of truth for the study's
delivery numbers (supersedes the ad-hoc scripts that produced corrections #11-#13).

For every win of ours found in the archived round schedules:
  slot        = draw -> next draw (consecutive rows of the merged winners snapshots)
  delivered   = sum of share difficulty on EACH sidechain (main / mini / nano) inside the slot,
                with the wallet's own mini mining subtracted as baseline work (we mine mini
                ourselves; main and nano are XvB-only for this wallet)
  advertised  = advertised bonus HR (winners row) x min(slot, 60 min)
  delivery R  = delivered / advertised   (difficulty-weighted, cross-chain)

Data inputs (all in ../data/): winners-*.txt + sources/xmrvsbeast-winners*.txt snapshots,
observer-all-chains-20260810.json, prod-db-dump.json (hashrate_hourly for mini baseline),
experiment-log.jsonl (credited margins per experiment round).
Usage: python3 rounds.py [--json]
"""
import glob
import json
import os
import sys
from datetime import datetime, timezone

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
MASK = "48LNi6pk"
EXPERIMENT_START = datetime(2026, 8, 4, 1, 0, tzinfo=timezone.utc).timestamp()

# --- round schedule: union of every archived winners snapshot ---------------------------
rows = {}
for path in glob.glob(f"{D}/winners-*.txt") + glob.glob(f"{D}/sources/xmrvsbeast-winners*.txt"):
    for line in open(path):
        f = line.split()
        if len(f) < 9:
            continue
        try:
            ts = datetime.fromisoformat(f[1] + " " + f[2]).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
        rows[round(ts)] = {"ts": ts, "who": f[0], "adv": float(f[3].replace("kH/s", "")) * 1e3,
                           "players": int(f[7]), "typ": f[8]}
# experiment log's rounds stream adds rows newer than any snapshot
logpath = f"{D}/experiment-log.jsonl"
if os.path.exists(logpath):
    for line in open(logpath):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        for row in r.get("rounds") or []:
            f = row.split()
            if len(f) < 9:
                continue
            try:
                ts = datetime.fromisoformat(f[1] + " " + f[2]).replace(tzinfo=timezone.utc).timestamp()
            except ValueError:
                continue
            rows.setdefault(round(ts), {"ts": ts, "who": f[0], "adv": float(f[3].replace("kH/s", "")) * 1e3,
                                        "players": int(f[7]), "typ": f[8]})
sched = sorted(rows.values(), key=lambda r: r["ts"])
draws = [r["ts"] for r in sched]

# --- shares on all three chains ---------------------------------------------------------
import glob as _g
# newest by mtime, NOT by name (correction #20: "-final" sorts before ".json" lexicographically,
# which silently served a stale dump and manufactured a false zero round)
_chains_file = max(_g.glob(f"{D}/observer-all-chains-*.json"), key=os.path.getmtime)
chains = json.load(open(_chains_file))
mini_floor = min((s["ts"] for s in chains["mini"]), default=None)  # mini dump depth limit

# --- our own mini baseline (H/s) from hourly hashrate dump ------------------------------
hh = {r["hour"]: r["p2pool"] for r in json.load(open(f"{D}/prod-db-dump.json"))["hashrate_hourly"]}

def own_mini_rate(ts):
    h = int(ts // 3600) * 3600
    for cand in (h, h - 3600, h + 3600):
        if hh.get(cand):
            return hh[cand]
    return 0.0

# --- per-round accounting ---------------------------------------------------------------
def slot_of(ts):
    later = [d for d in draws if d > ts + 1]
    return (min(later) - ts) if later else None

out = []
for r in sched:
    if not r["who"].startswith(MASK):
        continue
    slot = slot_of(r["ts"])
    if slot is None:
        continue
    per = {}
    for chain, shares in chains.items():
        inslot = [s for s in shares if s["ts"] and r["ts"] - 60 <= s["ts"] <= r["ts"] + slot]
        per[chain] = {"n": len(inslot), "work": sum(s["d"] for s in inslot),
                      "offs": sorted(round((s["ts"] - r["ts"]) / 60, 1) for s in inslot)}
    # mini baseline: our own expected mini work during the slot
    base = own_mini_rate(r["ts"]) * slot
    mini_excess = max(0.0, per["mini"]["work"] - base)
    mini_covered = mini_floor is not None and r["ts"] >= mini_floor
    delivered = per["main"]["work"] + per["nano"]["work"] + (mini_excess if mini_covered else 0.0)
    advertised = r["adv"] * min(slot, 3600)
    out.append({
        "draw_utc": datetime.fromtimestamp(r["ts"], timezone.utc).strftime("%m-%d %H:%M"),
        "ts": r["ts"], "typ": r["typ"], "players": r["players"],
        "adv_MHs": round(r["adv"] / 1e6, 2), "slot_min": round(slot / 60, 1),
        "main_n": per["main"]["n"], "main_offs": per["main"]["offs"],
        "nano_n": per["nano"]["n"], "mini_n": per["mini"]["n"],
        "mini_covered": mini_covered,
        "mini_excess_G": round(mini_excess / 1e9, 2) if mini_covered else None,
        "delivered_G": round(delivered / 1e9, 2),
        "advertised_G": round(advertised / 1e9, 2),
        "R": round(delivered / advertised, 3),
        "era": "experiment" if r["ts"] >= EXPERIMENT_START else "historical",
    })

if "--json" in sys.argv:
    print(json.dumps(out, indent=1))
else:
    hdr = f"{'draw(UTC)':>11} {'type':12} {'adv':>5} {'slot':>6} {'main':>4} {'nano':>4} {'mini':>4} {'delG':>6} {'advG':>6} {'R':>6} era"
    print(hdr)
    for o in out:
        print(f"{o['draw_utc']:>11} {o['typ']:12} {o['adv_MHs']:>5} {o['slot_min']:>6} "
              f"{o['main_n']:>4} {o['nano_n']:>4} {o['mini_n']:>4} "
              f"{o['delivered_G']:>6} {o['advertised_G']:>6} {o['R']:>6.1%} {o['era']}"
              + ("" if o["mini_covered"] else " (mini n/a)"))
    for era in ("historical", "experiment"):
        sub = [o for o in out if o["era"] == era]
        if not sub:
            continue
        del_t = sum(o["delivered_G"] for o in sub)
        adv_t = sum(o["advertised_G"] for o in sub)
        print(f"{era}: {len(sub)} rounds, R = {del_t:.1f}G / {adv_t:.1f}G = {del_t/adv_t:.1%}")
