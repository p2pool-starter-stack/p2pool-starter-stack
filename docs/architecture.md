# Architecture

The stack runs nine containerized services under Docker Compose. This doc lists each service and how
they connect.

The services provide a Monero full node, P2Pool sidechain mining, Tari merge-mining, a single worker
endpoint, and a monitoring dashboard. All node P2P and transaction traffic routes over Tor; no public
port forwarding is required.

## The services

| # | Service | Role |
|---|---|---|
| 1 | **Monerod** | The Monero daemon (full node). Configured for restricted RPC and Tor transaction broadcasting. |
| 2 | **P2Pool** | The mining sidechain. Supports Main, Mini, and Nano pools. |
| 3 | **Tari Base Node** | The Minotari node, merge-mined alongside Monero. |
| 4 | **XMRig Proxy** | The single stratum endpoint (`:3333`) all mining hardware connects to; the switching engine reconfigures it at runtime. |
| 5 | **Tor** | Provides SOCKS5 proxies and hidden services (onion addresses) for the other containers. |
| 6 | **Dashboard** | The web monitoring UI and the algorithmic switching engine. |
| 7 | **Docker Proxy** | A **read-only** proxy onto the Docker socket so the dashboard can read container stats/logs — no write access. |
| 8 | **Docker Control** | A second, minimal socket proxy scoped to **only** `start`/`stop` (nothing else — not create/kill/exec/reads), so the dashboard can reject workers when a node is down (Issue #31), hold p2pool + xmrig-proxy until the chains finish syncing (Issue #35), and switch a clearnet-syncing node back to Tor once it's synced (Issue #234). Kept separate so its write grant can't widen the read-only proxy. |
| 9 | **Caddy** | A reverse proxy that serves the dashboard over HTTPS (automatic local TLS) on the LAN. |

## High-level diagram

```mermaid
flowchart TB
    %% ── External actors ──
    You(["👤 You · Browser"])
    Workers(["⛏️ XMRig Workers"])
    Net(["🌐 Tor Network / Internet"])

    %% ── External services the dashboard calls out to (each labeled with its route) ──
    Telegram(["✈️ Telegram<br/>alerts + commands"])
    Hooks(["🔔 Webhook / ntfy<br/>alert sinks"])
    HC(["🩺 Healthchecks.io<br/>dead-man's switch"])
    XvB(["🎲 XMRvsBeast<br/>pool + stats"])
    GitHub(["🐙 GitHub<br/>release check"])
    Coin(["💱 CoinGecko<br/>price feed"])

    subgraph stack ["🐳 Pithead"]
        direction TB

        Caddy["🔒 Caddy<br/>HTTPS reverse proxy"]
        Dashboard["📊 Dashboard<br/>+ XvB switching engine"]
        DockerProxy["🛡️ Docker Socket Proxies<br/>read-only + start/stop"]
        Tor["🧅 Tor<br/>anonymity layer"]

        subgraph core ["⚙️ Mining Core"]
            direction TB
            Proxy["🔀 XMRig Proxy<br/>:3333"]
            P2Pool["🔵 P2Pool"]
            Monerod["🟠 Monero Node"]
            Tari["🟣 Tari Node"]
        end
    end

    You ==>|HTTPS| Caddy
    Caddy --> Dashboard
    Workers ==>|"Stratum 3333"| Proxy
    Dashboard ==>|"worker API · LAN"| Workers

    %% Dashboard internal control + monitoring (never leaves the box)
    Dashboard -.->|controls| Proxy
    Dashboard -.->|monitors| DockerProxy
    Dashboard -.->|"reads stats & sync"| core

    %% ── Dashboard egress — every outbound call is routed through Tor (🟢), so none leak the host IP ──
    Dashboard ==>|"🚨 alerts + commands · 🟢 Tor"| Tor
    Dashboard ==>|"🔔 webhook/ntfy alerts · 🟢 Tor"| Tor
    Dashboard ==>|"🩺 liveness ping · 🟢 Tor"| Tor
    Dashboard ==>|"📈 XvB stats + raffle · 🟢 Tor"| Tor
    Dashboard ==>|"🆕 update check · 🟢 Tor"| Tor
    Dashboard ==>|"💱 XMR/XTM prices · 🟢 Tor"| Tor

    Proxy ==>|hashrate| P2Pool
    Proxy ==>|"hashrate · 🟢 Tor"| Tor

    P2Pool <-->|"RPC / ZMQ"| Monerod
    P2Pool -->|merge-mine| Tari

    Monerod <-->|"tx + P2P · 🟢 Tor"| Tor
    Tari <-->|"P2P · 🟢 Tor"| Tor
    P2Pool <-->|"P2P · 🟢 Tor"| Tor
    Tor <--> Net

    %% Tor exit reaches each external service
    Net -.-> Telegram
    Net -.-> Hooks
    Net -.-> HC
    Net -.-> XvB
    Net -.-> GitHub
    Net -.-> Coin

    classDef ext fill:#1e293b,stroke:#64748b,color:#e2e8f0;
    classDef ctrl fill:#1d4ed8,stroke:#93c5fd,color:#eff6ff;
    classDef priv fill:#6d28d9,stroke:#c4b5fd,color:#f5f3ff;
    classDef mine fill:#047857,stroke:#6ee7b7,color:#ecfdf5;

    class You,Workers,Net,Telegram,Hooks,HC,XvB,GitHub,Coin ext;
    class Caddy,Dashboard ctrl;
    class Tor,DockerProxy priv;
    class Proxy,P2Pool,Monerod,Tari mine;

    style stack stroke:#475569,stroke-width:1px;
    style core stroke:#10b981,stroke-width:1px,stroke-dasharray:5 4;
```

Reading the diagram: thick arrows carry inbound connections and every path that **leaves the box** —
each egress edge is tagged with its route, and **🟢 Tor** means it exits through the Tor daemon (a Tor
exit IP, never your host's). Dotted arrows are the dashboard's internal control and monitoring, which
never leave the machine. The dashboard makes six outbound internet calls — the **Telegram** bot
(alerts + commands), the **webhook/ntfy** alert sinks, the **Healthchecks.io** liveness ping, the
**XvB** calls (stats, raffle registration, winners), the **GitHub** release check, and the opt-in
**CoinGecko** price feed (`dashboard.energy.price_feed`, XMR + XTM spot prices) — and all six are
Tor-routed, so enabling any of them never reveals where your stack runs (the webhook/ntfy sinks have
a `notifications.tor: false` opt-out for LAN endpoints Tor can't reach; see
[Telegram › Webhook and ntfy sinks](telegram.md#webhook-and-ntfy-sinks)). The dashboard also polls
each rig's RigForge API over the **LAN** (worker stats, config applies) — that traffic stays on your
local network and never touches the internet, so it carries no Tor tag. Node
colors group services by role: 🟦 control plane (Caddy, Dashboard), 🟪 privacy and isolation (Tor,
Docker socket proxies), and 🟩 the mining core. In remote-node mode the bundled 🟠 Monero node isn't
started, and P2Pool talks to your external node instead.

> The one exception is **optional clearnet initial sync** (`monero.clearnet_initial_sync` /
> `tari.clearnet_initial_sync`, default **off**): while active, that node's P2P leaves Tor to sync
> faster and its IP is exposed until it finishes, after which it reverts to Tor automatically (#234).
> The Telegram bot alerts you the whole time it's exposed. See [Privacy](privacy.md).

## Privacy by design

The stack is Tor-first. The Tor daemon provides hidden services (onion addresses) for Monero, Tari,
and P2Pool, so inbound connectivity needs no public IPv4 port forwarding. Monero and Tari route their
P2P and transaction traffic over Tor, and the clearnet DNS lookups those nodes formerly leaked are
closed (monerod checkpoints/blocklist/update-check, Tari DNS seeds + Pulse). The node's RPC binds to
`127.0.0.1` by default; set `monero.rpc_lan_access: true` for LAN access.

Two outbound yield paths used clearnet in v1.0 and exposed the host IP: P2Pool's outbound sidechain
peers and XvB donation mining. As of v1.1 both route over Tor by default, each with an opt-out
(measured cost ~10 % of yield on `mini`; see the
[Tor-vs-clearnet benchmark](benchmarks/tor-vs-clearnet.md)). The one-time install and image pulls
reveal the host IP once. See [Privacy & network egress](privacy.md) for the connection-by-connection
map and the remaining lock-down steps.

## Security posture

- **Containerized, non-root, least-privilege.** Services run in containers, and every one runs its
  main process as a non-root user (not uid 0). pithead owns the data directories and chowns each
  bind-mount to the uid its container uses, so a breakout or RCE in any daemon lands as an
  unprivileged user. Where a privilege is genuinely needed (e.g. P2Pool's memory locking) it's
  granted narrowly: P2Pool relies on an unlimited `memlock` ulimit rather than running privileged.
  The leaf services (Caddy, the dashboard, the two Docker socket proxies, and `xmrig-proxy`) run
  with `no-new-privileges`, and all of them drop every Linux capability (`cap_drop: [ALL]`). Caddy
  keeps only `NET_BIND_SERVICE` so it can bind `:80`/`:443`. The dashboard writes its history
  database as that non-root user into its (matching-owned) volume, so it no longer needs root's
  file-permission capability and drops all caps like the others. Every service runs with a
  read-only root filesystem (#377): each process can write only to its own data mount (blockchain
  DBs, Tor's keys, the dashboard's history, Caddy's certs) plus a small, size-capped ephemeral
  `tmpfs` (`noexec`, wiped on restart) for rendered configs and scratch. A compromised process
  cannot stage tooling in, or persist changes to, its container image.
- **Mining endpoint stays on the LAN.** The stratum port (`3333`) your rigs connect to is meant for
  your local network, never the public internet. It's published on all interfaces by default so LAN
  rigs work without extra config; narrow it with `p2pool.stratum_bind` (a specific LAN IP, or
  `127.0.0.1`) and firewall it to your LAN. See [Connecting Miners › Firewall](workers.md#firewall).
- **Verified binaries.** Third-party binaries are SHA256-verified during the image build.
- **Pinned versions.** Service images and binaries are pinned to known-good versions.
- **Hardened dashboard.** Security headers (a restrictive `Content-Security-Policy`,
  `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`) and a sanitized error handler. It reaches
  Docker only through socket proxies, never the raw socket: a read-only one for stats/logs, and a
  separate control proxy scoped to `start`/`stop` only (its ruleset denies create/kill/exec and all
  reads). Splitting them means the write grant needed for node-down worker failover can't widen the
  read-only proxy's access. General Docker write access stays off. Both proxies are **isolated off
  the mining bridge** (#345): they sit on their own network and are published only to the host
  loopback, so the host-networked dashboard reaches them but no mining container can — a compromised
  `monerod`/`tari`/`p2pool`/`xmrig-proxy` cannot read other containers' env (inspect) or start/stop
  the stack through them.
- **Locked-down config.** `config.json` is created `chmod 600` (owner-only), and the internal RPC
  proxy token is generated once and preserved across re-runs.

---

## Algorithmic switching

The dashboard distributes hashrate centrally rather than requiring per-rig pool configuration. All
workers connect to one endpoint, the `xmrig-proxy` service on port `3333`, and the decision engine
reallocates that hashrate between P2Pool (zero-fee Monero + Tari payouts) and XMRvsBeast (XvB) bonus
rounds. It donates the minimum needed to hold the target tier and routes the rest to P2Pool.

### How the engine decides

1. **Tier targeting.** The engine picks which XvB donation tier to aim for, set by
   `xvb.donation_level`:
   - `auto` (default): the highest tier your current hashrate can sustain.
   - a specific tier: `donor`, `vip`, `whale`, or `mega`. A specific tier is honored even if your
     hashrate is too low to hold it, in which case the dashboard shows a **⚠ Hashrate low for tier**
     badge.

   The four tiers and the donation hashrate each requires, which you must sustain on both your
   1-hour and 24-hour donation averages (as measured by XMRvsBeast), are set by the XvB raffle:

   | Tier | Donation hashrate to hold it |
   |---|---|
   | `donor` | **1 kH/s** (1,000 H/s) |
   | `vip` | **10 kH/s** (10,000 H/s) |
   | `whale` | **100 kH/s** (100,000 H/s) |
   | `mega` | **1 MH/s** (1,000,000 H/s) |

   > NOTE: the name "VIP" is overloaded. The `vip` tier above is a donation level (10 kH/s). Don't
   > confuse it with the dashboard's **Raffle Eligible** box. That box turns green only when you're set
   > up to actually win and collect a payout: donating at least the `donor` tier (on credited 1h+24h,
   > the same threshold tracked by **Current Tier**) and holding a P2Pool PPLNS share. XvB's bare rule
   > calls just-having-a-share a "VIP"; the dashboard is stricter, so a green "Yes" means a win is
   > actually paid. See the [Dashboard](dashboard.md) guide.

   Because the XvB raffle picks winners at random, donating above a tier's threshold earns nothing
   extra. The engine donates only enough to hold the target tier and routes the rest to P2Pool.

2. **Dynamic proxy reconfiguration.** A feedback controller watches your measured 1h / 24h donation
   averages and reconfigures the `xmrig-proxy` to send just enough time to XvB to stay in tier:
   ramping donation up when you fall behind and easing off as you catch up, with the remainder going
   to P2Pool. The controller edits the proxy config only; your workers keep their existing connection
   to `3333` and need no changes.

The result: the chosen XvB tier holds with minimal donation, and remaining hashrate mines Monero +
Tari on P2Pool. The dashboard's hashrate chart shades the P2Pool/XvB split over time.

---

## See also

- [The Dashboard](dashboard.md): Sync Mode and the live operational view.
- [Configuration](configuration.md): the `xvb.*` settings, data directories, and remote nodes.
- [Connecting Miners](workers.md): connecting hardware to the single `3333` endpoint.
