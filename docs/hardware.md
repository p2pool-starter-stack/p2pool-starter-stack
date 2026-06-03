# Hardware Requirements

This stack involves **two different kinds of machine**, and they have very different hardware
needs:

1. **The stack host** — the one machine that runs `./stack.sh` and the Docker stack (Monero node,
   P2Pool, Tari, the XMRig proxy, the dashboard, Tor). **It does not mine.** It runs the nodes and
   coordinates everything; the actual hashing happens elsewhere.
2. **Worker rigs** — one or more separate machines running [XMRig](https://github.com/xmrig/xmrig).
   These do the real RandomX hashing and point at the stack host's port `3333`. A worker can be the
   same machine as the host, but treating them separately is what lets you scale hashrate.

Size the **host** for nodes, storage, and uptime; size the **workers** for CPU mining performance.

> **This page covers the stack host.** Miner (worker-rig) hardware lives with the miner kit — see
> [RigForge](https://github.com/p2pool-starter-stack/rigforge#-hardware-requirements).

---

## The stack host

### At a glance

| Resource | Minimum | Recommended |
|---|---|---|
| **CPU** | 4 cores, 64-bit x86 (AVX2 advised) | 6–8+ cores with **AVX2** |
| **RAM** | **16 GB** | **32 GB** |
| **Disk — pruned node** | ~150 GB SSD | 300 GB+ SSD |
| **Disk — full node** | ~300 GB SSD | 600 GB+ SSD |
| **Network** | Always-on broadband | Unmetered broadband |
| **OS** | Ubuntu Server **24.04 LTS** | Ubuntu Server 24.04 LTS |

> These figures assume the **default local Monero node** with **pruning on** and **HugePages
> enabled**. Remote-node mode and other tweaks lower them — see
> [Lighter-footprint options](#lighter-footprint-options).

### Where these numbers come from

The host runs several services in one box, so its requirement is really the **sum of what each
service needs**, plus headroom for the operating system. Here's the per-component breakdown, taken
from each project's own guidance:

| Service | RAM it wants | Disk | Notes |
|---|---|---|---|
| **[Monero node](https://docs.getmonero.org/running-node/)** (`monerod`) | **4 GB** minimum; more RAM = bigger DB cache and faster sync | **~95 GB** pruned · **~230 GB** full — and growing | SSD strongly recommended. Not run at all in remote-node mode. |
| **[P2Pool](https://github.com/SChernykh/p2pool)** | **~2.3 GB** for the RandomX dataset it uses to verify blocks fast (`--light-mode` skips it, saving ~2 GB, but verifies slower) | tiny (sidechain state) | Needs a 64-bit CPU with **AVX2** and a synced `monerod`. |
| **[Tari base node](https://www.tari.com/integration-guide)** (`minotari_node`) | **4 GB** minimum, **8 GB+** recommended; grows over time | **50 GB+** SSD | Light enough to run on a Raspberry Pi; the stack caps its memory so growth can't take the host down. |
| **XMRig proxy · Tor · Caddy · dashboard · Docker** | a few hundred MB combined | a few GB (Docker images) | These coordinate and serve the UI — they don't mine, so no special CPU. |

Add the three heavy services together — Monero (4 GB), P2Pool (~2.3 GB), Tari (4 GB) — plus a
couple of GB for the OS, page cache, and supporting containers, and you land on the **16 GB / ~150 GB
minimum** above. Double the RAM and disk so Monero gets a roomier cache and both chains have space
to grow, and you reach the **32 GB / 300 GB recommendation**.

> **Heads-up on RandomX RAM:** Monero and P2Pool both want large memory pages for RandomX, so they
> share **one ~6 GB HugePages reservation** rather than each adding their own — see
> [Memory](#memory) for what that means for the 16 GB floor.

### CPU

The host CPU runs the nodes, P2Pool's block verification, the proxy, and the dashboard — it is
**not** your miner, so it doesn't need to be a high-end mining chip. Two things matter:

- **AVX2 is strongly recommended.** P2Pool verifies blocks with RandomX, which runs far better with
  AVX2; setup warns *"AVX2 not detected. Mining performance will be poor."* if it's missing. (P2Pool
  also requires a 64-bit CPU — ARMv7 and older aren't supported.)
- **More cores speed up the first sync.** Monero parallelizes block verification during the initial
  sync: `monero.prep_blocks_threads` defaults to `auto` = **host cores − 2, clamped to 4–8**. So
  6–10 cores let it use the full thread budget while leaving headroom for the rest of the stack.
  After the initial sync, steady-state CPU load is low.

### Memory

**16 GB is the practical floor** with the default configuration. The budget breaks down as:

- **~6 GB reserved for HugePages.** RandomX wants large pages, so setup configures
  `vm.nr_hugepages=3072` (3072 × 2 MB = **6 GB**), shared by `monerod` and P2Pool. This RAM is
  carved out of the kernel up front and is **invisible** to container memory stats — it's gone
  whether or not it's fully used at any moment.
- **Tari** (4 GB+, growing) gets an auto-sized **safety ceiling** (`tari.mem_limit: auto`) so a
  genuine runaway restarts cleanly instead of taking the host down. On a 16 GB host that ceiling
  lands around **7.5 GB**; on 32 GB, around **19 GB**.
- **The OS, page cache, and the lighter containers** take the rest.

On a 16 GB machine this all fits but is tight, which is exactly why Tari is capped. **32 GB is
recommended** if you run a full (unpruned) node, drive a lot of workers, or want long uptimes
without Tari's growth ever pressing on the cap.

> **Running with only 8 GB?** It can boot **only** if you disable HugePages (`./stack.sh setup
> --skip-optimize`), which frees the 6 GB reservation — but it leaves very little headroom and
> hurts RandomX verification performance. Not recommended; prefer 16 GB+.

### Disk

The two blockchains dominate, and an **SSD is strongly recommended** — initial-sync verification
and the node databases do a lot of random I/O that punishes spinning disks. What to provision:

| | Pruned (default) | Full (`monero.prune: false`) |
|---|---|---|
| Monero chain | ~80–100 GB | 200 GB+ |
| Tari chain | 50 GB+ | 50 GB+ |
| P2Pool + dashboard + Docker images | a few GB | a few GB |
| **Plan for** | **~150 GB+ SSD** | **~300 GB+ SSD** |

Both chains **keep growing**, so leave headroom — the *recommended* sizes above (300 GB pruned /
600 GB full) exist for exactly that. Pruning (the default) keeps a fully validating Monero node at a
fraction of the size and is the right choice for almost everyone.

You can put any service's data on a dedicated disk by pointing its `*.data_dir` at an absolute path
— e.g. to keep the Monero blockchain on a separate SSD. See
[Configuration › Data directories](configuration.md#data-directories).

### Network

- **Always-on broadband.** All upstream traffic (Monero, Tari, P2Pool) goes over **Tor**, with **no
  public port forwarding** required — the stack uses hidden services for inbound peers.
- **Initial sync is the heavy part.** The first run downloads and verifies both chains over Tor
  (slower than clearnet): tens of GB pruned, ~200 GB+ for a full Monero node. This can take anywhere
  from a few hours to a day or more. You can avoid it by
  [reusing an existing synced node](configuration.md#reusing-an-existing-node).
- **Steady state is light.** Once synced, bandwidth is modest.
- **LAN reachability for workers.** Each worker rig connects to the host on **port 3333** over your
  local network (plain stratum, not Tor). If the host has a firewall, allow inbound `3333` from your
  LAN.

### Operating system & dependencies

- **Ubuntu Server 24.04 LTS** is the officially supported platform. macOS and other Linux distros
  may work but aren't officially supported.
- The **kernel/HugePages tuning is Linux-only.** On Linux, making HugePages persistent edits GRUB
  and needs a **reboot** (you're prompted first, and can skip with `--skip-optimize`).
- Required software: **Docker Engine**, **Docker Compose v2**, **`jq`**, and **`openssl`**. On
  Ubuntu, `./stack.sh setup` offers to install anything missing — or do it yourself:

  ```bash
  sudo apt update && sudo apt install -y jq docker.io docker-compose-v2 openssl
  ```

---

## Lighter-footprint options

The defaults assume a self-hosted, pruned, HugePages-tuned local node. You can trade some of that
away:

| Want to… | Do this | Saves |
|---|---|---|
| Skip the Monero node entirely | **Remote-node mode** (`monero.mode: remote`) — the bundled `monerod` isn't started | ~80–200 GB disk + Monero's 4 GB RAM/CPU |
| Skip the initial sync wait | [Reuse an existing synced chain](configuration.md#reusing-an-existing-node) | Hours–days + sync bandwidth |
| Free the 6 GB HugePages reservation | `./stack.sh setup --skip-optimize` | ~6 GB RAM (at the cost of RandomX performance) |
| Free RAM for other apps | Lower `tari.mem_limit` (e.g. `"4g"`) | Caps Tari's ceiling lower |
| Keep mining when Tari has issues | `dashboard.tari_required: false` | Tari outages/syncs stop blocking Monero mining |

> Remote-node mode still runs Tari, P2Pool, the proxy, dashboard, and Tor locally — it only drops
> `monerod`. The remote node must be one you control with **ZMQ publishing enabled**; public "open
> node" endpoints don't qualify. See
> [Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node).

---

## Sizing examples

- **Small home setup (pruned):** a 6-core / 16 GB / 240 GB SSD mini-PC as the host, HugePages on,
  with one or two workers pointed at it. Comfortable for getting started.
- **Full node + several workers:** an 8-core / 32 GB / 600 GB SSD host running an unpruned node,
  feeding a handful of dedicated mining rigs. Headroom for Tari growth and long uptimes.
- **Minimal / reuse-an-existing-node:** point the stack at a Monero node you already run (remote
  mode), and the host needs only enough for Tari, P2Pool, the proxy, dashboard, and Tor — far less
  disk and RAM.

> **Sizing the miners** that connect to this host is a separate exercise — their CPU is what
> determines hashrate. See RigForge's
> [Hardware Requirements](https://github.com/p2pool-starter-stack/rigforge#-hardware-requirements).

---

## See also

- [Getting Started](getting-started.md) — prerequisites and first-run setup.
- [Configuration](configuration.md) — pruning, data directories, remote nodes, and `tari.mem_limit`.
- [Connecting Miners](workers.md) — connecting rigs to this host.
- [RigForge](https://github.com/p2pool-starter-stack/rigforge) — provision a tuned miner; miner hardware specs.
- [Architecture](architecture.md) — the services and how they fit together.
