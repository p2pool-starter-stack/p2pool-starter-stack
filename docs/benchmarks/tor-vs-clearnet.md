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

Measured only during donation windows (when `algo_service` has routed the proxy to XvB).

| Metric | Source · field |
|---|---|
| Accepted / rejected / invalid shares to XvB | xmrig-proxy `/summary` → `/api/state` · `proxy_summary.{accepted,rejected,invalid}` |
| Credited raffle weight | XvB stats API (already fetched over Tor, #163) · `block_reward_share_percent` analogue at XvB |

## Method

- **Rig:** the gouda test bench + one RigForge rig (`miner-0`) at a **fixed hashrate**, driven by
  [`tests/integration/e2e.sh`](../../tests/integration/e2e.sh)'s borrow flow.
- **Design:** sequential **A/B over matched windows** on the *same* hashrate (one rig can't run two
  arms at once). Each arm runs **several days** — sidechain shares are sparse, so reward-share and
  uncle counts only converge over days, not hours.
  - **Arm C (clearnet):** `p2pool.clearnet: true` (and, for #166, `xvb.tor: false`).
  - **Arm T (Tor):** the defaults (`p2pool.clearnet: false` / `xvb.tor: true`).
  - The **control variable is the #165 `p2pool.clearnet` knob itself** — the benchmark dogfoods the
    very toggle it's validating. monerod + Tari stay on Tor in both arms.
- **Collector:** a small poller (to land alongside this doc) snapshots the `/stats/*` fields +
  `docker stats tor` every few minutes into a JSONL/CSV per arm, and tails the p2pool console for
  `SHARE FOUND` / uncle lines. No new container — it reads what p2pool already writes.
- **Confounders to control:** same pool/sidechain (`main` vs `mini`/`nano` measured separately — the
  Tor penalty is expected to be worse on the faster sidechains), same monerod tip, same rig, and
  windows long enough that pool-difficulty drift averages out. Network weather varies, so we report
  the **clearnet arm's own run-to-run variance** as the noise floor.

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
