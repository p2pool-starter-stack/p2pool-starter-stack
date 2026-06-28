#!/usr/bin/env python3
"""bench-analyze.py — reduce the #256 Tor-vs-clearnet JSONL into a per-arm comparison.

Reads the collector output (tor.jsonl / clearnet.jsonl) plus events.log (for the block
boundaries) from a benchmark dir and prints a per-block + per-arm summary, then the Tor-vs-clearnet
verdict. Read-only; pure stdlib so it runs anywhere.

    bench-analyze.py [BENCH_DIR]          # default: ~/pithead-bench

Methodology (matches docs/benchmarks/tor-vs-clearnet.md):
  * The block is the statistical unit — 5-min snapshots within a block are autocorrelated, so we
    reduce each block to one number (its post-settle mean) and compare the 3 Tor vs 3 clearnet blocks.
  * The first settle-hours of every block are DISCARDED (p2pool reconnects + the PPLNS window
    re-stabilises after each arm switch).
  * Primary metric: reward_share (p2pool block_reward_share_percent). Because the fleet hashrate is
    held constant across arms, we also report yield-efficiency = reward_share / hashrate_share, which
    cancels drift in the sidechain's total hashrate as other miners come and go.
  * shares_found / shares_failed are cumulative counters that RESET when p2pool is recreated at each
    switch, so per-block totals are taken as the max within the block.
"""

import calendar
import json
import os
import sys
import time
from statistics import mean, pstdev


def parse_ts(s):
    # timegm treats the parsed struct_time as UTC (the events.log stamps are all `...Z`). Avoids the
    # datetime.UTC alias so the script stays portable to older Pythons — it's documented as run-anywhere.
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))


def load_blocks(events_path):
    """Return [(block_idx, arm, start_epoch, end_epoch)] and settle seconds, from events.log."""
    starts, end, settle_h = [], None, 3.0
    with open(events_path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2:
                continue
            ts = parse_ts(parts[0])
            rest = " ".join(parts[1:])
            if rest.startswith("RUN START"):
                starts.append((1, "tor", ts))  # block 1 is always the Tor arm
                for tok in parts:
                    if tok.startswith("settle-hours="):
                        settle_h = float(tok.split("=", 1)[1])
            elif rest.startswith("BLOCK "):
                idx = int(parts[2].split("/")[0])
                arm = next(t.split("=", 1)[1] for t in parts if t.startswith("arm="))
                starts.append((idx, arm, ts))
            elif rest.startswith("RUN COMPLETE"):
                end = ts
    starts.sort(key=lambda x: x[0])
    blocks = []
    for i, (idx, arm, start) in enumerate(starts):
        stop = starts[i + 1][2] if i + 1 < len(starts) else (end or float("inf"))
        blocks.append((idx, arm, start, stop))
    return blocks, settle_h * 3600


def load_rows(path):
    rows = []
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    return rows


def num(rows, key):
    return [r[key] for r in rows if isinstance(r.get(key), (int, float))]


def block_summary(rows):
    """Reduce one block's post-settle snapshots to a dict of metrics."""
    rs = num(rows, "reward_share")
    our_hr = num(rows, "hashrate_1h")
    pool_hr = [h for h in num(rows, "pool_hr") if h > 0]
    # hashrate share (%) computed per-snapshot then averaged, guarding divide-by-zero.
    hs = [
        100.0 * r["hashrate_1h"] / r["pool_hr"]
        for r in rows
        if r.get("pool_hr") and r.get("hashrate_1h") is not None and r["pool_hr"] > 0
    ]
    return {
        "n": len(rows),
        "reward_share": mean(rs) if rs else 0.0,
        "hashrate_share": mean(hs) if hs else 0.0,
        "yield_eff": (mean(rs) / mean(hs)) if rs and hs and mean(hs) else 0.0,
        "shares_found": max(num(rows, "shares_found") or [0]),
        "shares_failed": max(num(rows, "shares_failed") or [0]),
        "avg_effort": mean(num(rows, "avg_effort")) if num(rows, "avg_effort") else 0.0,
        "peers_out": mean(num(rows, "peers_out")) if num(rows, "peers_out") else 0.0,
        "our_hr_khs": (mean(our_hr) / 1000.0) if our_hr else 0.0,
        "pool_hr_mhs": (mean(pool_hr) / 1e6) if pool_hr else 0.0,
        "tor_cpu": mean(num(rows, "tor_cpu_pct")) if num(rows, "tor_cpu_pct") else 0.0,
    }


def main():
    bench_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/pithead-bench")
    blocks, settle = load_blocks(os.path.join(bench_dir, "events.log"))
    rows = {
        "tor": load_rows(os.path.join(bench_dir, "tor.jsonl")),
        "clearnet": load_rows(os.path.join(bench_dir, "clearnet.jsonl")),
    }

    print(f"# #256 Tor-vs-clearnet analysis   (settle discarded: {settle / 3600:.0f}h/block)\n")
    per_block = {"tor": [], "clearnet": []}
    hdr = (
        f"{'blk':>3} {'arm':<8} {'n':>4} {'reward%':>8} {'hr-share%':>9} {'yield-eff':>9} "
        f"{'shares':>6} {'rej':>4} {'effort%':>7} {'peers':>5} {'torCPU%':>7}"
    )
    print(hdr)
    print("-" * len(hdr))
    for idx, arm, start, stop in blocks:
        keep = [r for r in rows[arm] if start + settle <= r["ts"] < stop]
        if not keep:
            continue
        s = block_summary(keep)
        per_block[arm].append(s)
        print(
            f"{idx:>3} {arm:<8} {s['n']:>4} {s['reward_share']:>8.3f} {s['hashrate_share']:>9.3f} "
            f"{s['yield_eff']:>9.3f} {int(s['shares_found']):>6} {int(s['shares_failed']):>4} "
            f"{s['avg_effort']:>7.1f} {s['peers_out']:>5.1f} {s['tor_cpu']:>7.1f}"
        )

    print("\n## Per-arm (mean of block means; ± = block-to-block stdev, the noise floor)\n")
    agg = {}
    for arm in ("tor", "clearnet"):
        bs = per_block[arm]
        if not bs:
            continue

        def col(key, blocks=bs):
            return [b[key] for b in blocks]

        agg[arm] = {k: mean(col(k)) for k in bs[0]}
        agg[arm]["reward_sd"] = pstdev(col("reward_share")) if len(bs) > 1 else 0.0
        agg[arm]["yield_sd"] = pstdev(col("yield_eff")) if len(bs) > 1 else 0.0
        agg[arm]["shares_total"] = sum(col("shares_found"))
        agg[arm]["rej_total"] = sum(col("shares_failed"))
        a = agg[arm]
        print(
            f"  {arm:<9} blocks={len(bs)}  reward%={a['reward_share']:.3f} ±{a['reward_sd']:.3f}  "
            f"yield-eff={a['yield_eff']:.3f} ±{a['yield_sd']:.3f}  "
            f"shares={int(a['shares_total'])}  rej={int(a['rej_total'])}  "
            f"effort={a['avg_effort']:.1f}%  peers={a['peers_out']:.1f}  "
            f"our_hr={a['our_hr_khs']:.0f}kH/s  pool={a['pool_hr_mhs']:.1f}MH/s  torCPU={a['tor_cpu']:.1f}%"
        )

    if "tor" in agg and "clearnet" in agg:
        t, c = agg["tor"], agg["clearnet"]
        d_rs = (
            100.0 * (t["reward_share"] - c["reward_share"]) / c["reward_share"]
            if c["reward_share"]
            else 0.0
        )
        d_ye = 100.0 * (t["yield_eff"] - c["yield_eff"]) / c["yield_eff"] if c["yield_eff"] else 0.0
        print("\n## Tor vs clearnet")
        print(
            f"  reward-share:     Tor is {d_rs:+.1f}% vs clearnet  "
            f"(clearnet block-to-block spread ±{100 * c['reward_sd'] / c['reward_share']:.1f}%)"
            if c["reward_share"]
            else ""
        )
        print(
            f"  yield-efficiency: Tor is {d_ye:+.1f}% vs clearnet  "
            f"(clearnet spread ±{100 * c['yield_sd'] / c['yield_eff']:.1f}%)"
            if c["yield_eff"]
            else ""
        )
        print(
            f"  reject rate:      Tor {t['rej_total']}/{int(t['shares_total'])}  "
            f"clearnet {c['rej_total']}/{int(c['shares_total'])}"
        )
        print(f"  Tor daemon CPU:   Tor arm {t['tor_cpu']:.1f}%   clearnet arm {c['tor_cpu']:.1f}%")


if __name__ == "__main__":
    main()
