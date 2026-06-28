# FAQ

Common questions about what Pithead is, what it does for you, and how it compares to wiring the
pieces together yourself. If you're new here, start with [Getting Started](getting-started.md);
the deeper "why" lives in [Architecture](architecture.md).

---

## Why Pithead vs. doing it yourself / vs. Gupax

### vs. doing it yourself

You can absolutely run a private Monero + P2Pool + Tari setup by hand — plenty of people do, and
the underlying projects ([monerod](https://www.getmonero.org/), [P2Pool](https://github.com/SChernykh/p2pool),
[XMRig](https://github.com/xmrig/xmrig)) are excellent. Doing it yourself means standing up and
maintaining each piece and the wiring between them:

- A Monero full node with restricted RPC, ZMQ, and Tor transaction broadcasting.
- P2Pool pointed at that node, with an onion address for inbound peers.
- Tari (Minotari) merge-mining alongside Monero.
- Each rig configured for the pool, plus a plan for what happens when the node goes down.
- Some way to actually *see* hashrate, sync progress, and your PPLNS window.

Pithead automates that whole stack in one command and adds the parts that are tedious to build
yourself:

- **Tor-first networking.** A built-in Tor daemon gives Monero, Tari, and P2Pool hidden-service
  (onion) addresses — no public port forwarding, and Monero/Tari traffic runs over Tor. A couple of
  outbound yield paths still use clearnet today; see [Privacy & network egress](privacy.md) for the
  full map and how to harden them.
- **One endpoint for every rig.** All workers point at a single `xmrig-proxy` endpoint on `:3333`.
  There's nothing per-rig to configure — no wallet address, no pool URL juggling. See
  [Connecting Miners](workers.md).
- **Algorithmic XvB switching.** A feedback controller splits your hashrate between P2Pool and
  XMRvsBeast (XvB) bonus rounds, donating only the minimum needed to hold your target tier and
  routing the rest to P2Pool. See [Architecture › Algorithmic switching](architecture.md#algorithmic-switching).
- **Node-down worker failover.** If monerod goes down, the stack stops `xmrig-proxy` so your
  miners fail over to their backup pools instead of mining into a void. See
  [Configuration › `dashboard.tari_required`](configuration.md#configuration-reference).
- **A dashboard that tells you things.** Live hashrate, sync progress, the PPLNS window,
  per-worker stats, and your P2Pool/XvB split — served over HTTPS on your LAN. See
  [The Dashboard](dashboard.md).
- **Hardened defaults.** Least-privilege containers, SHA256-verified and version-pinned binaries,
  localhost-only RPC, and split read-only / start-stop Docker socket proxies. See
  [Architecture › Security posture](architecture.md#security-posture).

If you enjoy hand-wiring infrastructure, the manual route is a great learning exercise. If you'd
rather get a private, multi-rig, merge-mining stack running before your coffee gets cold, that's
what Pithead is for.

### vs. Gupax

[Gupax](https://github.com/gupax-io/gupax) is a desktop GUI for mining Monero on P2Pool. It runs on
Windows, macOS, and Linux, has a `--daemon` headless mode, and manages more than it used to: P2Pool
and XMRig by default, plus optional tabs for a local Monero node, a proxy for external miners, and
XvB hashrate-splitting. If you mine on one machine and want a friendly app to drive it, Gupax is a
great choice.

Pithead is a different form factor — an always-on server stack rather than a desktop app you launch
on your mining PC. The two overlap more than they once did: both can run your own node, take
external miners through a proxy, and split hashrate to the XvB raffle. Where Pithead goes further:

- **Tor-first by default.** Monero, Tari, and P2Pool reach the network over onion addresses with no
  extra setup. Gupax ships no built-in Tor; a community Docker image adds an optional hidden service.
- **Tari merge-mining.** A second payout from the same hashes. Gupax doesn't merge-mine Tari.
- **Built to run unattended.** Nine version-pinned containers on a dedicated Linux box, node-down
  worker failover, and a LAN web dashboard — not an app you keep open on your desktop.

Pick Gupax to mine from one machine. Pick Pithead to run the whole operation yourself — node,
privacy, dashboard, and a fleet of workers — as a server you set up once.

---

## FAQ

### Is my home IP exposed?

**Mostly not — with the Tor defaults, the only time your IP leaves the box is the one-time install.**
A built-in Tor daemon gives Monero, Tari, and P2Pool hidden-service (onion) addresses, so **inbound**
connections need no port forwarding and don't reveal your IP. Monero and Tari route P2P and transaction
traffic over Tor, and their old clearnet DNS lookups are closed.

The two former clearnet yield paths are **Tor-by-default as of v1.1**, each with a yield-vs-privacy opt-out:

- **P2Pool's outbound sidechain peers** (#165) — Tor-routed by default. You may opt into clearnet
  (`p2pool.clearnet: true`) for ~10 % more yield on `mini`, at the cost of exposing your IP — see the
  [Tor-vs-clearnet benchmark](benchmarks/tor-vs-clearnet.md).
- **XvB donation mining** (#166) — only if XvB is enabled; the donation connection to `xmrvsbeast.com`
  is Tor-routed by default (opt out with `xvb.tor: false`). The XvB *stats* fetch is Tor-routed too.

What still touches clearnet (and so can reveal your IP):

- **Install / build** fetches code and container images from GitHub, getmonero.org, and the image
  registries once — inherent and integrity-pinned, but it reveals your IP at that moment.

**Bottom line:** on a normal home connection behind NAT, with the Tor defaults, the only time your IP
leaves the box is that one-time install.

See **[Privacy & network egress](privacy.md)** for every connection and how to harden each one.

### Do I need to port-forward?

No. Because connectivity runs through Tor hidden services, there's **no public IPv4 port
forwarding required**. (On your LAN, port `3333` does need to be reachable from each rig to the
stack host — that's local network traffic, not an internet-facing port. See
[Connecting Miners › Networking notes](workers.md#networking-notes).)

### Is the XvB donation mandatory? Will it cost me?

It's optional, and the engine is designed to minimize what you give up. XvB switching is on by
default but can be turned off (`xvb.enabled: false`). When it's on, the decision engine donates
only enough hashrate to **hold your target tier** and routes everything else to P2Pool — because
the XvB raffle picks winners at random, donating above a tier's threshold earns nothing extra. See
[Architecture › Algorithmic switching](architecture.md#algorithmic-switching) and the `xvb.*`
keys in [Configuration](configuration.md#configuration-reference).

### Do I have to sign up for the XvB raffle?

No — there's no manual signup. With `xvb.enabled: true`, the stack auto-registers your wallet in
the XMRvsBeast raffle once you have a share in the P2Pool PPLNS window (registration only takes
effect after that first share, so it can take a little while on a fresh stack). It then re-registers
periodically so a long-offline rig re-enters cleanly. The registration call carries your full wallet
address and is routed over Tor like the XvB stats fetch, so it never exposes your IP on clearnet. If
XvB is disabled, no registration happens.

The dashboard shows an **`XvB raffle ✓`** header badge once you're registered (and a warning badge
if your wallet is rejected or registration is failing — see
[Configuration › XvB raffle auto-registration](configuration.md#xvb-raffle-auto-registration-xvb_submit_url)).

### What is Tari? Do I have to mine it?

Tari (the [Minotari](https://www.tari.com/) node) is a chain that's **merge-mined alongside
Monero** through P2Pool — you earn on both at once for the same RandomX work. You do need a Tari
payout address, but you don't have to let Tari problems hold up Monero mining: set
`dashboard.tari_required: false` to keep mining Monero through a Tari outage or resync, with Tari
catching up in the background. See [Configuration › `dashboard.tari_required`](configuration.md#configuration-reference).

### Can I use my existing synced Monero node?

Yes. You can skip most — or all — of the initial blockchain sync two ways: point the bundled node
at your existing `.bitmonero` directory via `monero.data_dir`, or switch to **remote mode** and
connect to a node you run elsewhere (it must have ZMQ publishing enabled for P2Pool). The same
`data_dir` trick works for reusing a synced Tari node. See
[Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

### What hardware do I need?

Plan for **16 GB+ RAM**, a CPU with **AVX2** for RandomX, and an **SSD** (~300 GB pruned /
~500 GB full minimum — Tari's chain alone is ~135 GB, and both chains grow ~100+ GB/year, so a
**2–4 TB** drive is the set-and-forget choice). Full minimum-vs-recommended sizing for the stack host is in
[Hardware Requirements](hardware.md). (Miner hardware is sized separately in
[RigForge](https://github.com/p2pool-starter-stack/rigforge).)

### How do I connect my miners?

Point any [XMRig](https://github.com/xmrig/xmrig) (or other RandomX miner) at
`YOUR_STACK_IP:3333` — that single endpoint is the only pool setting your rigs need, and you do
**not** put a wallet address in the miner config. Point all your rigs at the same address; the
stack aggregates them. New to mining? [RigForge](https://github.com/p2pool-starter-stack/rigforge)
provisions a tuned worker and wires up the `3333` connection in one command. See
[Connecting Miners](workers.md).

---

## See also

- [Getting Started](getting-started.md) — fresh machine to a synced, mining stack.
- [Architecture](architecture.md) — the services, the privacy model, and the switching engine.
- [Configuration](configuration.md) — every `config.json` key, reusing a node, and remote nodes.
- [Connecting Miners](workers.md) — the single `3333` endpoint and RigForge.
