import json, time, datetime

rows = [json.loads(l) for l in open("/home/vijit/xvb-experiment/log.jsonl")]
r = rows[-1]
now = r["t"]
print("latest poll:", time.strftime("%H:%M:%S", time.localtime(now)),
      "| errors:", [k for k in r if k.endswith("_err")] or "none")
win = None
for x in rows:
    for line in x.get("rounds", []):
        if line.startswith("48LNi6pk"):
            f = line.split()
            ts = datetime.datetime.fromisoformat(f[1] + " " + f[2]).replace(
                tzinfo=datetime.timezone.utc).timestamp()
            if win is None or ts > win[0]:
                win = (ts, f[3], f[7], f[8])
print("WIN:", time.strftime("%m-%d %H:%M:%S", time.localtime(win[0])),
      "| advertised:", win[1], "| players:", win[2], "| type:", win[3])
mins = (now - win[0]) / 60
print(f"round age: {mins:.1f} min")
shares = [s for s in r.get("shares", []) if s["ts"] and s["ts"] >= win[0] - 60]
diff = r["pool"]["diff"]
adv = float(win[1].replace("kH/s", "")) * 1000
exp_work = adv * min(mins, 60) * 60
work = sum(s["d"] for s in shares)
print(f"shares so far: {len(shares)} | delivered {work/1e9:.2f}G vs expected {exp_work/1e9:.2f}G "
      f"-> delivery {100*work/exp_work if exp_work else 0:.0f}%")
for s in shares:
    off = (s["ts"] - win[0]) / 60
    print(f"  share +{off:5.1f} min | diff {s['d']/1e9:.2f}G")
print("--- credited/routed through round ---")
for x in rows:
    if win[0] - 240 <= x["t"] <= now and (x["t"] - win[0]) % 360 < 120:
        print(time.strftime("%H:%M", time.localtime(x["t"])),
              x.get("cred", {}).get("1h"), "| routed", (x.get("local") or {}).get("routed_1h"))
