import json, time, sys
WIN = 1786021262.0  # 08-06 09:01:02 local
rows = [json.loads(l) for l in open(sys.argv[1] if len(sys.argv) > 1 else "xvb-experiment/log.jsonl")]
r = rows[-1]
shares = [s for s in r.get("shares", []) if s["ts"] and s["ts"] >= WIN - 60]
diff = r["pool"]["diff"]
adv = 3536.5e3
work = sum(s["d"] for s in shares)
exp = adv * 3600
print(f"ROUND 2 FINAL (clean margin): {len(shares)} shares, delivered {work/1e9:.2f}G vs {exp/1e9:.2f}G expected -> {100*work/exp:.0f}%")
for s in shares:
    print(f"  share +{(s['ts']-WIN)/60:.1f} min, diff {s['d']/1e9:.2f}G")
cred = [x.get("cred", {}).get("1h") for x in rows if WIN <= x["t"] <= WIN + 4500]
print("credited min through round:", min(c for c in cred if c))
