<div align="center">

<img src="./images/pithead-mark.svg" alt="Pithead" width="120">

# Pithead

### Private Monero + Tari merge mining, the whole stack, in one command.

[![CI](https://github.com/p2pool-starter-stack/pithead/actions/workflows/ci.yml/badge.svg)](https://github.com/p2pool-starter-stack/pithead/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform: Ubuntu 24.04](https://img.shields.io/badge/Platform-Ubuntu%2024.04-E95420?logo=ubuntu&logoColor=white)
![Tor](https://img.shields.io/badge/Networking-Tor--only-7D4698?logo=torproject&logoColor=white)

A professional-grade, containerized stack for running a private [Monero](https://www.getmonero.org/)
full node, [P2Pool](https://github.com/SChernykh/p2pool), and [Tari](https://www.tari.com/) merge
mining — engineered for **privacy**, **performance**, and **a setup you can finish before your
coffee gets cold**.

![Dashboard](./images/dashboard.png)

</div>

---

## ✨ Why this stack?

- 🧅 **Private by default.** A built-in Tor daemon gives Monero, Tari, and P2Pool hidden-service
  (onion) addresses. No public port forwarding, no exposing your home IP.
- ⛏️ **Monero + Tari, merge-mined.** Earn on both chains at once — Tari is mined alongside Monero
  through P2Pool with zero extra effort.
- 🧠 **Smart yield optimization.** An algorithmic engine continuously splits your hashrate between
  P2Pool and XMRvsBeast bonus rounds to maximize your return — automatically.
- 🔌 **One endpoint for every rig.** All your workers point at a single address. The stack routes
  hashrate upstream; you never touch a worker config to change pools.
- 📊 **A dashboard that actually tells you things.** Live hashrate, sync progress, PPLNS window,
  per-worker stats, and your P2Pool/XvB split — served over HTTPS on your LAN.
- 🚀 **One-command setup.** An interactive script handles dependencies, config, Tor, and kernel
  tuning, then starts everything for you.
- 🔒 **Hardened out of the box.** Least-privilege containers, SHA256-verified binaries, pinned
  versions, localhost-only RPC, and least-privilege Docker socket proxies (a read-only one for
  stats, plus a separate start/stop-only one for node-down worker failover).

---

## 🚀 Quick Start

> **Platform:** Ubuntu Server **24.04 LTS** is officially supported. Plan for **16 GB+ RAM** and an
> **SSD** (~150 GB pruned / ~300 GB full) — full sizing is in
> [Hardware Requirements](docs/hardware.md). You'll need your Monero and Tari payout addresses handy.

```bash
git clone https://github.com/p2pool-starter-stack/pithead.git
cd pithead
chmod +x pithead
./pithead setup
```

`setup` checks dependencies (and offers to install them on Ubuntu), asks for your wallet
addresses, provisions Tor, tunes the kernel for RandomX, and offers to start the stack. Then:

1. **Open the dashboard** at `https://<your-hostname>` (the script prints the exact URL).
2. **Let it sync.** On first boot the dashboard shows **Sync Mode** while your Monero and Tari
   nodes catch up to the network — it switches to the live view automatically once synced. p2pool
   and the proxy stay parked until then, so the sync logs stay clean.
3. **Connect your miners** by pointing any [XMRig](https://github.com/xmrig/xmrig) rig at
   `YOUR_STACK_IP:3333` (no wallet address needed). New to mining?
   [RigForge](https://github.com/p2pool-starter-stack/rigforge) provisions a tuned worker in one
   command.

📖 **Full walkthrough:** [docs/getting-started.md](docs/getting-started.md)

> **Already have a synced Monero node?** Skip the wait by pointing the stack at your existing
> blockchain — see [Reusing an existing node](docs/configuration.md#reusing-an-existing-node).

---

## 📚 Documentation

| Guide | What's inside |
|---|---|
| **[Getting Started](docs/getting-started.md)** | Prerequisites, install, first-run setup, and what to expect while the node syncs. |
| **[Hardware Requirements](docs/hardware.md)** | Minimum vs. recommended specs for the **stack host** — CPU, RAM, disk, network — and how to run leaner. (Miner specs live in [RigForge](https://github.com/p2pool-starter-stack/rigforge).) |
| **[Configuration](docs/configuration.md)** | Every `config.json` key, applying changes safely, reusing an existing node, and remote Monero nodes. |
| **[The Dashboard](docs/dashboard.md)** | Sync Mode and a tour of the live operational view. |
| **[Connecting Miners](docs/workers.md)** | Point any existing rig at the stack, or spin up a tuned miner with [RigForge](https://github.com/p2pool-starter-stack/rigforge). |
| **[Architecture](docs/architecture.md)** | The nine services, the privacy model, and the algorithmic XvB switching engine. |
| **[Operations & Maintenance](docs/operations.md)** | Full command reference, upgrades, backups, and troubleshooting. |

Browse the full index at **[docs/](docs/README.md)**.

---

## 🏗️ How it works

The stack orchestrates nine services via Docker Compose: a Monero **full node**, **P2Pool**, a
**Tari** base node, an **XMRig proxy** (your single worker endpoint), **Tor** for anonymity, the
**dashboard** + switching engine, a read-only **Docker socket proxy** (plus a tiny start/stop-only
control proxy), and **Caddy** for HTTPS.

```mermaid
flowchart TB
    %% ── External actors ──
    You(["👤 You · Browser"])
    Workers(["⛏️ XMRig Workers"])
    XvB(["🎲 XMRvsBeast Pool"])
    Net(["🌐 Tor Network / Internet"])

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

    Dashboard -.->|controls| Proxy
    Dashboard -.->|monitors| DockerProxy
    Dashboard -.->|"reads stats & sync"| core

    Proxy ==>|hashrate| P2Pool
    Proxy ==>|hashrate| XvB

    P2Pool <-->|"RPC / ZMQ"| Monerod
    P2Pool -->|merge-mine| Tari

    Monerod <--> Tor
    Tari <--> Tor
    P2Pool <--> Tor
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

Read the full breakdown — including the privacy model and the algorithmic switching engine — in
**[Architecture](docs/architecture.md)**.

---

## 🛠️ Common commands

Everything runs through `pithead` (`./pithead help` lists it all):

| Command | Description |
|---|---|
| `./pithead setup` | First-time interactive setup. |
| `./pithead apply` | Preview and apply `config.json` changes. |
| `./pithead up` / `down` / `restart` | Start / stop / restart the stack. |
| `./pithead upgrade` | Rebuild and restart after a `git pull`. |
| `./pithead logs [service]` | Follow logs (all, or one service). |
| `./pithead status` | Container status + health-check of every expected service (warns on anything down). |

Full reference: **[Operations & Maintenance](docs/operations.md)**.

---

## 🤝 Donate

If this stack saved you time and you'd like to support it, donations to this XMR wallet are
appreciated:

```
89VGXHYEYdTJ4qQPoSZSD4BQsXCm6vCjUF2y2Vm42mA8ESLXA4XpmsvWMFB2stQw7p5UXnyZ81EMtgkCYqjYBPow8v7btKv
```

## 📄 License

Provided "as-is" under the [MIT License](./LICENSE).
