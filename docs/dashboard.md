# The Dashboard

A single web page that monitors every service, charts hashrate, and shows the XvB switching engine's
decisions. Caddy serves it over HTTPS at `https://<hostname>` (the URL is printed when the stack
starts); with `dashboard.secure: false` it serves plain HTTP.

The dashboard has two states. While the nodes catch up to the network it shows Sync Mode. Once both
chains are synced it switches to the operational view.

---

## Sync Mode

The dashboard shows Sync Mode the first time you start the stack, or any time the Monero or Tari
node is still catching up. A `Syncing...` badge appears next to the hostname, the headline reads
*"System is currently synchronizing with the network,"* and no hashrate is routed yet.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/launch/sync.png">
  <img alt="Sync Mode" src="../images/launch/sync-light.png">
</picture>

Sync Mode gives each chain its own progress card:

- **Monero Sync**: verified block height vs. the network tip, with blocks remaining. A green check
  means the chain is caught up. It also shows Pruned or Full mode and the on-disk DB size (also in
  the **XMR Network** panel of the operational view), so you can confirm a reused chain matches your
  `monero.prune` setting.
- **Tari Sync**: the same, as a percentage ring, for the Minotari chain.

The top bar shows live host telemetry throughout: CPU, load average, RAM, HugePages (to confirm
RandomX optimization is active), and disk usage, for watching resources during the initial download.

A Monero or Tari node cannot mine until it has downloaded and verified the blockchain. On a first
run that takes a few hours to over a day, depending on hardware, disk, and network. Once the required
chains report synced, the dashboard swaps Sync Mode for the operational view and mining begins — no
refresh or restart needed.

While the chains sync, the dashboard keeps `p2pool` and `xmrig-proxy` stopped (a `Miner held (sync)`
badge shows next to the hostname) and starts them once the chains are ready. Running p2pool against
an unsynced node does nothing and floods Tari's logs with merge-mining chatter. Releasing the miner
is one-way: once it starts it stays up. By default the stack waits for both Monero and Tari. With
[`dashboard.tari_required: false`](configuration.md) it waits only for Monero and mines while Tari
finishes syncing in the background.

> **Want to skip most of the wait?** Point the stack at an existing synced blockchain, or connect
> to a remote node. See [Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

You can also follow sync progress from the command line. `./pithead status` prints each chain's
percent and blocks remaining while it's still syncing (no ETA — block rate isn't sampled), or watch
the node logs directly:

```bash
./pithead status
./pithead logs monerod
./pithead logs tari
```

---

## The operational view

Once both nodes are synced, the dashboard shows the operational view.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/launch/simple.png">
  <img alt="Operational dashboard — Simple view" src="../images/launch/simple-light.png">
</picture>

The page updates every 30 seconds, refreshing each panel in place rather than reloading. Scroll
position, the worker-table sort column, and the chart stay put between updates. A poll that fails —
or hangs, as a dropped Tor circuit can — aborts after 25 seconds and shows a red banner naming the
timestamp of the data still on screen ("Disconnected — showing data from …"); it clears on the next
successful refresh.

### Top bar

A status strip across the top shows the hostname, host telemetry (CPU, load, RAM, HugePages, disk),
total hashrate, and 1h / 24h routed averages for both P2Pool and XvB (your split). Next to the disk
readout, an `XMR Pruned` / `XMR Full` badge shows the Monero node's blockchain mode.

When the dashboard host is a name (not already an IP), the machine's IP shows beside it as
`hostname @ ip` (e.g. `pithead.local @ 192.168.1.42`), a way back in when the hostname doesn't
resolve from a phone or another LAN machine.

A version badge sits beside the hostname. A released build shows the version (e.g. `v1.3.0`); a
development or working-tree build shows a dashed `dev · branch @ commit` marker instead, so it is not
mistaken for a release. It appears on every screen, including Sync Mode, so a screenshot in a bug
report shows the build. To switch a `dev` build to a published release, see
[Switching a source checkout to release images](operations.md#switching-a-source-checkout-to-release-images).

When a newer Pithead release is out, a clickable `New release vX.Y.Z available ↗` badge appears next
to the version badge, linking to the GitHub release. The badge itself never updates anything. The
check is on by default and routed over Tor, so it does not reveal your IP. Turn it off with
`dashboard.check_for_updates: false` (see [Configuration](configuration.md#configuration-reference)).

With the [control channel](#configuration-view) enabled, an **Upgrade to vX.Y.Z** button appears
beside the badge — see [Upgrading from the dashboard](#upgrading-from-the-dashboard). Without it,
upgrade from the host per [Operations › Updating the stack](operations.md#updating-the-stack).

### Host & performance warnings

The top bar also surfaces the persistent host conditions that `setup` warns about, derived from
**live** metrics so they self-correct rather than going stale:

| Badge | Means | Fix |
|---|---|---|
| `⚠ HugePages off` | HugePages aren't reserved — RandomX hashrate is capped. | Run setup's tuning (or edit GRUB) and reboot; the badge clears once they're reserved. |
| `⚠ Low RAM (N GB)` | Under 16 GB of RAM — syncing is memory-heavy and Tari can OOM. | Add RAM for a stable node. |
| `⚠ No AVX2` | The CPU lacks AVX2, so RandomX mining is much slower. | A hardware limit; nothing to change at runtime. |
| `⚠ Payout wallet changed` | The wallet p2pool mines to changed within the last 72 hours (old → new, truncated). A confirmation if you changed it; an alarm if you didn't. | Verify `monero.wallet_address` in `config.json`; see [Operations › wallet changes](operations.md). The badge expires on its own after 72 h. |

The first two also push a Telegram alert (`hugepages`, `low_ram`) when first detected, if the bot is
on; the wallet badge pairs with the `wallet_changed` alert; AVX2 is badge-only (see
[Telegram Bot](telegram.md#choosing-which-alerts-you-get)). All active warning badges are echoed in
the bot's `/status` reply.

### Hero band

A strip of headline KPIs sits below the top bar:

| KPI | Meaning |
|---|---|
| **Total Hashrate** | Your combined hashrate across all workers. |
| **Shares in Window** | Shares you currently hold in the P2Pool PPLNS window (green when above zero). |
| **Raffle Eligible** | Whether you'd actually win **and** collect an XvB raffle payout: green **Yes**, red **No**, or muted **N/A** when XvB is off. (Full definition in [Overview](#overview).) |
| **Blocks Found** | P2Pool sidechain blocks your node has found. |
| **XvB Tier** | The donation tier you're currently holding. |
| **Mining Mode** | What your hashrate is routed to right now: P2Pool, XvB, or a split. |

### Node status & failover

If a local node becomes unreachable, a red `monerod DOWN` or `Tari DOWN` badge appears in the top
bar (after a short debounce, so a momentary blip doesn't flap). Sync state is read from monerod's
`get_info` RPC and Tari's gRPC, so "down" means the node itself is unreachable, not just that a log
line changed.

A red `⚠ DB write failing` badge appears if the dashboard can't write to its SQLite database (full
or read-only disk, permissions problem). The dashboard keeps serving live data, but hashrate history,
shares, and stats won't survive a restart until it's fixed.

If the database file is found **corrupt** (malformed, e.g. after a container was recreated twice in
quick succession while a write was mid-flight), the dashboard heals itself rather than erroring
forever: it quarantines the bad file to `mining_data.db.corrupt-<UTC>` (kept for post-mortem), starts
a fresh database, and keeps running. A `db_reset` alert (Telegram and the other sinks) tells you
history before that point was cleared. Payout and XvB state rebuild from the chain and the live feed;
only the historical charts reset.

While a node is down, the dashboard rejects workers so they fail over to the backup pools you've
configured, rather than sitting idle on a stack that can't mine. A sustained outage stops the
`xmrig-proxy` container (a `Workers rejected` badge shows) and a confirmed recovery restarts it.
monerod is required to mine, so a monerod outage always rejects. Whether a Tari outage rejects
follows [`dashboard.tari_required`](configuration.md): `true` (default) rejects on a Tari outage;
`false` keeps mining Monero through it. Rejection never triggers for a remote monerod, since the
stack doesn't manage that node.

**Non-blocking Tari.** With `tari_required: false`, a Tari-only (re)sync doesn't take over the
screen: the operational view stays up, mining continues, and a `Tari syncing` badge shows Tari's
progress until it catches up and merge-mining resumes.

### Hashrate chart

A time-series chart of hashrate with selectable ranges (1h / 24h / 1w / 1mo) that switch without
reloading. Shaded bands show the P2Pool/XvB split over time.

Diamond markers along the top flag **hashrate events** (#99): an amber one where total hashrate
dropped sharply and stayed down (an outage or a rig gone dark), a green one where it recovered.
Hover for the size of the drop. They mark the same transitions as the `hashrate_loss` Telegram
alert and survive a dashboard restart, so a drop that happened overnight is still on the chart in the
morning.

A gold **star** marks each **XvB raffle round your wallet won**, at the time the round was drawn.
Hover for the round type and the hashrate XvB credited the win at. Wins come from XvB's published
winners log (fetched over Tor, like every XvB read) and are stored permanently, so the stars stay on
the chart across restarts; the same wins are listed in the *XvB Donation Stats* card's
[Raffle Wins log](#xvb-tier-raffle).

An **Avg** control picks the hashrate-averaging window the chart plots: `1 Min` / `10 Min` /
`1 Hr` / `12 Hr` / `24 Hr` (the native windows xmrig-proxy reports). It is independent of the Range
control: the range sets how much *time* the x-axis spans; the averaging window sets how *smooth* each
plotted point is. Short windows (1–10 min) react within a poll or two, so a rig dropping or joining
shows up fast. Long windows (12–24 h) ride out the noise to show the trend. The choice is remembered
across reloads. Two things to know:

- `10 Min` is the default and matches the dashboard's headline hashrate.
- The longer windows need that much rig uptime to fill. Right after a (re)start, `12 Hr`/`24 Hr` read
  low and climb until enough history exists. Per-window history is kept only *going forward* from the
  version that introduced this control, so those lines are flat at the far-left edge of a long range
  until new data accumulates. Expected, not a fault.

### Overview

The summary panel pulls the key numbers together:

| Field | Meaning |
|---|---|
| **Mining Mode** | What the stack is routing hashrate to right now (e.g. P2Pool, XvB, or a split). |
| **Total Hashrate** | Your combined hashrate across all workers. |
| **Workers Alive** | How many rigs are connected and online right now. |
| **Share in Window** | Your shares in the current P2Pool PPLNS window. |
| **Raffle Eligible** | **Yes** only when you're set up to both *win* and *collect* an XvB payout: you're donating at least the **donor tier** (1 kH/s on XvB's *credited* 1h **and** 24h averages, the same threshold as **Current Tier**) **and** you hold a P2Pool PPLNS share (XvB's "VIP" gate; without it a win is skipped and you take a fail). Reads **No** when donating but a gate is unmet, and **N/A (XvB off)** when XvB is disabled. Intentionally stricter than XvB's bare "VIP = just a share" so a green Yes means a win is paid. |
| **Last Share** | Time since your last accepted share. |
| **P2Pool 1h / 24h (routed)** | Time-weighted average hashrate the proxy actually routed to P2Pool. |
| **XvB 1h / 24h (routed)** | Time-weighted average hashrate the proxy actually **routed** to XvB. (The XvB-API *credited* figure, XvB's definitive record, appears in the **Advanced** view's *XvB Donation Stats* card.) |
| **Current Tier** | The XvB tier you're currently holding, the one cleared by the **lower of your credited 1h and 24h** donation averages, so a recent hashrate drop shows up right away. |
| **Target Tier** | The tier the engine is aiming for (from `xvb.donation_level`). If your hashrate can't sustain an explicitly chosen tier, a **⚠ Hashrate low for tier** badge appears. |
| **Tari Mining** | Whether merge-mining of Tari is active and healthy. |
| **Wallets** | Your configured Monero and Tari payout addresses. |

### Workers Alive

A live table of every connected rig: worker name, IP, uptime, and per-worker hashrate over the 1m
and 10m windows — the same 10m window the chart's averaging toggle and Telegram's totals report —
for spotting a rig that has dropped off or is underperforming. A
worker whose direct API is unreachable still counts (with proxy-derived hashrate); a worker whose
miner has stopped drops out of the total. On a narrow screen the table scrolls sideways within its
card so columns stay readable. Until the first worker ever connects, the card shows a connect hint
("point each rig at `<host-ip>:3333`") in place of the empty table; see
[Connecting Miners](workers.md).

A [RigForge](https://github.com/p2pool-starter-stack/rigforge) rig that serves its enriched read API
adds a version badge and a row of chips next to its name — CPU governor and throttling state,
firmware board, HugePages, power draw and H/s-per-watt, the active tuning target and next autotune,
and watchdog temperature. Alarming states (throttling, thermal hold, a non-performance governor) read
red or amber; the rest are muted read-outs. Each chip shows only when the rig reports that field, so
a partial reading never leaves a blank, and a plain-xmrig rig shows no chips at all. If RigForge is up
but its miner isn't, the rig stays in the table with a **miner down** chip rather than dropping to
offline. Point the rig's descriptor at the enriched feed to turn this on — see
[Connecting Miners › RigForge enriched feed](workers.md#rigforge-enriched-feed).

Each rig shows accepted and rejected share counts (invalid shares folded into the rejected column as
`3 (+2 inv)` when present). A rig whose reject rate climbs past ~5% gets a red **⚠** flag next to its
rejected count — a rig submitting stale or bad shares (bad overclock, flaky network, clock drift)
rather than earning. Every column is sortable; click **Rejected** to float the worst offenders to the
top. Shares are cumulative since the proxy last started, so a brief early-run blip clears as good
shares accumulate.

Below the table, a **Proxy totals** line sums the stack's share health as reported by xmrig-proxy:
total accepted / rejected (with aggregate reject %) / invalid shares submitted upstream, plus the
best difficulty any share has hit. Hidden until the proxy submits its first shares.

The dashboard also persists these pool-wide counts as a time series: each 30-second poll stores how
much the accepted / rejected / invalid / expired counters advanced (a proxy restart re-baselines the
counters without corrupting the series), retained for 30 days like the hashrate history. `/api/state`
serves the series as `share_stats` and a trailing-24-hour reject rate as `reject_pct_24h` — a rate
over recent shares rather than the cumulative-since-proxy-start percentage in Proxy totals. The same
series drives the `high_reject_rate` [Telegram alert](telegram.md) when the trailing-hour rate
crosses 5%.

### Worker Inspect

With the control channel on (`dashboard.control.enabled`), a worker's name in the Workers Alive table
is a link. Click it to open **Worker Inspect** — a dialog with that rig's live telemetry, an editor
for the writable slice of its config, and the change history. Close it with the ✕ button, a click
outside it, or Escape.

The editor covers the keys RigForge lets the control path change: `pools`, `DONATION`, `autotune`,
`watchdog`, `watchdog_interval_min`, and `max_temp_c`. Nothing else (identity, filesystem paths, API
ports, the control token) is editable from here. Two modes edit the same set of keys and submit the
same `{worker, changes}` request:

- **Table** (the default) — one row per writable key, prefilled from the last config the dashboard
  applied. Only the rows you touch go into the change.
- **JSON** — paste or edit the writable-keys object directly, for copying a whole profile between
  rigs or moving faster than the table allows. A **Load from file** control inside this mode reads
  a local JSON file into the textarea (`FileReader`, no upload) so you can push the same profile to
  several rigs without retyping it. A malformed edit is flagged inline before you click Apply.

Either way, click **Apply to rig**; RigForge validates the change, applies it, and — if the miner
doesn't come back to a live hashrate — rolls it back on its own. The panel shows the outcome
(applied / rejected / rolled back) and appends it to the history.

To make a rig editable, give it `host`, `token`, and (unless it's the default `8082`) `control_port`
in its [`workers.list[]`](configuration.md#configuration-reference) descriptor. Without a host, or
without a token, the rig isn't a write target and the panel says so.

How it stays safe:

- **The dashboard never holds the rig's token.** It spools the worker name and the change into the
  same host-side control channel [the config editor uses](#configuration-view); the host resolves the
  rig's address and token from `config.json` and dials the rig. A compromised dashboard container can
  neither read the token nor point the write at a host it wasn't configured for (the same
  [SSRF rule](workers.md#per-worker-overrides) as the read path).
- **Fail-closed.** The write path exists only when the control channel is on, which requires a
  dashboard password; every request carries the CSRF header; and only the writable allowlist is
  accepted, at every layer.
- **Masked values stay masked.** If a writable value is ever a masked secret (the same
  `{__secret__: true}` sentinel the [Configuration view](#configuration-view) uses), the table
  editor renders it as a blank password field, never as JSON you could copy or mangle; leave it
  blank to keep it, type a value to replace it. JSON mode carries the sentinel through untouched
  unless you edit that key yourself.

RigForge keeps no config history on the rig, so Pithead owns it: every change the dashboard applies is
recorded with its keys, outcome, and time. Because the rig's enriched feed doesn't expose the writable
config *values*, the editor prefills from the last config the dashboard applied — not a live read of
the rig — so a change made directly on the rig (via `rigforge.sh`) won't show here until the next
dashboard apply.

Below the change history sits a **Hashrate by config version** table: each *applied* change, with the
rig's measured hashrate (the same per-rig `worker_history` samples, taken roughly every 5 minutes)
averaged over the window that version was active — from the moment it was applied to the moment the
next one was, or now for the current version. A version with no samples yet (just applied) shows a
dash rather than zero. This is a correlation over existing data, not a new measurement — no rig-side
change was needed to add it — so use it to compare versions empirically ("config #3 did 5.1 kH/s,
config #4 did 4.8 kH/s") rather than as a precise A/B test; a version's window can include restarts,
sync gaps, or other noise the average doesn't separate out.

### Simple vs. Advanced view

A **Simple / Advanced** toggle sits above the chart. **Simple** (the default) shows the chart, the
Overview summary, and the worker table. **Advanced** swaps the Overview for cards that break out the
same data in more detail: **My P2Pool Node Stats**, **Global P2Pool Stats**, **XvB Donation Stats**,
**XMR Network**, **Tari Merge-Mining**, and the **P2Pool Earnings (estimated)** calculator below. The
choice is remembered across reloads.

The earnings estimates and the XvB tier calculator live only in Advanced view. Simple view shows a
one-time banner pointing there; it goes away once you dismiss it or open Advanced view, and stays
away across reloads.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/launch/advanced.png">
  <img alt="Dashboard — Advanced view" src="../images/launch/advanced-light.png">
</picture>

### P2Pool Earnings (estimated)

A P2Pool mining calculator (Advanced view). It estimates the XMR earned from P2Pool mining, plus
the XTM the same hashrate merge-mines alongside it, from your P2Pool hashrate and the live network
figures.

The card is split into tabs — **Monero**, **Tari**, **XvB**, and **Energy** — driven by one
**what-if hashrate** input that sits above the tabs, so switching tabs keeps the value you entered.
Monero holds the XMR/day·month·year figures, time-to-share, and block reward; Tari holds the solo
time-to-block, per-block reward, and per-day average; XvB holds the tier/cost block and the
per-tier payout comparison. The XvB tab appears only when XvB is enabled, and the Energy tab only
when the fleet reports power (see [Energy & profit](#energy--profit)).

It is scoped to P2Pool — **not** an XvB calculator:

- **XvB donations are excluded.** Hashrate you route to XvB earns no P2Pool payout, so it isn't
  counted. The default is your P2Pool 1h-average hashrate, the *same* `P2Pool (1h)` figure shown
  in the header and the Overview / My Node cards, which already excludes any XvB-donated slice. So
  if you're running an XvB split, the estimate reflects your real P2Pool earnings, not an inflated
  total, and it stays consistent with the hashrate shown elsewhere on the page. (When that average
  is 0, a fresh start with no history yet, or donating everything to XvB, the estimate is 0 until
  you enter a what-if value.)
- **Tari merge-mining is included — but it is SOLO, so income is lumpy.** Merge-mining puts the same
  P2Pool hashrate to work on the Tari chain at no cost to the XMR side, but here it is **solo**: you
  get the *whole* Tari block reward at once when your own hashrate finds a Tari block, not as a
  steady trickle. At the current network difficulty that can be **months** between blocks, so the
  honest headline is the expected **time to a Tari block** (`difficulty ÷ hashrate`) and the full
  **per-block reward** — the per-day XTM figure is only a long-run average, not steady income. The
  estimate assumes the merge-mine channel stays connected; while merge-mining is inactive or Tari is
  still syncing, the XTM rows show `—` and the XMR figures are unaffected. XvB-donated hashrate does
  not merge-mine, so the same P2Pool-only default keeps the XTM estimate honest too.

| Field | Meaning |
|---|---|
| **Your P2Pool Hashrate** | The hashrate the estimate is based on. Defaults to your **P2Pool 1h average** (the same figure the header shows, excluding any XvB-donated portion); type a different value (e.g. `50k`, `1.2 MH/s`) to see a **what-if** projection if you added or removed P2Pool hashpower. |
| **XMR / day · month · year** | Expected Monero earned over each horizon, computed as `hashrate × block reward ÷ network difficulty`, the standard variance-free mining expectation. P2Pool's zero-fee PPLNS payout makes this the right long-run expectation. |
| **Est. Time to Tari Block** | Expected time for your hashrate to solo-find one Tari block: `network difficulty ÷ hashrate`. This is the honest headline for solo merge-mining — the reward lands here, all at once. `—` while merge-mining is inactive or Tari is still syncing. |
| **XTM per Block** | The full Tari block reward paid when you find a block — you get all of it at once, not spread over time. |
| **XTM / day (avg)** | The Tari block reward spread across the expected time-to-block — a **long-run average**, not steady income. `—` while merge-mining is inactive or Tari is still syncing. |
| **Time / Share** | How long, on average, that hashrate takes to find one P2Pool (sidechain) share. |
| **XMR Block Reward** | The current Monero block reward, for context. |

> **These are estimates, not guarantees.** Mining is variance-heavy, so real payouts swing well
> above and below these figures. The calculator says so in a disclaimer on the card. If the
> network figures aren't available yet, the card shows `—` rather than a bogus number.

### Energy & profit

The **Energy** tab turns "what does my hashrate earn" into "what does it earn *after power*." It
sums each worker's power draw and shows fleet efficiency, and — once you set a price — the net
profit after electricity.

Power draw comes from RigForge's enriched feed (the `watts` and `hs_per_watt` in the `rigforge`
block, sampled via RAPL every 15s — see [Connecting Miners](workers.md#rigforge-enriched-feed)). A
worker whose feed reports no watts (macOS, a non-RigForge rig, an older kit) can carry a manual
estimate: add `"watts": <number>` to its `workers.list[]` descriptor and it counts toward the
total, marked *estimated*. A worker with neither a measured nor a configured draw is left out and
the **Fleet Power** figure turns amber to show the total is a lower bound, not a fabricated zero.

The tab always shows fleet watts, H/s-per-watt, and energy use (kWh per day/month/year, a naive
extrapolation of the current draw). Three prices add the rest, and each is optional:

| Config | Adds |
|---|---|
| `dashboard.energy.cost_per_kwh` | **Power cost** per day/month/year (`kWh × price`). |
| `dashboard.energy.xmr_price`    | **Net profit** per day/month/year, P2Pool XMR earnings × your XMR price, minus power cost. |
| `dashboard.energy.tari_price`   | Folds Tari merge-mining earnings into that same net profit, at your Tari price. Requires `xmr_price` to be set too. |

All three are in your `dashboard.energy.currency` label (e.g. `USD`, `EUR`) — a label only, no
conversion happens. Leave `cost_per_kwh` unset and the tab shows only draw and efficiency; set it
but leave `xmr_price` unset and you get the energy cost but no net. Net profit scales with the same
what-if hashrate as the other tabs (power draw does not — it is the measured fleet), and it goes red
when power costs more than it earns.

Net profit counts **P2Pool XMR**, plus **Tari** merge-mining earnings once you also set
`tari_price` (Tari's contribution uses the same what-if Tari/day estimate the Tari tab already
shows). Leave `tari_price` at `0`/unset and net profit is P2Pool XMR only — the card's heading and
the Net/day tooltip say exactly which figure you're looking at, so it's never silently partial.
**XvB stays excluded** either way: it's raffle status, not a clean per-day income estimate, so
folding it in would mean guessing. **No price feed ships for either coin:** fetching an exchange
rate is a clearnet request this privacy-first stack avoids, so you supply both prices yourself (see
[Privacy › Runtime egress](privacy.md#runtime-egress)). An opt-in, Tor-routed price feed is a
possible follow-up, not implemented here.

### Payout confirmation

Everything above is a **model**. The earnings card also shows what actually landed in your wallet,
when you give the stack a way to check the chain. Set `monero.view_key` (the private **view** key
for your payout address) and the stack runs a **view-only** `monero-wallet-rpc` against your local
node, scanning for confirmed incoming payouts. P2Pool pays each miner's share directly in a Monero
block's coinbase, so the wallet is the only ground truth that a payout arrived. The card then shows
**Confirmed** totals — 24 hours, 7 days, and all-time XMR — beside the estimate, and a
`payout_confirmed` alert fires once per payout (Telegram and the other sinks).

The dashboard polls the wallet on a slow cadence (about every 5 minutes) and records each confirmed
payout to a small local table, so a restart never re-alerts. Coinbase outputs become spendable only
after 60 blocks; a payout is recorded and announced when it's **confirmed in a block**, not when it
matures — once, never twice. A pruned node confirms payouts fine (coinbase outputs are never pruned). If the
wallet is still doing its first scan or is briefly unreachable, the confirmed figure stays put
rather than erroring.

> **The view key is a secret. Treat it like a password.** A view key **cannot spend** — it can only
> scan — but it reveals every incoming payout amount and its timing to anyone who can read it. The
> stack keeps it in the owner-only `.env`, never logs or echoes it, keeps it off the dashboard
> Configuration editor, and never puts it on a container command line. It stays on the box: the
> view-only `monero-wallet-rpc` is published only to the host loopback (`127.0.0.1:18082`), runs
> non-root with a read-only root filesystem, and authenticates the dashboard with a generated
> password. **Phase 1 is local node only** — scanning through a third-party daemon would change the
> trust story, so a view key set with `monero.mode: remote` is refused. To rotate it, get a fresh
> view key from your wallet and replace `monero.view_key`. Leave `monero.view_key` empty (the
> default) and none of this runs — the card shows only the estimate.

The **Tari** side of the merge-mine works the same way (#462). Tari merge-mining here is solo — the
whole block reward lands at once when your hashrate finds a Tari block, so a payout is a rare, large
event worth confirming. Set `tari.view_key` and `tari.spend_public_key` (both exported from your
Tari wallet) and the stack runs a **view-only** `minotari_console_wallet` against your local Tari
node. The Tari tab of the earnings card then shows **Confirmed** XTM totals (24 hours, 7 days,
all-time) beside the time-to-block estimate, and the same `payout_confirmed` alert fires once per
Tari payout, carrying the chain. The Tari view key is a secret and is handled exactly like the
Monero one — owner-only `.env`, never logged or on a container command line, off the Configuration
editor — with one extra safeguard: because Tari has no key-import file, the three wallet secrets are
delivered to the container through a tmpfs secret mount, so they never appear in `docker inspect`.
Local Tari node only. Its restore point is a **birthday** (`tari.payout_scan_birthday`, days since
the Unix epoch), not a block height. Leave `tari.view_key` empty and none of the Tari half runs.

### XvB Tier (raffle)

A block inside the earnings card, driven by the same what-if hashrate input, that answers "which
XMRvsBeast tier could this hashrate hold, and what would it cost?". Hidden entirely while XvB is
disabled (`xvb.enabled: false`). It shows tier status only — deliberately no raffle entries or win
odds, because there are none to show: the raffle winner is drawn at random among everyone above
the threshold, so donating more than the threshold buys zero extra win chance.

| Field | Meaning |
|---|---|
| **Sustainable Tier** | The highest XvB donor tier the entered hashrate sustains while leaving P2Pool its share of the split — the same auto rule the donation controller uses (`hashrate × max donation fraction ≥ tier threshold`, default fraction 0.85). `None` when even the lowest tier is out of reach. |
| **Hashrate Cost** | What holding that tier costs: about its threshold in **continuous** donation, because XvB qualifies a tier on both the 1h and 24h credited averages. This hashrate earns no P2Pool shares while donated. |
| **Current Tier** | The tier your credited XvB donation clears right now (the lower of XvB's 1h and 24h averages). |
| **Target Tier** | The tier the donation controller is configured to aim for (`xvb.donation_level`), flagged when your hashrate can't sustain it. |

Below the tier figures, a **per-tier payout comparison** dropdown weighs each donor tier three ways:

| Field | Meaning |
|---|---|
| **Expected (XvB)** | XvB's own published expected reward for the tier, in XMR per year. This is XvB's pre-computed `reward_calc` figure for the tier's donor round, fetched over Tor from `reward_estimate_pub.txt` — the dashboard does not re-derive it. It is the raffle expectation across all qualifiers, so donating **above** the tier threshold does not raise it. `estimate unavailable` when the fetch is stale or failed — never a stale figure implied fresh. |
| **Cost / yr** | The P2Pool earnings given up by donating the tier threshold for a year: `threshold × the P2Pool daily rate × 365`, using the same rate the Monero tab shows. |
| **Net / yr** | Expected minus Cost. Shown only when XvB's estimate is available; otherwise the cost stands alone. |

The estimate is fetched over Tor on the same cadence and staleness rules as the XvB stats card, so
a quiet feed degrades to `estimate unavailable` rather than showing an old number. Pick a tier to
compare, e.g. Whale against VIP Donor, at a glance.

Raffle mechanics, flat: the winner of a donor round is drawn at random among wallets above the
tier threshold on both credited averages; a win terminates if the 1h average then drops below the
round minimum; and collecting any win needs a share in the P2Pool PPLNS window (what XvB calls
being a "VIP"). So the optimum donation is the minimum that clears your tier — never more. A tier
is raffle status, not an XMR payout, and the card says so. The tier thresholds come from the
server's tier table — the same one the donation controller steers by — so the two can't disagree.

NOTE: on the mini/nano sidechains the block adds a reminder that switching the P2Pool sidechain
resets your PPLNS shares — and with them XvB win collectability until a new share lands.

**Raffle Wins log.** The *XvB Donation Stats* card (Advanced view) lists the rounds your wallet
actually won — time, round type, and the hashrate XvB credited the win at — newest first, capped at
the 20 most recent. The dashboard reads XvB's public winners log about every half hour over Tor,
matches your wallet by the masked form the file uses, and stores each win permanently, so the list
(and the chart's gold stars) survives restarts and covers wins far older than the ~4 days the file
itself keeps. Each new win is also announced once in the dashboard's container log. The file
carries only masked wallets and the fetch sends nothing about you.

### Pool Cadence & Luck

A read-only card (Advanced view) that answers "is my share-finding on pace?" with four figures:

| Field | Meaning |
|---|---|
| **Since Pool's Last Block** | Time since the pool found a Monero block — **pool-wide**, not a payout to you specifically. Pool blocks are what trigger PPLNS payouts, so a long gap here means the whole pool is waiting, not that your rigs are misbehaving. |
| **Est. Time / Share** | How long your P2Pool hashrate takes, on average, to find one sidechain share: `share difficulty ÷ your P2Pool 1h average`. The same figure the earnings calculator shows as Time / Share. |
| **Luck** | Actual vs. expected shares in the PPLNS window, as a percentage: `expected = your 1h average × window length ÷ share difficulty`, `luck = actual ÷ expected × 100`. Over 100 % means you found shares faster than the math predicts (running lucky); under 100 %, slower. |
| **Your PPLNS Weight** | The sum of the difficulty of **your** shares inside the PPLNS window — the figure that sizes your slice of the next pool payout. Distinct from the pool-wide PPLNS Weight in the My P2Pool Node Stats card, which covers *everyone's* shares. |

Luck and Est. Time / Share need a P2Pool hashrate average and a live share difficulty; on a fresh
start (no history yet) the card shows `—` until the first samples land. Every figure derives from
data the dashboard already stores — the per-share difficulty recorded with each found share — so
there is nothing to configure.

---

## Configuration view

Edit `config.json` from the dashboard. Off by default: set `dashboard.control.enabled: true` in
`config.json`, set a `dashboard.auth.password` (required — this channel can change the payout
wallet, so it refuses to run without a login), and run `./pithead apply`. A **Configuration**
button then appears next to the Simple/Advanced toggle.

Two edit modes build the same candidate config and submit it through the same pipeline below
([#529](https://github.com/p2pool-starter-stack/pithead/issues/529)):

- **Form** (the default) pins a **Core** group at the top — the same wallet-address /
  `monero.mode` / `p2pool.pool` / dashboard-auth-and-host shortlist
  [`./pithead setup`](getting-started.md#3-run-setup) asks, read from the one file the wizard and
  this view share, [`config.core-keys.json`](../config.core-keys.json), so the two can't drift
  apart. Below it, the rest of the schema is grouped into **logical sections**
  ([#611](https://github.com/p2pool-starter-stack/pithead/issues/611)) an operator recognizes —
  Wallets & payout, Monero node, Mining, Workers, Dashboard & access, Notifications, Energy, Alerts
  & thresholds, System / advanced — instead of one section per top-level `config.json` key, so a
  grab-bag key like `dashboard` (auth, remote access, the energy calculator, alert thresholds, …)
  splits across the sections its fields actually belong to. Each section is a collapsed `<details>`
  as before; within **Notifications**, the 26 `telegram.events` toggles, the ntfy/webhook sinks,
  and Healthchecks each nest one level deeper into their own collapsed sub-group
  ([#612](https://github.com/p2pool-starter-stack/pithead/issues/612)) instead of dominating the
  section's field list. Rows in a section whose fields span more than one top-level key carry their
  full dotted path (`monero.view_key`, `tari.view_key`) so two leaves with the same name read as two
  different keys; a single-key section keeps the shorter relative label — its heading names the rest.
  A config path no logical section claims still renders, in a catch-all
  **Other** group — a new schema key can't silently vanish from the editor, and a frontend test
  fails loudly if one ever would. `workers.list[]` (the per-rig descriptors) isn't a form field
  here — a variable-length list has no single form control for it — edit it via
  [Worker Inspect](#worker-inspect) or `config.json` directly.

  A field the control gate wouldn't actually commit renders **greyed out**
  ([#613](https://github.com/p2pool-starter-stack/pithead/issues/613)): disabled, its value shown
  read-only, with a tooltip ("Host-only — edit `config.json` and run `./pithead apply`") instead of
  letting you edit it and finding out only at Save. The editable set is derived from the same
  allowlist the gate enforces (see below) and surfaced on `GET /api/config` as `_editable_keys`, so
  it can't drift from what the gate actually accepts; a greyed field never enters the staged edit
  set at all.
- **JSON** edits the whole fetched config as one text block, for operators who'd rather paste than
  click through fields. A **Load from file** control (`FileReader`, no upload) fills it from a
  saved `config.json`, the same pattern [Worker Inspect's JSON mode](#worker-inspect) uses. A
  malformed edit is flagged inline before you click Save. JSON mode edits the whole config as text,
  so grouping and the host-only grey-out (both display-layer, form-mode only) don't apply to it —
  the gate still validates and gates it identically to form mode.

The flow mirrors the CLI's `apply` either way:

1. The form/textarea is prefilled from a pre-masked copy of `config.json` the host renders into the
   control spool ([#440](https://github.com/p2pool-starter-stack/pithead/issues/440)). Secrets (the
   dashboard password, the Telegram bot token, node RPC credentials, the stratum password) show as
   "set — leave blank to keep"; their values never enter the dashboard container, let alone the
   browser — leaving one untouched sends a sentinel back (JSON mode carries it through verbatim
   too), and the host swaps in the live value when it stages the change.
2. **Save & preview changes** stages the edited config on the host, which dry-runs it and returns
   the same change preview `./pithead apply` prints — one row per changed setting, disruptive rows
   (⚠) styled as warnings. A config that fails validation is rejected here with pithead's own
   error message; nothing is applied.
3. Confirm. If the preview flags any change disruptive (⚠), you must type `APPLY` first. The
   commit runs `pithead apply -y` on the host and recreates only the containers whose config
   changed.

Most settings cannot be committed from the dashboard — the host-side runner holds an explicit
allowlist of operational settings (pool tier, XvB enable and donation level, alert toggles,
memory limits, time zone, the energy-calculator prices, …) and default-denies a change, in any
direction, to anything else. Form mode's grey-out (above) is that SAME allowlist surfaced to the
browser up front, not a separate approximation of it — so what renders editable is exactly what
the gate will commit. The allowlist gates BOTH edit modes identically regardless — JSON mode is a
different way to assemble the candidate config, not a different validation path, so it can't
smuggle a change the form couldn't make:
wallets, the dashboard login and onion settings, the control channel itself, the Tor egress
firewall, clearnet toggles, node endpoints, and every credential. It likewise refuses anything
the preview flags disruptive (⚠). Apply those from the host with `./pithead apply`; out-of-band
approval from the dashboard is tracked in
[#338](https://github.com/p2pool-starter-stack/pithead/issues/338).

A pool switch (`p2pool.pool` main/mini/nano) carries its standing warning: p2pool re-syncs the new
sidechain and your PPLNS window (and XvB shares) reset.

How it works underneath: the dashboard container cannot run `pithead` or write host files. It
drops a typed JSON change request into `./data/control/requests/` — its only writable leg of the
spool — and a root systemd path unit (`pithead-control`) runs `pithead control-run-pending`, which
validates the request, dry-runs or applies the staged copy, and writes the outcome to the
read-only `results/` mount plus an audit line (timestamp, logged-in user, action, outcome, and
the names of the changed settings) to `audit/control.log`. The container cannot forge results,
alter a staged config between preview and commit, or rewrite the audit log. A failed apply keeps
the previous config at `config.json.bak-control` and surfaces pithead's error in the view.
Operational details:
[Operations › Editing config from the dashboard](operations.md#editing-config-from-the-dashboard).

### Access log and recent config changes

Below the form, the Configuration view shows two read-only security panels
([#349](https://github.com/p2pool-starter-stack/pithead/issues/349)):

- **Access log.** Recent dashboard requests from Caddy's access log — time, HTTP status, method,
  path, and the logged-in user — plus a count of failed logins (401s) in the last 24 hours. Over
  Tor there is no source IP to trace or block, so the signal is the *rate* of failures: five or
  more in a day shows a warning to rotate the dashboard password (set a new
  `dashboard.auth.password`, run `./pithead apply`) and, if the onion address may have leaked,
  `./pithead rotate-dashboard-onion`. The log is always on; entries appear once Caddy has handled
  a request on this version.
- **Recent config changes.** The control channel's host-side audit trail: one row per handled
  request — timestamp, dashboard user, preview/commit, outcome, and the *names* of the settings
  that changed. Values are never recorded (several are secrets). Shown only when
  `dashboard.control.enabled` is on.

Both panels read host-written files through read-only mounts, and the dashboard treats every
field in them as hostile input — a request path is attacker-chosen bytes — so each string is
stripped to a safe character set before it is served. See
[Operations › Watching for intruders](operations.md#watching-for-intruders) for the log paths,
size bounds, and rotation steps.

## Upgrading from the dashboard

With `dashboard.control.enabled: true` (the same flag as the Configuration view) and a newer
release detected, an **Upgrade to vX.Y.Z** button appears next to the new-release badge. It runs
the release install's documented update — download the new bundle, run `./pithead upgrade` — on
the host, with no SSH:

1. Click the button and type `UPGRADE` to confirm. An upgrade recreates every container, so the
   dashboard disconnects briefly and miners reconnect to the stratum port; config, wallet, and
   chain data are untouched.
2. The dashboard drops an upgrade request into the same control spool the Configuration view
   uses. The host-side runner asks the GitHub release API (over Tor) for the latest release
   itself and refuses the request unless the version you confirmed **is** that latest release and
   it is newer than the running version — the container proposes, the host decides what gets
   installed. Attempts are limited to one per 10 minutes, and every one is written to the audit
   log.
3. The runner downloads the release bundle (over Tor). On the
   [versioned deploy layout](operations.md#the-deploy-box-layout) — a `pithead-vX.Y.Z` install
   dir with its data directories outside it — the bundle is extracted into a fresh sibling
   `pithead-v<new>/`, `config.json`, `.env`, and the control spool are carried over, and the new
   dir's `./pithead upgrade` runs; on success `current ->` repoints there and the previous dir
   stays intact as the rollback copy. Any other layout (a plain `pithead/` extract, or data
   directories living inside the install dir) gets the bundle extracted in place instead. Either
   way, `upgrade` re-renders the generated config and pulls the new images. The page rides out
   its own restart and reports the outcome; reload when it says the new version is up.

The version the container proposes is never trusted as the target: the host independently fetches
the latest tag from GitHub, and the bundle it downloads is for that host-derived tag. The bundle
is also cryptographically verified
([#376](https://github.com/p2pool-starter-stack/pithead/issues/376)): with the release public key
on disk (`cosign.pub`, shipped in every signed bundle), the runner fetches the release's
`pithead.tar.gz.sig` and checks the download against the key it **already holds** before
extracting a byte — a bad or missing signature, or a missing cosign binary, fails the upgrade
with nothing changed, and a swapped key inside a malicious bundle cannot vouch for itself. The
`pithead upgrade` that follows verifies each image's signature the same way before pulling. An
install without `cosign.pub` (older than the first signed release) still rests on TLS to GitHub
(over Tor) plus that tag pinning, and says so in the journal — upgrading once to a signed release
picks up the key. See [Releasing › Signed releases](releasing.md#signed-releases).

**Upgrading from v1.7.x or older shows one last false failure.** Dashboard versions before
v1.8.1 treat the reverse proxy's brief 502 — normal while the dashboard container recreates
itself — as a hard failure, and the page polling during the upgrade is still the *old* version:
the fix ships inside the release being installed, so it cannot protect the jump that installs
it. If the modal reports "Error: HTTP 502" but the version badge shows the new version and the
new-release banner is gone, the upgrade landed; reload the page to clear the modal (or confirm
with `./pithead version` on the host). This happens once — upgrades started from v1.8.1 or
later ride out the restart.

The button never appears on a source checkout — the runner refuses the request there, since a dev
install updates with `git pull`. If the upgrade fails, the result says so in the view: a failed
release lookup or bundle download changes nothing; a failure during `pithead upgrade` leaves
containers that were not yet recreated on the previous images, and finishing up is one
`./pithead upgrade` on the host. There is no automatic rollback — the images of the previous
release stay on disk, and `docker compose` state is recoverable the same way as a failed
CLI upgrade.

## Tips

- **First visit certificate warning.** With `dashboard.secure: true` (the default), Caddy uses a
  self-signed certificate, so your browser shows a one-time "connection is not private" warning.
  Accept it to proceed. To use plain HTTP instead, set `dashboard.secure: false` and run
  `./pithead apply`.
- **Reaching it from another machine.** Use the stack server's hostname/IP. If the hostname doesn't
  resolve on your LAN, set `dashboard.host` in `config.json` to an address that does.
- **Adding a login.** The dashboard has no password by default, fine for a private LAN appliance. If
  the box is shared or reachable beyond your LAN, set `dashboard.auth.password` (keep
  `dashboard.secure: true`) and run `./pithead apply` to put a login prompt in front of it. See
  [Configuration › Exposing the dashboard safely](configuration.md#exposing-the-dashboard-safely).
- **On your phone.** The layout is responsive. Open the same URL and it reflows to a single column
  with a stacked header.
- **Stuck on Sync Mode?** The chain is still downloading. Check `./pithead logs monerod` /
  `./pithead logs tari` for steady progress; see
  [Operations › Troubleshooting](operations.md#troubleshooting) if a node looks stalled.

For how the switching engine decides the P2Pool/XvB split, see
[Architecture › Algorithmic switching](architecture.md#algorithmic-switching).
