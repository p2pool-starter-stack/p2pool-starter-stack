# The Dashboard

The dashboard is the control center for your stack: a single web page that monitors every
service, charts your hashrate, and surfaces the decisions made by the algorithmic XvB switching
engine. It's served over HTTPS by Caddy at `https://<your-hostname>` (the URL is printed when the
stack starts).

The dashboard has **two states**. While your nodes are catching up to the network it shows
**Sync Mode**; once both chains are synced it switches automatically to the full **operational
view**.

---

## Sync Mode

The first time you start the stack — or any time the Monero or Tari node is still catching up to
the network — the dashboard shows **Sync Mode**. A **`Syncing…`** badge appears next to the
hostname, the headline reads *"System is currently synchronizing with the network,"* and no
hashrate is routed yet.

![Sync Mode](../images/syncing.png)

Sync Mode gives each chain its own progress card so you can see exactly where things stand:

- **Monero Sync** — current verified block height vs. the network tip, with the number of blocks
  remaining. A green check means this chain is fully caught up. It also shows whether the node is
  running **Pruned** or **Full** and its on-disk DB size (also in the **XMR Network** panel of the
  operational view) — handy for confirming a reused chain matches your `monero.prune` setting.
- **Tari Sync** — the same, as a percentage ring, for the Minotari chain.

The top bar still shows live host telemetry throughout — CPU, load average, RAM, **HugePages**
(so you can confirm RandomX optimization is active), and disk usage — which is handy for keeping
an eye on resources during the initial download.

**Why this screen exists:** a Monero or Tari node can't mine until it has downloaded and verified
the blockchain, which on a first run can take from a few hours to over a day depending on your
hardware, disk, and network. Sync Mode makes that progress visible instead of leaving you
guessing. Once the required chains report fully synced, the dashboard automatically swaps Sync
Mode for the operational view and mining begins — no refresh or restart needed.

While the chains are syncing, the dashboard keeps `p2pool` and `xmrig-proxy` **stopped** (a
**`Miner held (sync)`** badge shows next to the hostname) and starts them automatically once
they're ready. Running p2pool against an unsynced node achieves nothing and floods Tari's logs
with merge-mining chatter that buries the messages you'd actually want while debugging a sync.
Releasing the miner is one-way — once it starts it stays up. By default the stack waits for
**both** Monero and Tari; if you've set [`dashboard.tari_required: false`](configuration.md), it
waits only for Monero and starts mining while Tari finishes syncing in the background.

> **Want to skip most of the wait?** Point the stack at an existing synced blockchain, or connect
> to a remote node. See [Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

You can also follow sync progress from the command line:

```bash
./stack.sh logs monerod
./stack.sh logs tari
```

---

## The operational view

Once both nodes are synced, the dashboard shows the full operational view.

![Operational dashboard](../images/dashboard.png)

### Top bar

A persistent status strip across the top shows the hostname, host telemetry (CPU, load, RAM,
HugePages, disk), your **total hashrate**, and headline **1h / 24h averages** for both P2Pool and
XvB so you can see your split at a glance. Next to the disk readout, an **`XMR Pruned`** /
**`XMR Full`** badge shows the Monero node's blockchain mode at a glance.

### Node status & failover

If a local node becomes unreachable, a red **`monerod DOWN`** or **`Tari DOWN`** badge appears in
the top bar (after a short debounce, so a momentary blip doesn't flap). Sync state is read from
monerod's `get_info` RPC and Tari's gRPC, so "down" means the node itself is unreachable — not just
that a log line changed.

While a node is down, the dashboard also **rejects workers** so they fail over to the backup pools
you've configured, instead of sitting idle on a stack that can't mine for them — a sustained outage
stops the `xmrig-proxy` container (a **`Workers rejected`** badge shows) and a confirmed recovery
restarts it. monerod is required to mine, so a monerod outage always rejects. Tari is merge-mining
gravy, so whether a Tari outage rejects follows [`dashboard.tari_required`](configuration.md): when
it's `true` (default) a Tari outage rejects too; set it `false` to keep mining Monero straight
through a Tari outage. (Rejection never triggers for a remote monerod — the stack doesn't manage
that node.)

**Non-blocking Tari.** With `tari_required: false`, a Tari-only (re)sync no longer takes over the
screen: the operational view stays up, mining continues, and a **`Tari syncing`** badge shows Tari's
progress until it catches up and merge mining resumes.

### Hashrate chart

A time-series chart of your hashrate with selectable ranges (1h / 24h / 1w / 1mo). The shaded
bands show how hashrate was split between **P2Pool** and **XvB** over time, so you can see the
switching engine at work.

### Overview

The summary panel pulls the key numbers together:

| Field | Meaning |
|---|---|
| **Mining Mode** | What the stack is routing hashrate to right now (e.g. P2Pool, XvB, or a split). |
| **Total Hashrate** | Your combined hashrate across all workers. |
| **Share in Window** | Your shares in the current P2Pool PPLNS window. |
| **Last Share** | Time since your last accepted share. |
| **P2Pool 1h / 24h avg** | Time-weighted average hashrate routed to P2Pool. |
| **XvB 1h / 24h avg** | Donation hashrate credited by the XMRvsBeast API (the definitive record). |
| **Current Tier** | The XvB tier you're currently holding. |
| **Target Tier** | The tier the engine is aiming for (from `xvb.donation_level`). If your hashrate can't sustain an explicitly chosen tier, a **⚠ Hashrate low for tier** badge appears. |
| **Tari Mining** | Whether merge mining of Tari is active and healthy. |
| **Wallets** | Your configured Monero and Tari payout addresses. |

### Workers Alive

A live table of every connected rig — worker name, IP, uptime, and per-worker hashrate over
several windows (e.g. 10s / 60s / 15m) — so you can spot a rig that has dropped off or is
underperforming. A worker that's connected but whose direct API is unreachable still counts (with
proxy-derived hashrate); a worker whose miner has stopped drops out of the total.

---

## Tips

- **First visit certificate warning.** With `dashboard.secure: true` (the default), Caddy uses a
  self-signed certificate, so your browser shows a one-time "connection is not private" warning.
  Accept it to proceed. To use plain HTTP instead, set `dashboard.secure: false` and run
  `./stack.sh apply`.
- **Reaching it from another machine.** Use the hostname/IP of the stack server. If your hostname
  doesn't resolve on your LAN, set `dashboard.host` in `config.json` to an address that does.
- **Stuck on Sync Mode?** That usually just means the chain is still downloading. Check
  `./stack.sh logs monerod` / `./stack.sh logs tari` for steady progress; see
  [Operations › Troubleshooting](operations.md#troubleshooting) if a node looks stalled.

For how the switching engine decides the P2Pool/XvB split, see
[Architecture › Algorithmic switching](architecture.md#algorithmic-switching).
