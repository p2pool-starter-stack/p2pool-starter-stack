# FAQ

Answers to common questions about Pithead, checked against the code. Start with
[Getting Started](getting-started.md); the design is in [Architecture](architecture.md).

---

## Why Pithead vs. doing it yourself / vs. Gupax

### vs. doing it yourself

You can run a private Monero + P2Pool + Tari setup by hand on top of
[monerod](https://www.getmonero.org/), [P2Pool](https://github.com/SChernykh/p2pool), and
[XMRig](https://github.com/xmrig/xmrig). Doing it yourself means standing up and maintaining each
piece and the wiring between them:

- A Monero full node with restricted RPC, ZMQ, and Tor transaction broadcasting.
- P2Pool pointed at that node, with an onion address for inbound peers.
- Tari (Minotari) merge-mining alongside Monero.
- Each rig configured for the pool, plus a plan for what happens when the node goes down.
- Some way to see hashrate, sync progress, and your PPLNS window.

Pithead runs that stack from one command and adds the parts that are tedious to build yourself:

- Tor-first networking. A built-in Tor daemon gives Monero, Tari, and P2Pool hidden-service
  (onion) addresses, so there is no public port forwarding and Monero/Tari traffic runs over Tor.
  A couple of outbound yield paths still use clearnet; see
  [Privacy & network egress](privacy.md) for the full map and how to harden them.
- One endpoint for every rig. All workers point at a single `xmrig-proxy` endpoint on `:3333`.
  Nothing is configured per rig: no wallet address, no pool URL. See
  [Connecting Miners](workers.md).
- Algorithmic XvB switching. A feedback controller splits hashrate between P2Pool and XMRvsBeast
  (XvB) bonus rounds, donating the minimum needed to hold your target tier and routing the rest to
  P2Pool. See [Architecture › Algorithmic switching](architecture.md#algorithmic-switching).
- Node-down worker failover. If monerod goes down, the stack stops `xmrig-proxy` so miners fail
  over to their backup pools. See
  [Configuration › `dashboard.tari_required`](configuration.md#configuration-reference).
- Dashboard. Live hashrate, sync progress, the PPLNS window, per-worker stats, and the P2Pool/XvB
  split, served over HTTPS on your LAN. See [The Dashboard](dashboard.md).
- Hardened defaults. Least-privilege containers, SHA256-verified and version-pinned binaries,
  localhost-only RPC, and split read-only / start-stop Docker socket proxies. See
  [Architecture › Security posture](architecture.md#security-posture).

### vs. Gupax

[Gupax](https://github.com/gupax-io/gupax) is a desktop GUI for mining Monero on P2Pool. It runs on
Windows, macOS, and Linux, has a `--daemon` headless mode, and manages P2Pool and XMRig by default,
plus optional tabs for a local Monero node, a proxy for external miners, and XvB hashrate-splitting.

Pithead is an always-on server stack rather than a desktop app. The two overlap — both can run your
own node, take external miners through a proxy, and split hashrate to the XvB raffle. Where they
differ:

- **Tor-first by default.** Monero, Tari, and P2Pool reach the network over onion addresses with no
  extra setup. Gupax ships no built-in Tor; a community Docker image adds an optional hidden service.
- **Tari merge-mining.** A second payout from the same hashes. Gupax does not merge-mine Tari.
- **Runs unattended.** Nine version-pinned containers on a dedicated Linux box, node-down worker
  failover, and a LAN web dashboard.

Gupax mines from one machine. Pithead runs the node, privacy, dashboard, and a fleet of workers as
a server you set up once.

---

## FAQ

### Is my home IP exposed?

With the Tor defaults, the only time your IP leaves the box is the one-time install. A built-in
Tor daemon gives Monero, Tari, and P2Pool hidden-service (onion) addresses, so inbound connections
need no port forwarding and do not reveal your IP. Monero and Tari route P2P and transaction
traffic over Tor, and their old clearnet DNS lookups are closed.

The two former clearnet yield paths are Tor-by-default as of v1.1, each with a yield-vs-privacy opt-out:

- P2Pool's outbound sidechain peers (#165) are Tor-routed by default. You may opt into clearnet
  (`p2pool.clearnet: true`) for ~10 % more yield on `mini`, at the cost of exposing your IP; see the
  [Tor-vs-clearnet benchmark](benchmarks/tor-vs-clearnet.md).
- XvB donation mining (#166), only if XvB is enabled: the donation connection to `xmrvsbeast.com`
  is Tor-routed by default (opt out with `xvb.tor: false`). The XvB *stats* fetch is Tor-routed too.

What still touches clearnet, and so can reveal your IP:

- Install / build fetches code and container images from GitHub, getmonero.org, and the image
  registries once. This is inherent and integrity-pinned, but it reveals your IP at that moment.

Bottom line: on a normal home connection behind NAT, with the Tor defaults, the only time your IP
leaves the box is that one-time install.

See **[Privacy & network egress](privacy.md)** for every connection and how to harden each one.

### Do I need to port-forward?

No. Because connectivity runs through Tor hidden services, no public IPv4 port forwarding is
required. (On your LAN, port `3333` does need to be reachable from each rig to the stack host.
That's local network traffic, not an internet-facing port. See
[Connecting Miners › Networking notes](workers.md#networking-notes).)

### Is the XvB donation mandatory? Will it cost me?

It's optional. XvB switching is on by default and turns off with `xvb.enabled: false`. When on,
the decision engine donates only enough hashrate to hold your target tier and routes everything
else to P2Pool. Because the XvB raffle picks winners at random, donating above a tier's threshold
earns nothing extra. See
[Architecture › Algorithmic switching](architecture.md#algorithmic-switching) and the `xvb.*`
keys in [Configuration](configuration.md#configuration-reference).

### Do I have to sign up for the XvB raffle?

No, there's no manual signup. With `xvb.enabled: true`, the stack auto-registers your wallet in
the XMRvsBeast raffle once you have a share in the P2Pool PPLNS window (registration only takes
effect after that first share, so it can take a little while on a fresh stack). It then re-registers
periodically so a long-offline rig re-enters cleanly. The registration call carries your full wallet
address and is routed over Tor like the XvB stats fetch, so it never exposes your IP on clearnet. If
XvB is disabled, no registration happens.

The dashboard shows an `XvB raffle ✓` header badge once you're registered (and a warning badge
if your wallet is rejected or registration is failing; see
[Configuration › XvB raffle auto-registration](configuration.md#xvb-raffle-auto-registration-xvb_submit_url)).

### What is Tari? Do I have to mine it?

Tari (the [Minotari](https://www.tari.com/) node) is a chain that's merge-mined alongside Monero
through P2Pool; you earn on both at once for the same RandomX work. You do need a Tari payout
address, but a Tari outage never holds up Monero mining — p2pool keeps mining through it, with
Tari catching up in the background, no matter how `dashboard.tari_required` is set. That flag only
covers Tari's *sync* holds: set it to `false` to also skip waiting for Tari's initial sync and to
keep the normal dashboard (instead of the full-screen Sync view) during a Tari resync. See
[Configuration › `dashboard.tari_required`](configuration.md#configuration-reference).

### Can I use my existing synced Monero node?

Yes. You can skip most or all of the initial blockchain sync two ways: point the bundled node at
your existing `.bitmonero` directory via `monero.data_dir`, or switch to remote mode and connect
to a node you run elsewhere (it must have ZMQ publishing enabled for P2Pool). The same `data_dir`
trick works for reusing a synced Tari node. See
[Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

### What hardware do I need?

Plan for 16 GB+ RAM, a CPU with AVX2 for RandomX, and an SSD (~330 GB pruned / ~530 GB full
minimum; Tari's chain alone is ~150 GB, and both chains grow ~100+ GB/year, so a 2–4 TB drive is
the set-and-forget choice). Full minimum-vs-recommended sizing for the stack host is in
[Hardware Requirements](hardware.md). (Miner hardware is sized separately in
[RigForge](https://github.com/p2pool-starter-stack/rigforge).)

### How do I know a payout actually arrived?

Give the stack a private view key and it confirms payouts on-chain. Set `monero.view_key` (and for
Tari, `tari.view_key` + `tari.spend_public_key`) and a view-only wallet scans your local node for
incoming payouts; the dashboard's earnings card then shows confirmed totals beside the estimate,
and a `payout_confirmed` alert fires once per payout. A view key can see incoming amounts but never
spend. See [Dashboard › Payout confirmation](dashboard.md#payout-confirmation) — including
[how to export the keys](dashboard.md#exporting-your-keys) from your wallets.

### How do I connect my miners?

Point any [XMRig](https://github.com/xmrig/xmrig) (or other RandomX miner) at
`YOUR_STACK_IP:3333`. That single endpoint is the only pool setting your rigs need, and you do
not put a wallet address in the miner config. Point all your rigs at the same address; the stack
aggregates them. New to mining? [RigForge](https://github.com/p2pool-starter-stack/rigforge)
provisions a tuned worker and wires up the `3333` connection in one command. See
[Connecting Miners](workers.md).

---

## See also

- [Getting Started](getting-started.md) — fresh machine to a synced, mining stack.
- [Architecture](architecture.md) — the services, the privacy model, and the switching engine.
- [Configuration](configuration.md) — every `config.json` key, reusing a node, and remote nodes.
- [Connecting Miners](workers.md) — the single `3333` endpoint and RigForge.
