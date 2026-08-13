import sqlite3, time

c = sqlite3.connect("/data/mining_data.db")
# Whale era bounds (credited 24h >= 100k), padded so post-win streams fit inside.
rows = list(c.execute("select ts from xvb_history where avg_24h>=100000 order by ts"))
lo, hi = rows[0][0], rows[-1][0]
wins = [r[0] for r in c.execute("select ts from raffle_wins where ts between ? and ? order by ts", (lo, hi))]
pays = list(c.execute("select ts, amount_atomic from payouts where chain='monero' and ts between ? and ?", (lo, hi + 12 * 3600)))

H = 3600.0
MAXOFF = 12  # hours after a win we examine

# Baseline: payout rate in hours NOT within MAXOFF hours after any win.
def near_win(t):
    return any(0 <= t - w < MAXOFF * H for w in wins)

base_amt = sum(a for t, a in pays if lo <= t <= hi and not near_win(t)) / 1e12
# covered time: era duration minus union of win windows (approximate union by merging)
ivals = sorted((w, min(w + MAXOFF * H, hi)) for w in wins)
merged = []
for s, e in ivals:
    if merged and s <= merged[-1][1]:
        merged[-1][1] = max(merged[-1][1], e)
    else:
        merged.append([s, e])
covered = sum(e - s for s, e in merged)
base_hours = (hi - lo - covered) / H
base_rate = base_amt / base_hours  # XMR per hour, away from wins
print(f"era {time.strftime('%m-%d', time.localtime(lo))}->{time.strftime('%m-%d', time.localtime(hi))}, "
      f"{len(wins)} wins; baseline {base_rate*1000:.3f} mXMR/h over {base_hours:.0f} clean hours")

# Bucket every payout by hours-since the NEAREST PRECEDING win (within MAXOFF h).
buckets = [0.0] * MAXOFF
counts = [0] * MAXOFF
for t, a in pays:
    prevs = [t - w for w in wins if 0 <= t - w < MAXOFF * H]
    if prevs:
        off = int(min(prevs) // H)
        buckets[off] += a / 1e12
        counts[off] += 1
# Bucket exposure: how many win-hours actually elapsed at each offset (era-end + overlap trimmed).
# Overlap: an hour claimed by a *nearer* preceding win is not exposure for the earlier win.
expo = [0.0] * MAXOFF
for i, w in enumerate(wins):
    for off in range(MAXOFF):
        s, e = w + off * H, w + (off + 1) * H
        e = min(e, hi + 12 * 3600)
        if e <= s:
            continue
        # trim any part where a later win is nearer
        later = [x for x in wins if s < x < e]  # a win starting inside this hour claims the rest
        if any(x <= s for x in wins if x > w):  # a later win started before this hour: not ours
            continue
        span = (min(later) - s) if later else (e - s)
        expo[off] += span / H

print(f"{'h after win':>11} {'payouts':>8} {'XMR':>8} {'baseline':>9} {'excess mXMR':>12}")
cum = 0.0
for off in range(MAXOFF):
    expected = base_rate * expo[off]
    excess = buckets[off] - expected
    cum += excess
    print(f"{off:>11} {counts[off]:>8} {buckets[off]:.4f} {expected:>9.4f} {excess*1000:>12.2f}  cum {cum*1000:7.2f}")
print(f"\nper-win excess by cutoff: 2h {sum(buckets[:2]) - base_rate*sum(expo[:2]):.4f} XMR /{len(wins)} wins")
for cut in (2, 4, 6, 8, 10, 12):
    ex = sum(buckets[:cut]) - base_rate * sum(expo[:cut])
    print(f"  cutoff {cut:>2}h: total excess {ex*1000:7.2f} mXMR = {ex/len(wins)*1000:6.2f} mXMR/win")
