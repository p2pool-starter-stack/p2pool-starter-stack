#!/usr/bin/env python3
"""Bootstrap CIs for the paper's headline aggregates (seed pinned; §2.3 mapping row)."""
import json, random, subprocess, sys
random.seed(20260812)
rounds = json.loads(subprocess.run([sys.executable, "rounds.py", "--json"],
                                   capture_output=True, text=True).stdout)
clean = [r for r in rounds if r["era"] == "experiment" and r["draw_utc"] != "08-05 00:12"]
hist = [r for r in rounds if r["era"] == "historical"]
def R(rs): return sum(r["delivered_G"] for r in rs) / sum(r["advertised_G"] for r in rs)
def boot(rs, n=20000):
    vals = sorted(R([random.choice(rs) for _ in rs]) for _ in range(n))
    return vals[int(0.025 * n)], vals[int(0.975 * n)]
out = {"clean_R": R(clean), "clean_CI": boot(clean), "hist_R": R(hist), "hist_CI": boot(hist),
       "all_R": R(rounds), "all_CI": boot(rounds)}
json.dump(out, open("../figures/final_stats.json", "w"), indent=1)
print(json.dumps(out, indent=1))
