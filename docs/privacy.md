# Privacy & network egress

This doc lists every connection the stack makes off your box: where it goes, whether it's routed
over Tor, whether it's on by default, and how to lock it down.

The rule: nothing should leave the host to the internet except through Tor. Where that isn't
possible (or trades away yield), the connection must be off or Tor-routed by default, have a
documented toggle, and be listed here.

As of v1.1 the stack is Tor-by-default for all runtime egress. Monero and Tari (including the DNS
lookups they used to leak), P2Pool's outbound sidechain peers (#165), and XvB donation mining (#166)
are all Tor-routed by default, each with a documented opt-out for operators who trade privacy for
yield. What's left is inherent: the one-time install/build reveals your IP to the download host, and
remote-node mode (`monero.mode: remote`, off by default) talks to the node you choose. Both are
called out below.

One opt-in deliberately moves a node onto clearnet: an
[optional clearnet initial sync](#optional-clearnet-initial-sync-off-by-default) that lets Monero
and/or Tari download their chains over clearnet (much faster than over Tor) for the one-time initial
sync, then returns to Tor. It is off by default, loudly warned, and covered in full below.

---

## Enforced fail-closed, not just configured (#270)

Every per-app Tor setting below is backed by a host firewall, so "behind Tor" is a property the
stack enforces, not one it merely hopes each daemon is configured for. At `up`/`apply`, `pithead`
installs rules in Docker's `DOCKER-USER` chain: the mining bridge (monerod, p2pool, tari,
xmrig-proxy) may reach the LAN, the other containers, and the Tor SOCKS, but any direct dial to the
public internet is DROPPED. Only the `tor` container reaches the internet. So if a daemon is
misconfigured, buggy, or learns a clearnet peer address (as Tari's comms layer does), the connection
fails closed instead of leaking your IP.

- Needs root (the firewall rules), like the GRUB/HugePages steps; removed at `pithead down`.
- Opt out with `network.tor_egress_firewall: false` (then routing falls back to per-app config only).
- The host-networked dashboard and caddy aren't on the bridge; the dashboard's only external calls
  already go over the Tor SOCKS (`socks5h`, [#163](#runtime-egress)/#224).
- Verify it live with [`tests/integration/benchmarks/bench-verify-egress.sh`](../tests/integration/benchmarks/bench-verify-egress.sh); it confirms 0 app-container public connections.

---

## Inbound — no port forwarding

Your home IP is never advertised to an inbound peer, and you never touch your router's port-forward
settings. Every service that accepts inbound connections does so through a Tor hidden service (onion
address): monerod, Tari, and P2Pool each get one from the built-in Tor daemon. So:

- No public IPv4 port forwarding is required, and your IP is not advertised to inbound peers.
- The only LAN-facing port is the stratum endpoint `:3333` that your own rigs connect to. It is
  plain stratum, unauthenticated by default, and must never face the internet: `pithead
  setup`/`doctor` warn if your host has a public IP. Lock it down with `p2pool.stratum_bind`, a
  firewall, and/or an optional `p2pool.stratum_password` that requires each rig to authenticate.
  See [Connecting miners › Firewall](workers.md#firewall) and [Authentication](workers.md#authentication).
- The **dashboard** can get a fourth, optional onion (`dashboard.onion.enabled`, default off) so you
  can reach it remotely over Tor without a port-forward or public IP. It fronts the authenticated
  Caddy login, and pithead refuses to publish it without a 16-character password. This is **inbound**
  access over Tor and does not change the egress table below. See
  [Remote access over Tor](configuration.md#remote-access-over-tor-onion-service).

---

## Runtime egress

What the running stack sends to the internet, connection by connection.

| Connection | Destination | What it could reveal | Tor? | Default | How to control |
|---|---|---|---|---|---|
| **monerod** P2P + tx broadcast | Monero network | — | ✅ Tor (`proxy=` / `tx-proxy=`) | on | Tor by default; **P2P** can opt into clearnet for the initial sync only ([#183](#optional-clearnet-initial-sync-off-by-default)) — tx broadcast stays on Tor regardless |
| **monerod** DNS (checkpoints, blocklist, update check, priority-node hostnames) | DNS resolvers | "this IP runs Monero" | ✅ **closed** — `disable-dns-checkpoints`, `check-updates=disabled`, `enable-dns-blocklist=0`, hostname priority-nodes dropped (#161) | n/a | — |
| **monerod RPC to a remote node** (only if `monero.mode: remote`) | the node you configured | **your real home IP**, to that node's operator | ❌ clearnet | **off** — the bundled local node is the default and has no remote-RPC egress | use a node you run/trust, or one reachable as a `.onion` over Tor |
| **Tari** P2P | Tari network | — | ✅ Tor (`type = "tor"`) | on | Tor by default; can opt into clearnet (TCP) for the initial sync only ([#183](#optional-clearnet-initial-sync-off-by-default)) |
| **Tari** DNS seeds + Pulse (`seeds.tari.com`, `checkpoints.tari.com`) | DNS resolvers | "this IP runs Tari" | ✅ **closed** — `dns_seeds = []`, onion `peer_seeds`, resolver pointed at a dead address (#162) | n/a | clearnet sync ([#183](#optional-clearnet-initial-sync-off-by-default)) re-enables the `seeds.tari.com` DNS seed for the sync window |
| **P2Pool** inbound peers | reach you via onion | — | ✅ onion hidden service | on | — |
| **P2Pool** outbound sidechain peers | P2Pool sidechain peers, via Tor | — | ✅ **Tor** (`--socks5`, proxy-type `tor`) by default (#165) | on | opt out with `p2pool.clearnet: true` (exposes your IP for max yield) → [below](#p2pool-outbound-peers-165---tor-by-default) |
| Dashboard **XvB stats** fetch | `xmrvsbeast.com` | your Monero **wallet** (no longer your IP) | ✅ Tor (`socks5h`, #163) | on, only if XvB enabled | `XVB_ENABLED=false` stops it |
| Dashboard **XvB raffle registration** (#263) | `xmrvsbeast.com` | your Monero **wallet** (no longer your IP) | ✅ Tor (`socks5h`, same path as the stats fetch) | on, only if XvB enabled; fires once you have a PPLNS share | `XVB_ENABLED=false`, or set `XVB_SUBMIT_URL` to a disable sentinel (`off`), to stop it |
| **XvB donation mining** (only while donating) | `na.xmrvsbeast.com:4247` via Tor | — | ✅ **Tor** (per-pool `socks5`, DNS proxy-side) by default (#166) | on while donating | opt out with `xvb.tor: false` (exposes IP for max yield); `xvb.enabled: false` stops it entirely |
| Dashboard **update check** (#224) | `api.github.com` | nothing about you — GitHub sees a **Tor exit**, not your IP | ✅ Tor (`socks5h`) | **on** | `dashboard.check_for_updates: false` to opt out; cached, fails silently offline |
| **Caddy** TLS (dashboard HTTPS) | local only | — | n/a — `tls internal`, **no ACME / no external CA** | on | clean (no egress) |
| **Telegram** alerts (#121) | Telegram API | your IP | ❌ | **off** | opt-in only |
| Dashboard **Healthchecks** ping (#79) | `hc-ping.com` (or self-hosted) | nothing about you — the endpoint sees a **Tor exit**, not your IP | ✅ **always** Tor (`socks5h`) | opt-in (set `healthchecks.ping_url`; off until set) | the ping URL must be Tor-reachable (hosted, public, or an onion self-hosted instance) — there is no clearnet mode |

`socks5h` (used for the XvB stats fetch) routes DNS resolution through Tor too, so the hostname isn't
resolved on the clearnet either. The host-networked dashboard reaches the bridge's Tor SOCKS at
`172.28.0.25:9050`.

---

## Build / setup-time egress

These run once, at install or `pithead apply`, and inherently reveal your IP to the host you
download from. They cannot be Tor-routed transparently, but they are integrity-pinned so a network
attacker can't substitute what you receive.

| What | Destination | When |
|---|---|---|
| Source clone / release bundle | `github.com` | install / update (`git checkout vX.Y.Z` or downloading the release bundle) |
| Component binaries (monerod / p2pool / xmrig-proxy) | `downloads.getmonero.org`, `github.com` | **image build only** — verified against a published **SHA256** / checksum. A release install *pulls* prebuilt images instead, so it never runs these. |
| Container images | **`ghcr.io`** (the `pithead-*` images, #44), `quay.io` (Tari), Docker Hub (caddy, socket-proxy) | image **pull** on a release install / `pithead upgrade`, or build from source. All pinned by **`@sha256:` digest** (#135). |

Mitigation: run the install/build behind a VPN or with `torsocks`, or pre-pull the images and clone
on another machine and copy them over. The downloads are pinned (SHA256 + image digests), so the
risk is the one-time IP disclosure, not tampering.

---

## The Tor-by-default yield paths (and their opt-outs)

As of v1.1 both former clearnet yield paths, P2Pool outbound peers (#165) and XvB donation mining
(#166), route over Tor by default. Each has an opt-out for operators who'd trade the IP exposure for
maximum yield (Tor latency can raise stale/uncle shares and rejects). The two sections below document
the routing and how to opt out.

What Tor costs you (measured): a 5-day interleaved benchmark on `mini` (#256, full
[methodology + data](benchmarks/tor-vs-clearnet.md)) puts the price of routing P2Pool over Tor at
roughly 10 % of mining yield (−11 % reward share / yield-efficiency vs clearnet, just above the run's
noise floor). The cause is pure share-propagation latency: there were zero extra rejected shares and
no measurable Tor CPU overhead. The loss is shares arriving late enough to land as uncles. We keep
Tor the default anyway, because not leaking your home IP to the P2Pool network is the point and ~10 %
is a modest, opt-out-able price. The cost is largest on the smaller/faster sidechains (where your
share of the chain is biggest) and negligible on `main`.

### P2Pool outbound peers (#165) — ✅ Tor by default

P2Pool advertises its onion for inbound peers but, without a SOCKS proxy, would dial outbound
sidechain peers over clearnet, exposing your IP to the P2Pool network. As of v1.1 `pithead` injects
`--socks5 <tor-ip>:9050 --socks5-proxy-type tor` into P2Pool's `command:` by default, so outbound
dials go through Tor. No action needed.

Opt out for maximum yield (lower stale/uncle rate plus a larger peer set, at the cost of exposing
your IP, worse on `--mini`/`--nano`): set `p2pool.clearnet: true` in `config.json` and re-run
`pithead apply`. For the strictest posture, refuse clearnet peers entirely (onion-only): P2Pool also
has a `--no-clearnet-p2p` flag, not yet wired to its own config knob.

Trade-off (measured): Tor adds latency to share propagation, costing ~10 % of yield on `mini` (#256,
the loss is uncles/late shares, not rejects; see the box above), and `--no-clearnet-p2p` shrinks your
peer set to onion-only. The Tor-by-default flip was gated on that benchmark, which is why it's a v1.1
change (#165), not a v1.0 default. NOTE: the `p2pool.clearnet: true` opt-out only began working once #294
fixed a config bug that had silently pinned the egress firewall on; on a current build it takes
effect after `pithead apply`.

### XvB donation mining (#166) — ✅ Tor by default

When the optimizer donates to XMRvsBeast (XvB), it points the proxy at `na.xmrvsbeast.com:4247`. As
of v1.1 that connection routes through Tor by default: `algo_service` sets a per-pool `socks5` on the
XvB pool object it pushes to xmrig-proxy (the pool's DNS is resolved proxy-side, like the stats fetch
in #163), so donation mining no longer exposes your home IP. No action needed.

Opt out for maximum yield (stratum-over-Tor adds latency that can raise rejected shares, scaling with
hashrate): set `xvb.tor: false` and re-run `pithead apply`; the donation connection then dials
direct. To stop the egress entirely instead, disable XvB (`"xvb": { "enabled": false }`), which also
stops the (already Tor-routed, #163) stats fetch.

> NOTE: the xmrig-proxy dev-fee `--donate-level` is pinned to `0` by default (`proxy.donate_level`,
> rendered explicitly per #173) and does not ride the XvB pool's `socks5`, so if you set it above 0,
> that dev-fee traffic goes clearnet. Keep it at `0` for a fully Tor runtime.

---

## Optional clearnet initial sync (off by default)

Routing everything over Tor is correct for ongoing operation, but it makes the one-time initial
block download (IBD) slow: Tor circuits are bandwidth-capped, so a full Monero sync can drop to
near-zero blocks/sec and stall for long stretches, and Tari's chain is no faster. The standard
pattern for Tor-based nodes is to sync once over clearnet, then return to Tor. The stack supports this
as an explicit, default-off opt-in (#183).

Per-component flags in `config.json`, both `false` by default:

```jsonc
"monero": { "clearnet_initial_sync": false },
"tari":   { "clearnet_initial_sync": false }
```

Set the one(s) you want to `true` and run `./pithead apply`. Monero and Tari sync independently, so
you can enable either, both, or neither.

### What it changes

| | Tor-only (default) | Clearnet initial sync (opt-in) |
|---|---|---|
| **Monero** P2P | over Tor (`proxy=172.28.0.25:9050`) | **direct to clearnet seed nodes** (proxy line dropped), `out-peers` 48 → **32** + P2Pool v4.16's recommended **priority nodes** (`p2pmd.xmrvsbeast.com`, `nodes.hashvault.pro`) for fast, reliable sync |
| **Monero** tx broadcast | over Tor (`tx-proxy=`) | **still over Tor** — unchanged |
| **Tari** transport | Tor (`type = "tor"`) | **TCP** (`type = "tcp"`) |
| **Tari** seeds | onion `peer_seeds`, `dns_seeds = []` | **`dns_seeds = ["seeds.tari.com"]`** (onion seeds are unreachable without Tor), onion `public_addresses` dropped |

### The privacy trade-off (threat model)

What is exposed while a flag is on: your host's IP address, to the P2P network of the enabled chain,
i.e. "this IP is running a Monero/Tari node." A few DNS lookups also happen over clearnet during the
window: for Monero, the two P2Pool-recommended priority-node hostnames (`p2pmd.xmrvsbeast.com`,
`nodes.hashvault.pro`); for Tari, `seeds.tari.com` (to the configured resolvers `1.1.1.1` /
`8.8.8.8` / `9.9.9.9`) to discover clearnet peers. This is the same exposure as any ordinary clearnet
node, which is exactly what this window temporarily is.

What is *not* exposed:

- Your wallet addresses / payouts: there is no wallet activity during a sync.
- Monero transaction origin: `tx-proxy=tor` is left in place, so any tx broadcast still goes over
  Tor. (And there's no broadcasting during IBD anyway.)
- Nothing about *what* you mine, only that an IP runs a node.

That's the same exposure as running any ordinary (non-Tor) full node, scoped to the sync window. For
a privacy-first deployment it's still a real disclosure, which is why it is off by default and must
be explicitly opted into.

### It switches back to Tor automatically (#234)

The dashboard tracks each chain's sync state. The first time a clearnet node reports fully synced, the
dashboard writes a persistent "sync complete" marker and restarts the daemon, which comes back up
Tor-only. From then on the node stays on Tor across restarts, `apply`, and reboots (the marker, not
the flag, is the source of truth, so a restart can never silently re-expose a synced node). Monero and
Tari transition independently, each as soon as *it* finishes.

You can leave `clearnet_initial_sync: true` in `config.json`; it's effectively spent once the sync
completes. (To deliberately re-sync over clearnet later, e.g. after wiping a chain, toggle the flag
off and on again with `./pithead apply`, which re-arms it.)

### It is loud and always-visible

The active state is surfaced in four places, so it can't be enabled by accident or missed:

- `./pithead apply` prints a `⚠`-flagged, disruptive-change confirmation describing exactly what
  becomes exposed before it recreates the daemon.
- `./pithead status` and `./pithead up` print a prominent **"CLEARNET INITIAL SYNC ACTIVE — node IP
  exposed"** banner the whole time a node is actually on clearnet, and it clears by itself once the
  auto-transition completes.
- `./pithead doctor` raises a `⚠ WARN` while a node is exposed and flips back to a green
  `✓ OK "all node P2P is Tor-only"` once it's switched back.
- The dashboard shows the clearnet state live, and the daemon container logs a matching warning on
  every start until the transition completes.

If the automatic switch ever fails (e.g. the dashboard couldn't restart the container), it is
fail-safe: the marker is written before the restart, so any later restart still comes up Tor-only,
and the supervisor keeps retrying. A node is never silently stranded on clearnet. The banners and
`doctor` warning stay up until it's genuinely back on Tor.

---

## Local trust boundary & known limitations

Everything above is about network egress, what leaves the host. On the host itself, the stack assumes
the local machine and the private Docker bridge are trusted, which is the right model for a
single-purpose appliance. One consequence is worth recording explicitly:

- **The monerod RPC credential appears in the p2pool container's process arguments (#57).** p2pool
  accepts the monerod RPC login (`--rpc-login`) only as a command-line argument; it has no
  environment-variable or config-file equivalent, so the username/password are visible in the p2pool
  process's argv to any local process that can read it (`ps`, `/proc/<pid>/cmdline`). This is
  local-only (never remotely reachable) and the credential is an auto-generated random secret
  guarding a `restricted-rpc` (read-only, public-safe) endpoint that by default is bound to localhost
  plus the Docker bridge, not the LAN (set `monero.rpc_lan_access: true` to expose it, in which case
  the credential matters more). Moving it off argv isn't possible without removing RPC authentication
  (a worse trade-off, it's defense-in-depth on the internal path) or an upstream p2pool change, so
  it's accepted as a known limitation rather than fixed. Practical guidance: on a single-user
  appliance this is a non-issue; if you co-host the stack on a machine shared with other local users,
  treat the monerod RPC credential as visible to them and prefer a single-purpose host for stronger
  isolation.

## Maximum-privacy checklist

- [ ] Keep `:3333` off the public internet: firewall it to your LAN, set `p2pool.stratum_bind`,
  and/or require a `p2pool.stratum_password` (`pithead doctor` flags public-IP exposure).
- [ ] Leave `p2pool.clearnet` off (the default) to keep P2Pool outbound peers on Tor (#165).
- [ ] Set `xvb.enabled: false` if you don't want any XvB egress.
- [ ] Leave `monero.clearnet_initial_sync` / `tari.clearnet_initial_sync` off (the default) to keep all node P2P on Tor. If you do use a clearnet sync, the dashboard switches each node back to Tor automatically once it's synced; `pithead doctor` flags it while exposed and clears when done.
- [ ] Run the initial install/build behind a VPN or `torsocks`.
- [ ] Leave Telegram (#121) off unless you accept its clearnet IP exposure. Healthchecks (#79) always pings over Tor, so it's safe to enable — just make sure its ping URL is Tor-reachable (hosted `hc-ping.com`, or an onion/public self-hosted instance).
- [ ] Run `pithead doctor`; it surfaces the public-IP exposure check among its diagnostics.

---

See also: [Architecture › Privacy by design](architecture.md#privacy-by-design) ·
[Connecting miners › Firewall](workers.md#firewall) · the privacy-egress epic (#160).
