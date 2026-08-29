# Hardware Requirements

Hardware sizing for the stack host. For a machine running [the appliance image](appliance.md),
the appliance guide's "What you need" section is the short version to follow. The stack runs
on two kinds of machine with different needs:

1. The stack host: the one machine that runs `./pithead` and the Docker stack (Monero node, P2Pool,
   Tari, the XMRig proxy, the dashboard, Tor). It does not mine — it runs the nodes and coordinates;
   the hashing happens elsewhere.
2. Worker rigs: one or more separate machines running [XMRig](https://github.com/xmrig/xmrig). These
   do the RandomX hashing and point at the stack host's port `3333`. A worker can be the same machine
   as the host, but keeping them separate is what scales hashrate.

Size the host for nodes, storage, and uptime; size the workers for CPU mining performance.

> This page covers the stack host. Miner (worker-rig) hardware lives with the miner kit, see
> [RigForge](https://github.com/p2pool-starter-stack/rigforge#-hardware-requirements).

---

## The stack host

### At a glance

| Resource | Minimum | Recommended |
|---|---|---|
| **CPU** | 4 cores, 64-bit x86 (AVX2 advised) | 6–8+ cores with **AVX2** |
| **RAM** | **16 GB** | **32 GB** |
| **Disk — pruned node** | ~330 GB SSD | 1 TB+ SSD |
| **Disk — full node** | ~530 GB SSD | 2 TB+ SSD |
| **Network** | Always-on broadband | Unmetered broadband |
| **OS** | Ubuntu Server **24.04 LTS** | Ubuntu Server 24.04 LTS |

> These figures assume the default configuration: both nodes local, Monero pruned, HugePages enabled.
> Pointing either node at a machine you already run lowers them a lot — Tari is the bigger cut. See
> [Running a node elsewhere](#running-a-node-elsewhere).

### Where these numbers come from

The host runs several services in one box, so its requirement is the sum of what each service needs
plus headroom for the OS. Per-component breakdown, from each project's own guidance:

| Service | RAM it wants | Container ceiling | Disk | Notes |
|---|---|---|---|---|
| **[Monero node](https://docs.getmonero.org/running-node/)** (`monerod`) | **4 GB** minimum; more RAM = bigger DB cache and faster sync | 6 GB (`monero.mem_limit`) | **~100 GB** pruned · **~270 GB** full — and growing | SSD strongly recommended. Not run at all with `monero.mode: remote`. |
| **[P2Pool](https://github.com/SChernykh/p2pool)** | **~2.3 GB** for the RandomX dataset it uses to verify blocks fast | 1 GB | tiny (sidechain state) | Needs a 64-bit CPU with **AVX2** and a synced `monerod`. The dataset lives in the shared HugePages reservation, not in the container, so don't count it twice. |
| **[Tari base node](https://www.tari.com/integration-guide)** (`minotari_node`) | **4 GB** minimum, **8 GB+** recommended; grows over time | auto (`tari.mem_limit`) | **~150 GB** SSD — and growing | The largest single disk consumer once Monero is pruned (~150 GB vs a pruned Monero node's ~100 GB), so budget for it whenever it runs here. The stack caps its memory so growth can't take the host down. Not run at all with `tari.mode: remote`. |
| **XMRig proxy · Tor · dashboard** | a few hundred MB combined | 512 MB each | a few GB (Docker images) | These coordinate and serve the UI. They don't mine, so no special CPU. |
| **Caddy · Docker socket proxies** | small | 128 MB each | — | Serve the dashboard and mediate its Docker access. |
| **Payout confirmation** (`wallet-rpc`, `tari-wallet`) | only when enabled | 2 GB · 512 MB | small (view-only wallet state) | Started only when `monero.view_key` / `tari.view_key` are set — and both are refused in that node's `remote` mode, since the scan needs a local node. |

Add the three heavy services' RAM (Monero 4 GB, P2Pool ~2.3 GB, Tari 4 GB) plus a couple of GB for
the OS, page cache, and supporting containers, and you reach the 16 GB minimum above.

Disk is dominated by the two chains. A pruned Monero node (~100 GB) plus the Tari node (~150 GB) and
a few GB for P2Pool and the OS put a pruned host near ~260 GB; a *full* Monero node (~270 GB) instead
of pruned pushes that toward ~425 GB. Pruning Monero doesn't shrink Tari, so budget for Tari
whenever it runs here. (A *freshly synced* pruned node is ~100 GB, but pruning an existing full
chain doesn't
reclaim space in place — run `monero-blockchain-prune` to write a new pruned DB; until then it sits
at full size. Stop monerod first: the tool moves the new DB into place itself, renaming the old
chain aside, and it will do that under a running daemon.)

Both chains keep growing, ~100+ GB/year combined (Tari, a young chain, grows fastest; Monero adds
tens of GB/year). That's why the table lists a ~330 GB (pruned) / ~530 GB (full) minimum but
recommends more: for a set-and-forget host, put it on a 2–4 TB SSD. Disk figures are measured on live
deployments (August 2026: a full node at 267 GB Monero + 149 GB Tari; a pruned node measured
~102 GB Monero). `./pithead setup` budgets above these measurements on purpose — 120 GB pruned /
320 GB full for Monero, 200 GB for Tari — so a host sized to the minimums has growth room from day
one. The
per-service **RAM** figures are provisioning minimums — steady-state resident memory is much lower
(`monerod` and P2Pool a few hundred MB each, since their large data lives in the shared HugePages and
in reclaimable page cache; Tari 2–4 GB and climbing), so size for the minimums, not today's usage.

The container ceilings are runaway protection, not reservations: nothing is set aside up front, and
each container runs with swap disabled so a leak is OOM-killed and restarted on its own instead of
dragging the host down with it.

> NOTE: Monero and P2Pool both want large memory pages for RandomX, so they share one ~6 GB
> HugePages reservation rather than each adding their own. See [Memory](#memory) for what that means
> for the 16 GB floor.

### CPU

The host CPU runs the nodes, P2Pool's block verification, the proxy, and the dashboard. It is not the
miner, so it need not be a high-end mining chip. Two things matter:

- AVX2 is strongly recommended. P2Pool verifies blocks with RandomX, which runs far better with AVX2;
  setup warns *"AVX2 not detected. Mining performance will be poor."* if it's missing. (P2Pool also
  requires a 64-bit CPU; ARMv7 and older aren't supported.)
- More cores speed up the first sync. Monero parallelizes block verification during the initial sync:
  `monero.prep_blocks_threads` defaults to `auto` = host cores − 2, clamped to 4–8. So 6–10 cores use
  the full thread budget while leaving headroom for the rest of the stack. Steady-state CPU load
  after the initial sync is low.

### Memory

16 GB is the practical floor with the default configuration. The budget:

- ~6 GB reserved for HugePages. RandomX wants large pages, so setup configures `vm.nr_hugepages=3072`
  (3072 × 2 MB = 6 GB), shared by `monerod` and P2Pool. This RAM is carved out of the kernel up front
  and is invisible to container memory stats; it's gone whether or not it's fully used.
- Tari (4 GB+, growing) gets an auto-sized ceiling (`tari.mem_limit: auto`) so a runaway restarts
  cleanly instead of taking the host down. On a 16 GB host that ceiling is ~7.5 GB; on 32 GB, ~19 GB.
- The OS, page cache, and the lighter containers take the rest.

On a 16 GB machine this fits but is tight, which is why Tari is capped. Use 32 GB if you run a full
(unpruned) node, drive many workers, or want long uptimes without Tari's growth pressing on the cap.
With `tari.mode: remote` there is no Tari container to cap, so that term leaves the budget entirely —
see [Running a node elsewhere](#running-a-node-elsewhere).

> Running with only 8 GB? It boots only if you disable HugePages (`./pithead setup --skip-optimize`),
> which frees the 6 GB reservation, but leaves little headroom and hurts RandomX verification
> performance. Watch what else that changes: with no reservation to subtract, Tari's auto ceiling
> becomes ~75% of total RAM — 6 GB of an 8 GB host. On a host that small, set `tari.mem_limit` by
> hand (e.g. `"3g"`), or run `tari.mode: remote` and leave the memory to `monerod` and P2Pool.
> Prefer 16 GB+.
>
> The [appliance](appliance.md) makes this call itself: 16 GB is its supported floor, and on a
> machine below it the boot shrinks the reservation to 5 GB — the smallest pool that still holds
> both RandomX datasets — announces it on the console, and `doctor` reports it as a warning until
> the machine has 16 GB. Far below the floor (under ~7 GB) the reservation is released entirely
> and the stack will not run reliably.

### Disk

The two blockchains dominate, and an SSD is strongly recommended: initial-sync verification and the
node databases do heavy random I/O that punishes spinning disks. What to provision:

| | Pruned (default) | Full (`monero.prune: false`) |
|---|---|---|
| Monero chain | ~100 GB | ~270 GB |
| Tari chain | ~150 GB | ~150 GB |
| P2Pool + dashboard + Docker images | a few GB | a few GB |
| **Plan for** | **~330 GB+ SSD** | **~530 GB+ SSD** |

Both chains keep growing, ~100+ GB/year combined (Tari, a young chain, grows fastest), so leave
headroom: the *recommended* 1 TB+ (pruned) / 2 TB+ (full) sizes exist for that, and a 2–4 TB SSD is
the set-and-forget choice. Tari's chain (~150 GB) is the largest single item and is the same whether
or not you prune Monero, so pruning only saves disk on the Monero side. Pruning (the default) keeps a
fully validating Monero node at a fraction of the size.

A node running elsewhere is left out of this budget entirely — see
[Running a node elsewhere](#running-a-node-elsewhere) for the totals in each combination.

> `setup` pre-flights these. Before a sync, `./pithead setup` warns if the host falls short; it never
> blocks. Disk is checked per filesystem rather than as one total: the data dirs are grouped by the
> volume they sit on, and each volume is compared against the combined need of the components sharing
> it — so splitting chains across disks is measured as you actually laid it out. The budget follows
> the modes you configured, and a node set to `remote` is left out of it entirely. The RAM check does
> not: it warns below 16 GB whatever the modes, so a deliberately small remote-node host sees that
> warning and can ignore it.
>
> `./pithead doctor` re-runs the same disk check on demand, and adds a live memory check rather than
> repeating setup's: it warns when the HugePages reservation is missing, and when free memory is
> under 2 GB right now. Setup asks whether the host has enough RAM at all; doctor asks whether enough
> is free today.

You can put any service's data on a dedicated disk by pointing its `*.data_dir` at an absolute path,
e.g. to keep the Monero blockchain on a separate SSD. See
[Configuration › Data directories](configuration.md#data-directories).

### Network

- Always-on broadband. With both nodes local, all upstream traffic (Monero, Tari, P2Pool) goes over
  Tor, with no public port forwarding required; the stack uses hidden services for inbound peers. A
  node you point at over the network is the exception — that leg is a direct connection, so keep it
  on the LAN or behind WireGuard ([Privacy › Runtime egress](privacy.md#runtime-egress)).
- Initial sync is the heavy part. The first run downloads and verifies both chains over Tor (slower
  than clearnet): ~100 GB pruned / ~270 GB full for Monero, plus ~150 GB for Tari. This takes a few
  hours to a day or more. A node in `remote` mode syncs nothing here, so its share drops out. Avoid
  it by
  [reusing an existing synced node](configuration.md#reusing-an-existing-node), or speed it up with
  an [optional clearnet initial sync](privacy.md#optional-clearnet-initial-sync-off-by-default)
  (default off, privacy-relevant) that downloads over clearnet and then returns to Tor.
- Steady state is light. Once synced, bandwidth is modest.
- LAN reachability for workers. Each worker rig connects to the host on port 3333 over the local
  network (plain stratum, not Tor). If the host has a firewall, allow inbound `3333` from the LAN.

### Operating system & dependencies

- Ubuntu Server 24.04 LTS is the officially supported platform. macOS and other Linux distros may
  work but aren't officially supported.
- The kernel/HugePages tuning is Linux-only. On Linux, making HugePages persistent edits GRUB and
  needs a reboot (you're prompted first, and can skip with `--skip-optimize`).
- Required software: Docker Engine, Docker Compose v2, `jq`, and `openssl`. On Ubuntu, `./pithead
  setup` offers to install anything missing, or do it yourself:

  ```bash
  sudo apt update && sudo apt install -y jq docker.io docker-compose-v2 openssl
  ```

---

## Lighter-footprint options

The defaults assume a self-hosted, pruned, HugePages-tuned local node. You can trade some away:

| Want to… | Do this | Saves |
|---|---|---|
| Skip the Tari node entirely | `tari.mode: remote`; the bundled `minotari_node` isn't started | ~200 GB disk budget + Tari's RAM ceiling — the biggest single cut |
| Skip the Monero node entirely | `monero.mode: remote`; the bundled `monerod` isn't started | ~120 GB (pruned) / ~320 GB (full) disk budget + Monero's 4 GB RAM |
| Skip the initial sync wait | [Reuse an existing synced chain](configuration.md#reusing-an-existing-node) | Hours–days + sync bandwidth |
| Free the 6 GB HugePages reservation | `./pithead setup --skip-optimize` | ~6 GB RAM (at the cost of RandomX performance). The reservation is unconditional otherwise — remote-node modes don't shrink it, since P2Pool still verifies blocks with RandomX |
| Free RAM for other apps | Lower `tari.mem_limit` (e.g. `"4g"`) | Caps Tari's ceiling lower |
| Keep mining while Tari resyncs | `dashboard.tari_required: false` | A Tari resync stops blocking Monero mining (Tari outages never block it, either setting) |

---

## Running a node elsewhere

Either chain can live on another machine. `monero.mode: remote` and `tari.mode: remote` each drop
that node's container from the stack: it is never started, its data directory is left out of the
disk budget, and its chain is never synced here. Everything else — P2Pool, the XMRig proxy, the
dashboard, and Tor — still runs locally in every combination.

Tari is the larger saving. Its chain is the biggest single item in the budget (~200 GB, against
~120 GB for a pruned Monero node), and it is also the fastest-growing, so moving it off a small host
buys the most room. Free disk `setup` and `doctor` ask for, by combination:

| Monero | Tari | Disk budget on this host |
|---|---|---|
| local, pruned (default) | local (default) | ~330 GB |
| local, full | local | ~530 GB |
| local, pruned | **remote** | **~130 GB** |
| local, full | **remote** | ~330 GB |
| **remote** | local | ~210 GB |
| **remote** | **remote** | under 10 GB (P2Pool, dashboard, Tor, Docker images) |

What a remote Tari node changes beyond disk:

- **RAM.** No `minotari_node` container, so nothing is capped by `tari.mem_limit` and Tari's 4 GB+
  drops out of the memory sum behind the 16 GB floor. The 6 GB HugePages reservation, `monerod`, and
  P2Pool are unchanged, so HugePages remains the largest single claim on the host.
- **Initial sync.** No Tari chain to download or verify here — roughly 150 GB less over Tor on the
  first run, and the sync wait shrinks to Monero's.
- **Network.** P2Pool's merge-mining gRPC to that node is a direct connection, not a Tor circuit,
  and it is plaintext and unauthenticated. Keep the node on your LAN or behind WireGuard. See
  [Privacy › Runtime egress](privacy.md#runtime-egress).
- **Tor.** No inbound onion is published for a node that isn't here, so a remote-mode host serves
  one fewer hidden service.

Either way it must be a node you control, and the requirements differ per chain. See
[Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node) and
[Remote Tari node](configuration.md#remote-tari-node) — including how to make *this* stack the
serving side for another one.

> NOTE: on-chain payout confirmation scans against local nodes only, so `monero.view_key` is refused
> with `monero.mode: remote` and `tari.view_key` with `tari.mode: remote`. Setup fails with that
> reason rather than scanning through someone else's daemon.

---

## Sizing examples

- Small home setup (pruned): a 6-core / 16 GB / 1 TB SSD mini-PC as the host, HugePages on, with
  one or two workers pointed at it.
- Full node + several workers: an 8-core / 32 GB / 600 GB SSD host running an unpruned node, feeding
  a handful of dedicated mining rigs. Headroom for Tari growth and long uptimes.
- Small disk, Tari elsewhere: a 240 GB mini-PC can host a pruned Monero node with `tari.mode: remote`
  pointed at a Tari node on the LAN — ~130 GB of budget instead of ~330 GB, and no Tari chain to sync.
- Minimal / reuse-an-existing-node: point the stack at nodes you already run (`monero.mode` and
  `tari.mode: remote`); the host then needs only enough for P2Pool, the proxy, dashboard, and Tor —
  under 10 GB of chain-free disk, and no node RAM at all.

> Sizing the miners that connect to this host is separate; their CPU determines hashrate. See
> RigForge's [Hardware Requirements](https://github.com/p2pool-starter-stack/rigforge#-hardware-requirements).

---

## See also

- [Getting Started](getting-started.md) — prerequisites and first-run setup.
- [Configuration](configuration.md) — pruning, data directories, remote nodes, and `tari.mem_limit`.
- [Connecting Miners](workers.md) — connecting rigs to this host.
- [RigForge](https://github.com/p2pool-starter-stack/rigforge) — provision a tuned miner; miner hardware specs.
- [Architecture](architecture.md) — the services and how they fit together.
