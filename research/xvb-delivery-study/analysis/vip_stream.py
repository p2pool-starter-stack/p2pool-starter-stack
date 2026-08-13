import sqlite3, time
c = sqlite3.connect("/data/mining_data.db")
# VIP era: everything before the whale era began.
whale_lo = list(c.execute("select min(ts) from xvb_history where avg_24h>=100000"))[0][0]
wins = [r[0] for r in c.execute("select ts from raffle_wins where ts < ? order by ts", (whale_lo,))]
if not wins:
    print("no pre-whale wins"); raise SystemExit
lo = wins[0] - 7 * 86400
pays = list(c.execute("select ts, amount_atomic from payouts where chain='monero' and ts between ? and ?", (lo, whale_lo)))
H, MAXOFF = 3600.0, 8
def near(t): return any(0 <= t - w < MAXOFF * H for w in wins)
base_amt = sum(a for t, a in pays if not near(t)) / 1e12
base_hours = (whale_lo - lo) / H - MAXOFF * len(wins)  # approx; wins are far apart
base_rate = base_amt / base_hours
gross = sum(a for t, a in pays if near(t)) / 1e12
excess = gross - base_rate * MAXOFF * len(wins)
print(f"VIP era: {len(wins)} wins from {time.strftime('%m-%d', time.localtime(wins[0]))}, baseline {base_rate*1000:.3f} mXMR/h")
print(f"gross in 8h windows {gross*1000:.1f} mXMR, excess {excess*1000:.1f} = {excess/len(wins)*1000:.2f} mXMR/win")
# face value per VIP-era win: same bonus rig, so same ~17.5 face; realization:
print(f"realization vs 17.5 mXMR face: {excess/len(wins)/0.0175*100:.0f}%")
