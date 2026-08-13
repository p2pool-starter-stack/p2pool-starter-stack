import sqlite3, time
c = sqlite3.connect("/data/mining_data.db")
fmt = lambda t: time.strftime("%m-%d %H:%M", time.localtime(t))
rows = list(c.execute("select ts from xvb_history where avg_24h>=100000 order by ts"))
lo, hi = rows[0][0], rows[-1][0]
days = (hi - lo) / 86400
print("whale era:", fmt(lo), "->", fmt(hi), f"({days:.1f} days)")
wins = [r[0] for r in c.execute("select ts from raffle_wins where ts between ? and ? order by ts", (lo, hi + 7200))]
pays = list(c.execute("select ts, amount_atomic from payouts where chain='monero' and ts between ? and ?", (lo, hi + 7200)))
tot = sum(a for _, a in pays) / 1e12
W = sum(a for t, a in pays if any(0 <= t - w <= 7200 for w in wins)) / 1e12
P = tot - W
p2p, xvb = list(c.execute("select avg(v_p2pool), avg(v_xvb) from history where timestamp between ? and ?", (lo, hi)))[0]
cf = P * (p2p + xvb) / p2p
print(f"wins in era: {len(wins)}")
print(f"total payouts: {tot:.4f} XMR | xvb-attributed(2h): {W:.4f} | p2pool: {P:.4f}")
print(f"avg split: p2pool {p2p/1000:.1f} kH/s, xvb {xvb/1000:.1f} kH/s")
print(f"counterfactual all-p2pool: {cf:.4f} XMR")
print(f"whale-era net vs counterfactual: {tot-cf:+.4f} XMR over {days:.1f}d = {(tot-cf)/days*30:+.4f} XMR/30d")
print(f"realized per win: {W/len(wins)*1000:.2f} mXMR | xvb income per day: {W/days*1000:.2f} mXMR | forgone per day: {(cf-P)/days*1000:.2f} mXMR")
