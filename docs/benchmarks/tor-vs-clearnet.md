# Benchmark: mining over Tor vs clearnet (#256)

> **Status: methodology — results pending.** This documents *what* we measure, *from where*, and
> *how we decide*, so the run is reproducible and the conclusion is honest. The results table at the
> bottom is filled in after the multi-day run on the [gouda test bench](../../tests/integration/gouda-testbench-README.md).

## The question

While the stack is **actively mining at steady state**, does routing the **mining-path** networking
over Tor instead of clearnet measurably cost us yield or reliability? This gates the Tor-by-default
decision for two paths:

- **p2pool outbound sidechain P2P** ([#165](https://github.com/p2pool-starter-stack/pithead/issues/165)) — `p2pool.clearnet` knob.
- **XvB donation mining** ([#166](https://github.com/p2pool-starter-stack/pithead/issues/166)) — `xvb.tor` knob.

This is **not** about *initial sync* over Tor — that's a separate, already-settled question
([#183](https://github.com/p2pool-starter-stack/pithead/issues/183)/#234: Tor IBD is impractically
slow, hence the opt-in clearnet-then-Tor initial sync). Here both monerod and Tari stay on Tor
throughout; only the **p2pool / XvB** egress changes between arms.

## What we measure, and from where

Every source below was verified against the live p2pool container on gouda (`/stats/*` files written
by p2pool's `--local-api` / `--data-api`, plus the dashboard `/api/state` and `docker stats`).

### Primary — yield (the bottom line)

The headline question is "does Tor cost us money," and that is captured **directly** by our share of
the PPLNS reward window — no raw orphan counter required, because an orphaned/uncled share simply
fails to earn its full weight, which shows up here.

| Metric | Meaning | Source · field |
|---|---|---|
| **PPLNS reward share** | our % of the sidechain reward window — direct revenue | `/stats/local/stratum` · `block_reward_share_percent` |
| **Yield efficiency** | reward-share ÷ hashrate-share; `< 1` ⇒ shares going stale | derived: `block_reward_share_percent` ÷ ( `hashrate_1h` ÷ `/stats/pool/stats` · `pool_statistics.hashRate` ) |
| **Effort** | hashes-per-share vs expected — rises when shares are found but not counted | `/stats/local/stratum` · `average_effort`, `current_effort` |
| **Uncle / orphan events** (our shares) | raw stale-share count — a *mechanism* cross-check on the yield number | parse the p2pool **console log** (`SHARE FOUND` + `SideChain` uncle markers); **not** in `/api/state` |

> **Why reward-share is primary, not a raw orphan count.** p2pool includes uncle shares at reduced
> weight and drops orphans entirely; both effects land in `block_reward_share_percent`. So the net
> revenue impact is measurable from the stratum stats today. The raw uncle count (log-parse) is kept
> as a secondary cross-check, not the decision metric — it's noisier and harder to attribute to *our*
> shares.

### Secondary — the mechanism (latency / connectivity)

These explain *why* the yield moved (or confirm it didn't) and are all available today.

| Metric | Source · field |
|---|---|
| Share-found cadence / time-to-first-share | `/stats/local/stratum` · `shares_found`, `last_share_found_time` |
| Sidechain peer count & churn | `/stats/local/p2p` · `connections`, `incoming_connections`, `peer_list_size` |
| Stratum-level rejects | `/stats/local/stratum` · `shares_failed` |
| Effective hashrate on pool | `/stats/local/stratum` · `hashrate_1h`, `hashrate_24h` |
| Tor daemon overhead under sustained traffic | `docker stats tor` (CPU %, mem) |

### XvB donation path (#166)

> **Not collected in the headline run** — XvB is disabled so the p2pool-yield comparison isn't
> confounded (see *Method* below). These fields apply only to a separate, dedicated XvB-transport
> measurement, where they'd be sampled during donation windows (when `algo_service` has routed the
> proxy to XvB).

| Metric | Source · field |
|---|---|
| Accepted / rejected / invalid shares to XvB | xmrig-proxy `/summary` → `/api/state` · `proxy_summary.{accepted,rejected,invalid}` |
| Credited raffle weight | XvB stats API (already fetched over Tor, #163) · `block_reward_share_percent` analogue at XvB |

## Method

- **Rig:** the gouda bench (running `develop`) + the **full RigForge fleet, `miner-0`…`miner-7`
  (~269 kH/s combined)** at a **fixed hashrate**, all pointed at gouda's stratum. A constant total
  hashrate across both arms is load-bearing for the ratio metric below.
- **Sidechain: `mini`.** At ~269 kH/s we are **~1.8 % of the `mini` sidechain** (observed ~14.75 MH/s)
  → **~155 of our own shares/day** — enough statistical power while staying a small, *representative*
  participant. (`main` at this hashrate yields only ~10 shares/day — too sparse; `nano` would make us
  **~11 % of the chain**, large enough that our own latency would drag it and *overstate* the Tor
  penalty. The uncle/orphan rate is set by the ~10 s share interval — the same on every sidechain —
  so the `mini` result generalises to `main`/`nano`.)
- **Design — INTERLEAVED A/B** (not one long block per arm): alternate **T → C → T → C in ~1.5–2-day
  blocks** so each arm samples the same diurnal / weekly / network-weather range. (A "5 days Tor then
  5 days clearnet" layout would confound the arm with the calendar period.) **Discard the first ~6 h
  after each switch** while p2pool reconnects + the PPLNS window re-stabilises. Run until each arm has
  **≥ ~500–1000 of our shares** (≈ 10–12 calendar days at ~155/day).
  - **Arm T (Tor):** `p2pool.clearnet=false` (`--socks5`), `tor_egress_firewall=true`, `xvb.tor=true` —
    the `develop` defaults (fail-closed, egress-gated).
  - **Arm C (clearnet):** `p2pool.clearnet=true`, `tor_egress_firewall=false`, `xvb.tor=false`. The
    **firewall must be off in this arm** — the #270 Tor-egress firewall DROPs direct clearnet dials, so
    leaving it on would give p2pool 0 sidechain peers and the arm would silently collect garbage. The
    arm switch toggles the two together. monerod + Tari keep their Tor app-config in both arms, so only
    p2pool's transport differs; clearnet exposure here is the intended baseline on the test bench.
  - Only the **mining-path transport** flips. Held constant in *both* arms: monerod + Tari on Tor,
    **XvB disabled** (`xvb.enabled=false`, see below), the rig, hashrate, sidechain, and monerod tip.
  - **Why XvB is disabled for this run.** With `XVB_DONATION_LEVEL=auto` the optimizer dynamically
    splits the fleet between p2pool and XvB to climb raffle tiers — observed on gouda routing ~96 kH/s
    to XvB vs only ~18 kH/s to p2pool while chasing the **Whale** tier. That (a) starves p2pool, so
    `reward_share` — our **primary** metric — would be measured on a fraction of the fleet, and (b)
    makes the split itself a function of Tor latency, i.e. the optimizer reacts to the very thing we're
    trying to isolate. Disabling XvB sends the **full ~269 kH/s to p2pool in both arms**, so
    `reward_share` is a clean readout of transport overhead (and ~155 shares/day, not a trickle). The
    XvB **transport** overhead (#166) is a separate, smaller question — benchmarked on its own, not
    folded into the p2pool-yield comparison. The harness re-asserts `xvb.enabled=false` on every
    `pithead apply` so a switch or recovery can't let the optimizer drift back on.
  - Every switch is **egress-gated** by `bench-verify-egress.sh` — Arm T must be a clean all-Tor PASS
    before any data is collected, so a leak can never silently invalidate a window.
- **Controlling natural variance:** (1) **interleave** (the dominant control); (2) compare the
  **ratio** yield-efficiency = reward-share ÷ hashrate-share, which cancels out the sidechain's total
  hashrate drifting as other miners come and go; (3) run to a **target share count**, not a fixed
  clock, so Poisson noise (~1/√N) sits below the effect we're resolving; (4) the **clearnet arm's
  block-to-block variance is the noise floor** for the decision; (5) hold everything else constant.
- **Collector:** [`bench-collect.sh`](../../tests/integration/benchmarks/bench-collect.sh) — a
  read-only poller that snapshots the `/stats/*` fields + `docker stats tor` into one JSONL line per
  interval (default 5 min), per arm, in `~/pithead-bench/<arm>.jsonl`. No new container.

## Running it — autonomous on gouda

The run must survive the operator being **offline for days**, so **everything runs on gouda**; a
laptop / SSH session is only an optional observer. Three layers:

- **[`bench-orchestrate.sh`](../../tests/integration/benchmarks/bench-orchestrate.sh)** (detached on
  gouda) drives the whole run: flips the arm each block via `pithead apply`, egress-gates the switch,
  (re)starts the collector, health-checks every cycle, writes `~/pithead-bench/status.json`, and
  **self-protects** — transient blips (a miner reconnecting, Tor circuit churn) are tolerated and
  recorded, but a genuine *unrecoverable* break **pauses collection and marks that window invalid**
  rather than polluting the dataset. An unwatched multi-day break then costs calendar time, not data.
- **Cron watchdog** (`*/15 * * * *` + an `@reboot` entry) runs
  [`bench-healthcheck.sh`](../../tests/integration/benchmarks/bench-healthcheck.sh): restarts the
  orchestrator or collector if either died, re-`up`s the stack if it's down, appends `health.log`.
  This catches the orchestrator itself dying or a gouda reboot — what the orchestrator can't
  self-report. Runs as the operator user; the only privileged step (`iptables`) is covered by the
  scoped `/etc/sudoers.d/pithead-firewall` grant.
- **Observe over Tailscale:** `ssh gouda bench-status`
  ([`bench-status.sh`](../../tests/integration/benchmarks/bench-status.sh)) prints a one-screen
  summary — current arm, day, last-OK, shares per arm, egress verdict, miners, collector. The
  dashboard UI (on gouda's Tailscale IP) is the live stack glance.

### Runbook

```bash
# 1. calibrate (~6–12 h, Tor arm): confirm live mini total, our share, shares/day
tests/integration/benchmarks/bench-orchestrate.sh --calibrate --pool mini

# 2. start the autonomous interleaved run + install the watchdog cron
nohup tests/integration/benchmarks/bench-orchestrate.sh \
      --pool mini --block-hours 36 --settle-hours 6 --target-shares 800 >/dev/null 2>&1 &
tests/integration/benchmarks/bench-orchestrate.sh --install-cron   # */15 + @reboot watchdog

# 3. check from anywhere over Tailscale
ssh gouda bench-status
ssh gouda tail -n 40 pithead-bench/health.log

# 4. graceful stop (restores the develop default, removes the cron, keeps the JSONL data)
tests/integration/benchmarks/bench-orchestrate.sh --stop
```

## Decision rule

The clearnet arm establishes the **noise floor** (its own variance across sub-windows). Then:

- **Tor yield-efficiency / reward-share delta within that noise floor** ⇒ keep **Tor as the default**
  for that path (#165/#166 ship as-is); document the measured (negligible) trade-off.
- **Tor materially below clearnet** (a reward-share loss clearly outside the noise, especially if
  concentrated on `--mini`/`--nano`) ⇒ document the trade-off and reconsider: a **per-sidechain
  default**, or **clearnet-default with a Tor opt-in**, rather than a blanket Tor default.

Either way the conclusion lands in [`docs/privacy.md`](../privacy.md) so operators get an honest
trade-off, and it sets the final default for #165/#166 **before** the v1.1 release.

## Results

_Pending the multi-day run. To be filled with: a per-arm table (reward share, yield efficiency,
effort, uncle count, peers, rejects, Tor overhead), the noise floor, and the recommendation._

| Arm | Pool | Days | Reward share | Yield eff. | Avg effort | Uncles | Peers | Rejects | Tor CPU/mem |
|---|---|---|---|---|---|---|---|---|---|
| _clearnet_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | — |
| _Tor_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ | _tbd_ |

**Recommendation:** _pending._
