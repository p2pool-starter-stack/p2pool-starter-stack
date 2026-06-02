# Architecture

The stack orchestrates nine containerized services via Docker Compose. Together they give you a
private Monero full node, decentralized P2Pool mining, Tari merge mining, a single worker
endpoint, and a monitoring dashboard — all behind Tor, with no public port forwarding required.

## The services

| # | Service | Role |
|---|---|---|
| 1 | **Monerod** | The Monero daemon (full node). Configured for restricted RPC and Tor transaction broadcasting. |
| 2 | **P2Pool** | The decentralized mining sidechain, with support for Main, Mini, and Nano pools. |
| 3 | **Tari Base Node** | The Minotari node, merge-mined alongside Monero. |
| 4 | **XMRig Proxy** | A single connection point for all your mining hardware; the switching engine reconfigures it on the fly. |
| 5 | **Tor** | A centralized anonymity layer providing SOCKS5 proxies and hidden services (onion addresses) for the other containers. |
| 6 | **Dashboard** | The web monitoring UI and the algorithmic switching engine. |
| 7 | **Docker Proxy** | A **read-only** proxy onto the Docker socket so the dashboard can read container stats/logs — no write access. |
| 8 | **Docker Control** | A second, minimal socket proxy scoped to **only** `start`/`stop` (nothing else — not create/kill/exec/reads), so the dashboard can reject workers when a node is down (Issue #31). Kept separate so its write grant can't widen the read-only proxy. |
| 9 | **Caddy** | A reverse proxy that serves the dashboard over HTTPS (automatic local TLS) on the LAN. |

## High-level diagram

```mermaid
flowchart TB
    %% ── External actors ──
    You(["👤 You · Browser"])
    Workers(["⛏️ XMRig Workers"])
    XvB(["🎲 XMRvsBeast Pool"])
    Net(["🌐 Tor Network / Internet"])

    subgraph stack ["🐳 P2Pool Starter Stack"]
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

    Dashboard -.->|controls| Proxy
    Dashboard -.->|monitors| DockerProxy
    Dashboard -.->|"reads stats & sync"| core

    Proxy ==>|hashrate| P2Pool
    Proxy ==>|hashrate| XvB

    P2Pool <-->|"RPC / ZMQ"| Monerod
    P2Pool -->|merge-mine| Tari

    Monerod <-->|tx broadcast| Tor
    Tari <-->|P2P| Tor
    P2Pool <-->|P2P| Tor
    Tor <--> Net

    classDef ext fill:#1e293b,stroke:#64748b,color:#e2e8f0;
    classDef ctrl fill:#1d4ed8,stroke:#93c5fd,color:#eff6ff;
    classDef priv fill:#6d28d9,stroke:#c4b5fd,color:#f5f3ff;
    classDef mine fill:#047857,stroke:#6ee7b7,color:#ecfdf5;

    class You,Workers,XvB,Net ext;
    class Caddy,Dashboard ctrl;
    class Tor,DockerProxy priv;
    class Proxy,P2Pool,Monerod,Tari mine;

    style stack stroke:#475569,stroke-width:1px;
    style core stroke:#10b981,stroke-width:1px,stroke-dasharray:5 4;
```

**Reading the diagram:** **thick arrows** carry mining hashrate and inbound connections, **dotted
arrows** are the dashboard's control and monitoring, and **solid arrows** are internal service
data and anonymized network traffic. Node colors group services by role — 🟦 control plane
(Caddy, Dashboard), 🟪 privacy & isolation (Tor, Docker socket proxy), and 🟩 the mining core.
In remote-node mode the bundled 🟠 Monero node isn't started, and P2Pool talks to your external
node instead.

## Privacy by design

Privacy isn't bolted on — it's the default. A dedicated Tor daemon provides hidden services
(onion addresses) for Monero, Tari, and P2Pool, so the stack participates in each network without
exposing your home IP and **without any public IPv4 port forwarding**. Monero broadcasts
transactions over Tor, and the node's RPC is bound to localhost by default (opt into LAN access
explicitly via `monero.rpc_lan_access`).

## Security posture

- **Containerized & least-privilege.** Services run in containers; where privileges are needed
  (e.g. P2Pool's memory locking) they're granted narrowly via specific Linux capabilities rather
  than running fully privileged.
- **Verified binaries.** Third-party binaries are SHA256-verified during the image build.
- **Pinned versions.** Service images and binaries are pinned to known-good versions.
- **Hardened dashboard.** Security headers (a restrictive `Content-Security-Policy`,
  `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`) and a sanitized error handler; it reaches
  Docker only through socket proxies, never the raw socket: a **read-only** one for stats/logs, and
  a separate **control** proxy scoped to `start`/`stop` only (its ruleset denies create/kill/exec
  and all reads). Splitting them means the write grant needed for node-down worker failover can't
  widen the read-only proxy's access. General Docker write access stays off.
- **Locked-down config.** `config.json` is created `chmod 600` (owner-only), and the internal RPC
  proxy token is generated once and preserved across re-runs.

---

## Algorithmic switching

Rather than asking you to configure each rig for a different pool, the stack manages hashrate
distribution **centrally**. All your workers connect to a single endpoint — the `xmrig-proxy`
service on port `3333` — and the dashboard's decision engine continuously reallocates that
hashrate between **P2Pool** (Monero + Tari mining) and **XMRvsBeast (XvB)** bonus rounds to
maximize your yield.

### How the engine decides

1. **Tier targeting.** The engine picks which XvB donation tier to aim for, set by
   `xvb.donation_level`:
   - `auto` (default) — the highest tier your current hashrate can sustain.
   - a specific tier — `donor`, `vip`, `whale`, or `mega`. A specific tier is honored **even if
     your hashrate is too low to hold it**, in which case the dashboard shows a
     **⚠ Hashrate low for tier** badge.

   Because the XvB raffle picks winners at random, donating *above* a tier's threshold earns
   nothing extra — so the engine donates only enough to hold the target tier and routes the rest
   to P2Pool.

2. **Dynamic proxy reconfiguration.** A feedback controller watches your measured **1h / 24h
   donation averages** and reconfigures the `xmrig-proxy` to send just enough time to XvB to stay
   in tier — ramping donation up when you fall behind and easing off as you catch up — with the
   remainder going to P2Pool. This happens seamlessly, with **no changes on your workers**.

The result: you stay in your chosen XvB tier with minimal donation, and every spare cycle mines
Monero + Tari on P2Pool. The dashboard's hashrate chart shades the P2Pool/XvB split over time so
you can watch the controller work.

---

## See also

- [The Dashboard](dashboard.md) — Sync Mode and the live operational view.
- [Configuration](configuration.md) — the `xvb.*` settings, data directories, and remote nodes.
- [Adding Workers](workers.md) — connecting hardware to the single `3333` endpoint.
