# The Dashboard

The dashboard is a single web page that monitors every service, charts your hashrate, and shows
the decisions made by the algorithmic XvB switching engine. Caddy serves it over HTTPS at
`https://<your-hostname>` (the URL is printed when the stack starts).

The dashboard has two states. While your nodes catch up to the network it shows Sync Mode. Once
both chains are synced it switches automatically to the full operational view.

---

## Sync Mode

The dashboard shows Sync Mode the first time you start the stack, or any time the Monero or Tari
node is still catching up. A `Syncing…` badge appears next to the hostname, the headline reads
*"System is currently synchronizing with the network,"* and no hashrate is routed yet.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/launch/sync.png">
  <img alt="Sync Mode" src="../images/launch/sync-light.png">
</picture>

Sync Mode gives each chain its own progress card so you can see exactly where things stand:

- **Monero Sync**: current verified block height vs. the network tip, with the number of blocks
  remaining. A green check means this chain is fully caught up. It also shows whether the node is
  running Pruned or Full and its on-disk DB size (also in the **XMR Network** panel of the
  operational view), so you can confirm a reused chain matches your `monero.prune` setting.
- **Tari Sync**: the same, as a percentage ring, for the Minotari chain.

The top bar shows live host telemetry throughout: CPU, load average, RAM, HugePages (so you can
confirm RandomX optimization is active), and disk usage. Useful for watching resources during the
initial download.

A Monero or Tari node can't mine until it has downloaded and verified the blockchain. On a first
run that takes from a few hours to over a day depending on your hardware, disk, and network. Sync
Mode makes the progress visible. Once the required chains report fully synced, the dashboard swaps
Sync Mode for the operational view and mining begins. No refresh or restart needed.

While the chains are syncing, the dashboard keeps `p2pool` and `xmrig-proxy` stopped (a
`Miner held (sync)` badge shows next to the hostname) and starts them automatically once they're
ready. Running p2pool against an unsynced node achieves nothing and floods Tari's logs with
merge-mining chatter that buries the messages you'd want while debugging a sync. Releasing the
miner is one-way: once it starts it stays up. By default the stack waits for both Monero and Tari.
With [`dashboard.tari_required: false`](configuration.md) it waits only for Monero and starts
mining while Tari finishes syncing in the background.

> **Want to skip most of the wait?** Point the stack at an existing synced blockchain, or connect
> to a remote node. See [Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

You can also follow sync progress from the command line:

```bash
./pithead logs monerod
./pithead logs tari
```

---

## The operational view

Once both nodes are synced, the dashboard shows the full operational view.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/launch/simple.png">
  <img alt="Operational dashboard — Simple view" src="../images/launch/simple-light.png">
</picture>

The page updates live every 30 seconds, refreshing each panel in place rather than reloading the
whole page. Your scroll position, the column you've sorted the worker table by, and the chart all
stay put between updates.

### Top bar

A persistent status strip across the top shows the hostname, host telemetry (CPU, load, RAM,
HugePages, disk), your total hashrate, and 1h / 24h routed averages for both P2Pool and XvB so you
can read your split. Next to the disk readout, an `XMR Pruned` / `XMR Full` badge shows the Monero
node's blockchain mode.

When the dashboard host is a name (not already an IP), the machine's IP address shows beside it as
`hostname @ ip` (e.g. `pithead.local @ 192.168.1.42`). This is a reliable way back in when the
hostname doesn't resolve from your phone or another machine on the LAN.

A small version badge sits beside the hostname so you know which build is running. A released
build shows the version (e.g. `v1.3.0`); a development or working-tree build shows a dashed
`dev · branch @ commit` marker instead, so it's never mistaken for a release. It appears on every
screen, including Sync Mode, which makes it easy to confirm what you're on when sharing a
screenshot in a bug report. On a `dev` build but would rather run a published release? See
[Switching a source checkout to release images](operations.md#switching-a-source-checkout-to-release-images).

When a newer Pithead release is out, a clickable `New release vX.Y.Z available ↗` badge appears
next to the version badge, linking to the GitHub release. It's a heads-up only. It never updates
anything; you upgrade with `./pithead upgrade` when you're ready. The check is on by default and
routed over Tor (so it can't reveal your IP). Turn it off with `dashboard.check_for_updates: false`
(see [Configuration](configuration.md#configuration-reference)).

### Hero band

A strip of headline KPIs sits just below the top bar, so the numbers that matter read the moment
the page loads:

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

A red `⚠ DB write failing` badge appears if the dashboard can't write to its own SQLite database (a
full or read-only disk, a permissions problem). The dashboard keeps serving live data, but hashrate
history, shares, and stats won't survive a restart until it's fixed. It's surfaced rather than lost
silently.

While a node is down, the dashboard also rejects workers so they fail over to the backup pools
you've configured, instead of sitting idle on a stack that can't mine for them. A sustained outage
stops the `xmrig-proxy` container (a `Workers rejected` badge shows) and a confirmed recovery
restarts it. monerod is required to mine, so a monerod outage always rejects. Tari is merge-mining
gravy, so whether a Tari outage rejects follows [`dashboard.tari_required`](configuration.md): when
it's `true` (default) a Tari outage rejects too; set it `false` to keep mining Monero straight
through a Tari outage. (Rejection never triggers for a remote monerod, since the stack doesn't
manage that node.)

**Non-blocking Tari.** With `tari_required: false`, a Tari-only (re)sync no longer takes over the
screen: the operational view stays up, mining continues, and a `Tari syncing` badge shows Tari's
progress until it catches up and merge mining resumes.

### Hashrate chart

A time-series chart of your hashrate with selectable ranges (1h / 24h / 1w / 1mo) that switch
without reloading the page. The shaded bands show how hashrate was split between P2Pool and XvB
over time, so you can see the switching engine at work.

An **Avg** control picks the hashrate-averaging window the chart plots: `1 Min` / `10 Min` /
`1 Hr` / `12 Hr` / `24 Hr` (the native windows xmrig-proxy reports). This is independent of the
Range control. The range sets how much *time* the x-axis spans; the averaging window sets how
*smooth* each plotted point is. Short windows (1–10 min) react quickly, so a rig dropping or
joining shows up within a poll or two. Long windows (12–24 h) ride out the noise to show the
underlying trend. Your choice is remembered across reloads. Two things to know:

- `10 Min` is the default and matches the dashboard's headline hashrate, so the chart looks the
  same as before unless you change it.
- The longer windows need that much rig uptime to fill. Right after a (re)start, `12 Hr`/`24 Hr`
  read low and climb until enough history exists. Per-window history is also kept only *going
  forward* from the version that introduced this control, so those lines are flat at the far-left
  edge of a long range until new data accumulates. That's expected, not a fault.

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
| **Tari Mining** | Whether merge mining of Tari is active and healthy. |
| **Wallets** | Your configured Monero and Tari payout addresses. |

### Workers Alive

A live table of every connected rig: worker name, IP, uptime, and per-worker hashrate over several
windows (e.g. 10s / 60s / 15m), so you can spot a rig that has dropped off or is underperforming.
A worker that's connected but whose direct API is unreachable still counts (with proxy-derived
hashrate); a worker whose miner has stopped drops out of the total. On a narrow screen the table
scrolls sideways within its card, so its columns stay readable rather than stretching the page.

Each rig also shows its accepted and rejected share counts (with invalid shares folded into the
rejected column as `3 (+2 inv)` when present). A rig whose reject rate climbs past ~5% gets a red
**⚠** flag next to its rejected count. That's a quick way to catch a rig submitting stale or bad
shares (bad overclock, flaky network, clock drift) rather than earning. Every column is sortable,
so you can click **Rejected** to float the worst offenders to the top. The shares are cumulative
since the proxy last started, so a brief early-run blip clears itself as good shares accumulate.

Below the table, a **Proxy totals** line sums the whole stack's share health as reported by the
xmrig-proxy: total accepted / rejected (with the aggregate reject %) / invalid shares submitted
upstream, plus the best difficulty any of your shares has hit. It's hidden until the proxy has
submitted its first shares.

### Simple vs. Advanced view

A **Simple / Advanced** toggle sits above the chart. **Simple** (the default) keeps the page to
the essentials: the chart, the Overview summary, and the worker table. **Advanced** swaps the
Overview for a set of cards that break out the same data in more detail: **My P2Pool Node Stats**,
**Global P2Pool Stats**, **XvB Donation Stats**, **XMR Network**, **Tari Merge Mining**, and the
**P2Pool Earnings (estimated)** calculator below. Your choice is remembered across reloads.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/launch/advanced.png">
  <img alt="Dashboard — Advanced view" src="../images/launch/advanced-light.png">
</picture>

### P2Pool Earnings (estimated)

A P2Pool mining calculator (Advanced view). It estimates the XMR earned from P2Pool mining only,
turning your P2Pool hashrate and the live Monero network figures into a rough payout estimate. It
is deliberately scoped to P2Pool. It is **not** an XvB or a Tari calculator:

- **XvB donations are excluded.** Hashrate you route to XvB earns no P2Pool payout, so it isn't
  counted. The default is your P2Pool 1h-average hashrate, the *same* `P2Pool (1h)` figure shown
  in the header and the Overview / My Node cards, which already excludes any XvB-donated slice. So
  if you're running an XvB split, the estimate reflects your real P2Pool earnings, not an inflated
  total, and it stays consistent with the hashrate shown elsewhere on the page. (When that average
  is 0, a fresh start with no history yet, or donating everything to XvB, the estimate is 0 until
  you enter a what-if value.)
- **Tari merge-mining is excluded.** Tari is earned alongside Monero but is a separate payout
  (its own calculator is planned).

| Field | Meaning |
|---|---|
| **Your P2Pool Hashrate** | The hashrate the estimate is based on. Defaults to your **P2Pool 1h average** (the same figure the header shows, excluding any XvB-donated portion); type a different value (e.g. `50k`, `1.2 MH/s`) to see a **what-if** projection if you added or removed P2Pool hashpower. |
| **XMR / day · month · year** | Expected Monero earned over each horizon, computed as `hashrate × block reward ÷ network difficulty`, the standard variance-free mining expectation. P2Pool's zero-fee PPLNS payout makes this the right long-run expectation. |
| **Time / Share** | How long, on average, that hashrate takes to find one P2Pool (sidechain) share. |
| **XMR Block Reward** | The current Monero block reward, for context. |

> **These are estimates, not guarantees.** Mining is variance-heavy, so real payouts swing well
> above and below these figures. The calculator says so in a disclaimer on the card. If the
> network figures aren't available yet, the card shows `—` rather than a bogus number. Tari
> earnings and an XvB tier projection aren't included yet.

---

## Tips

- **First visit certificate warning.** With `dashboard.secure: true` (the default), Caddy uses a
  self-signed certificate, so your browser shows a one-time "connection is not private" warning.
  Accept it to proceed. To use plain HTTP instead, set `dashboard.secure: false` and run
  `./pithead apply`.
- **Reaching it from another machine.** Use the hostname/IP of the stack server. If your hostname
  doesn't resolve on your LAN, set `dashboard.host` in `config.json` to an address that does.
- **Adding a login.** By default the dashboard has no password, which is fine for a private LAN
  appliance. If the box is shared or reachable beyond your LAN, set `dashboard.auth.password` (keep
  `dashboard.secure: true`) and run `./pithead apply` to put a login prompt in front of it. See
  [Configuration › Exposing the dashboard safely](configuration.md#exposing-the-dashboard-safely).
- **On your phone.** The dashboard is responsive. Open the same URL on a phone and the layout
  reflows to a single column with a stacked header, so you can check on the stack from the couch.
- **Stuck on Sync Mode?** That usually just means the chain is still downloading. Check
  `./pithead logs monerod` / `./pithead logs tari` for steady progress; see
  [Operations › Troubleshooting](operations.md#troubleshooting) if a node looks stalled.

For how the switching engine decides the P2Pool/XvB split, see
[Architecture › Algorithmic switching](architecture.md#algorithmic-switching).
