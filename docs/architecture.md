# Architecture

The stack orchestrates eight containerized services via Docker Compose. Together they give you a
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
| 7 | **Docker Proxy** | A secure, read-only proxy for the Docker socket, so the dashboard can query container stats without full Docker access. |
| 8 | **Caddy** | A reverse proxy that serves the dashboard over HTTPS (automatic local TLS) on the LAN. |

## High-level diagram

```mermaid
graph TD
    subgraph "Docker Stack"
        Dashboard[Dashboard & Algo Engine]
        Tor[Tor Anonymity Service]
        DockerProxy[Docker Socket Proxy]

        subgraph "Mining Core"
            Monerod[Monero Daemon]
            P2Pool[P2Pool Node]
            Tari[Tari Base Node]
            Proxy[XMRig Proxy]
        end
    end

    subgraph "External"
        Workers["Hardware Workers (XMRig)"]
        XvB[XMRvsBeast Pool]
        Internet[Tor Network / Internet]
    end

    Workers -- "Stratum (3333)" --> Proxy

    Dashboard -- "Controls" --> Proxy
    Dashboard -- "Monitors" --> DockerProxy

    Proxy -- "Switches between" --> P2Pool
    Proxy -- "Switches between" --> XvB

    P2Pool <-->|RPC/ZMQ| Monerod
    P2Pool -->|Merge Mine| Tari

    Monerod <-->|Tx Broadcast| Tor
    Tari <-->|P2P Traffic| Tor
    P2Pool <-->|P2P Traffic| Tor

    Tor <--> Internet
```

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
- **Hardened dashboard.** Security headers (a self-only CSP, `X-Frame-Options: DENY`,
  `nosniff`, a `Referrer-Policy`) and a sanitized error handler; it reaches Docker only through a
  read-only socket proxy.
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
