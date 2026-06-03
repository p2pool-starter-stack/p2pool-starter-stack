# Hardware Requirements

This stack involves **two different kinds of machine**, and they have very different hardware
needs:

1. **The stack host** — the one machine that runs `./stack.sh` and the Docker stack (Monero node,
   P2Pool, Tari, the XMRig proxy, the dashboard, Tor). **It does not mine.** It runs the nodes and
   coordinates everything; the actual hashing happens elsewhere.
2. **Worker rigs** — one or more separate machines running [XMRig](https://github.com/xmrig/xmrig).
   These do the real RandomX hashing and point at the stack host's port `3333`. A worker can be the
   same machine as the host, but treating them separately is what lets you scale hashrate.

Size the **host** for nodes, storage, and uptime. Size the **workers** for CPU mining performance.

---

## The stack host

### At a glance

| Resource | Minimum | Recommended |
|---|---|---|
| **CPU** | 4 cores, 64-bit x86 | 6–8+ cores with **AVX2** |
| **RAM** | **16 GB** (HugePages on) | **32 GB** |
| **Disk (pruned node)** | ~120 GB SSD | 250 GB+ SSD |
| **Disk (full node)** | ~300 GB SSD | 500 GB+ SSD |
| **Network** | Always-on broadband | Unmetered broadband |
| **OS** | Ubuntu Server **24.04 LTS** | Ubuntu Server 24.04 LTS |

> These figures assume the **default local Monero node** with **pruning on** and **HugePages
> enabled**. Remote-node mode and other tweaks lower them — see
> [Lighter-footprint options](#lighter-footprint-options).

### CPU

The host CPU runs the Monero and Tari nodes, P2Pool (which uses RandomX to **verify** shares and
blocks), the proxy, and the dashboard. It is **not** your miner, so it doesn't need to be a
high-end mining chip — but two things matter:

- **AVX2 is strongly recommended.** RandomX (used by P2Pool for verification) runs far better with
  AVX2. Setup warns *"AVX2 not detected. Mining performance will be poor."* if it's missing — the
  stack still runs, just slower.
- **More cores speed up the initial sync.** Monero block verification during the first sync is
  parallelized: `monero.prep_blocks_threads` defaults to `auto` = **host cores − 2, clamped to
  4–8**. So 6–10 cores let it use the full thread budget while leaving headroom for the rest of the
  stack. After the initial sync, steady-state CPU load is low.

### Memory (RAM)

**16 GB is the practical floor** with the default configuration. The budget breaks down roughly as:

- **~6 GB reserved for HugePages.** RandomX wants large pages, so setup configures
  `vm.nr_hugepages=3072` (3072 × 2 MB = **6 GB**). This RAM is carved out of the kernel up front and
  is **invisible** to container memory stats — it's gone whether or not it's fully used at any
  moment.
- **Tari** needs a few GB and its memory **grows over time**, so the stack puts an auto-sized
  **safety ceiling** on it (`tari.mem_limit: auto`) that lets a genuine runaway restart cleanly
  instead of taking the host down. On a 16 GB host that ceiling lands around **7.5 GB**; on 32 GB,
  around **19 GB**.
- **monerod, P2Pool, Tor, the dashboard, the OS, and page cache** take the rest.

On a 16 GB machine this all fits but is tight, which is exactly why Tari is capped. **32 GB is
recommended** if you run a full (unpruned) node, drive a lot of workers, or want long uptimes
without Tari's growth ever pressing on the cap.

> **Running with only 8 GB?** It can boot **only** if you disable HugePages (`./stack.sh setup
> --skip-optimize`), which frees the 6 GB reservation — but it leaves very little headroom and
> hurts RandomX verification performance. Not recommended; prefer 16 GB+.

### Disk

The blockchains dominate disk usage, and an **SSD is strongly recommended** — initial-sync
verification and the node databases do a lot of random I/O that punishes spinning disks.

| What | Pruned (default) | Full (`monero.prune: false`) |
|---|---|---|
| Monero blockchain | **~80–100 GB** | **200 GB+** and growing |
| Tari (Minotari) chain | a few GB, growing | a few GB, growing |
| P2Pool + dashboard data | small (≤ a few GB) | small |
| Docker images | a few GB | a few GB |
| **Plan for** | **~120 GB+** | **~300 GB+** |

The Monero chain **keeps growing**, so leave headroom. Pruning (the default) keeps a fully
validating node at a fraction of the size and is the right choice for almost everyone; only disable
it if you specifically need the full transaction history.

You can put any service's data on a dedicated disk by pointing its `*.data_dir` at an absolute path
— e.g. to keep the Monero blockchain on a separate SSD. See
[Configuration › Data directories](configuration.md#data-directories).

### Network

- **Always-on broadband.** All upstream traffic (Monero, Tari, P2Pool) goes over **Tor**, with **no
  public port forwarding** required — the stack uses hidden services for inbound peers.
- **Initial sync is the heavy part.** The first run downloads and verifies the whole chain over Tor
  (slower than clearnet): tens of GB pruned, ~200 GB for a full node. This can take anywhere from a
  few hours to a day or more. You can avoid it by
  [reusing an existing synced node](configuration.md#reusing-an-existing-node).
- **Steady state is light.** Once synced, bandwidth is modest.
- **LAN reachability for workers.** Each worker rig connects to the host on **port 3333** over your
  local network (plain stratum, not Tor). If the host has a firewall, allow inbound `3333` from your
  LAN.

### Operating system

- **Ubuntu Server 24.04 LTS** is the officially supported platform.
- The **kernel/HugePages tuning is Linux-only.** On Linux, making HugePages persistent edits GRUB
  and needs a **reboot** (you're prompted first, and can skip with `--skip-optimize`).
- **macOS and other Linux distributions may work** but aren't officially supported; on non-Linux
  hosts the kernel optimization step is skipped automatically.

### Software dependencies

- **Docker Engine** and **Docker Compose v2**
- **`jq`** and **`openssl`**

On Ubuntu, `./stack.sh setup` detects anything missing and offers to install it. To do it manually:

```bash
sudo apt update && sudo apt install -y jq docker.io docker-compose-v2 openssl
```

---

## Lighter-footprint options

The defaults assume a self-hosted, pruned, HugePages-tuned local node. You can trade some of that
away:

| Want to… | Do this | Saves |
|---|---|---|
| Skip the Monero node entirely | **Remote-node mode** (`monero.mode: remote`) — the bundled `monerod` isn't started | ~80–200 GB disk + monerod's RAM/CPU |
| Skip the initial sync wait | [Reuse an existing synced chain](configuration.md#reusing-an-existing-node) | Hours–days + sync bandwidth |
| Free the 6 GB HugePages reservation | `./stack.sh setup --skip-optimize` | ~6 GB RAM (at the cost of RandomX performance) |
| Free RAM for other apps | Lower `tari.mem_limit` (e.g. `"4g"`) | Caps Tari's ceiling lower |
| Keep mining when Tari has issues | `dashboard.tari_required: false` | Tari outages/syncs stop blocking Monero mining |

> Remote-node mode still runs Tari, P2Pool, the proxy, dashboard, and Tor locally — it only drops
> `monerod`. The remote node must be one you control with **ZMQ publishing enabled**; public "open
> node" endpoints don't qualify. See
> [Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node).

---

## Worker rigs (the miners)

Workers are where hashrate actually comes from. Each is a separate machine running XMRig that points
at the host's `3333` endpoint — no wallet address in the worker config. Add as many as you like.

| Resource | Guidance |
|---|---|
| **CPU** | A modern multi-core x86 CPU with **AVX2** is strongly recommended. RandomX is CPU-only — more (and faster) cores = more hashrate. The provisioning kit auto-detects the CPU (e.g. AMD EPYC, Ryzen X3D) and applies a matching profile. |
| **RAM** | RandomX in fast mode needs **~2.3 GB** for its dataset/cache, plus **~2 MB per mining thread**. **4 GB+** is comfortable for most rigs; budget more for high-core-count CPUs. |
| **HugePages** | The worker kit configures **1 GB and 2 MB** HugePages (plus MSR tweaks) for maximum hashrate. On Linux this needs a **reboot** to take effect. |
| **OS** | Ubuntu 22.04+, Debian 12, or macOS. |
| **Network** | Must reach the stack host on port **3333** over the LAN/network. Workers do **not** need Tor. |

The automated, performance-tuned setup lives in [`worker/`](../worker/) — see
[Adding Workers](workers.md) and the kit's own [README](../worker/Readme.md). You can also point any
hand-configured XMRig instance at the stack; the wallet and pool routing are handled centrally.

---

## Sizing examples

- **Small home setup (pruned):** a 6-core / 16 GB / 240 GB SSD mini-PC as the host, HugePages on,
  with one or two desktop/laptop workers pointed at it. Comfortable for getting started.
- **Full node + several workers:** an 8-core / 32 GB / 500 GB SSD host running an unpruned node,
  feeding a handful of dedicated mining rigs. Headroom for Tari growth and long uptimes.
- **Minimal / reuse-an-existing-node:** point the stack at a Monero node you already run (remote
  mode), and the host needs only enough for Tari, P2Pool, the proxy, dashboard, and Tor — far less
  disk and RAM.

---

## See also

- [Getting Started](getting-started.md) — prerequisites and first-run setup.
- [Configuration](configuration.md) — pruning, data directories, remote nodes, and `tari.mem_limit`.
- [Adding Workers](workers.md) — connecting rigs and the high-performance provisioning kit.
- [Architecture](architecture.md) — the services and how they fit together.
