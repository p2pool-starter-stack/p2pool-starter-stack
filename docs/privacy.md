# Privacy & network egress

This is the single source of truth for **every connection the stack makes off your box** — where it
goes, whether it's routed over Tor, whether it's on by default, and how to lock it down.

**North-star:** nothing should leave the host to the internet except through Tor. Where that isn't
possible (or trades away yield), the connection must be **off or Tor-routed by default**, have a
**documented toggle**, and be **listed here**.

Honesty first: the stack is **Tor-first**. Monero and Tari — including the DNS lookups they used to
leak — are fully Tor-routed, and as of v1.1 **P2Pool's outbound sidechain peers route over Tor by
default** too (#165, with a `p2pool.clearnet` opt-out). The remaining clearnet yield path is **XvB
donation mining** (Tor-by-default tracked in #166), plus **install/build reveals your IP once**.
Those are called out below with how to mitigate each.

There is also one **opt-in** that deliberately moves a node onto clearnet: an
[optional clearnet initial sync](#optional-clearnet-initial-sync-off-by-default) that lets Monero
and/or Tari download their chains over clearnet (much faster than over Tor) for the **one-time
initial sync**, then return to Tor. It is **off by default**, loudly warned, and covered in full
below.

---

## Inbound — no port forwarding

**Your home IP is never advertised to a single inbound peer, and you never touch your router's
port-forward settings.** Every service that accepts inbound connections does so through a **Tor
hidden service (onion address)**: monerod, Tari, and P2Pool each get one from the built-in Tor
daemon. So:

- **No public IPv4 port forwarding is required**, and your IP is not advertised to inbound peers.
- The **only** LAN-facing port is the stratum endpoint **`:3333`** that your own rigs connect to. It
  is plain stratum — **unauthenticated by default** — and must never face the internet:
  `pithead setup`/`doctor` warn if your host has a public IP. Lock it down with `p2pool.stratum_bind`,
  a firewall, and/or an optional `p2pool.stratum_password` that requires each rig to authenticate.
  See [Connecting miners › Firewall](workers.md#firewall) and [Authentication](workers.md#authentication).

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
| **P2Pool** outbound sidechain peers | P2Pool sidechain peers, via Tor | — | ✅ **Tor** (`--socks5`, proxy-type `tor`) by default (#165) | on | opt out with `p2pool.clearnet: true` (exposes your IP for max yield) → [below](#hardening-the-clearnet-paths) |
| Dashboard **XvB stats** fetch | `xmrvsbeast.com` | your Monero **wallet** (no longer your IP) | ✅ Tor (`socks5h`, #163) | on, only if XvB enabled | `XVB_ENABLED=false` stops it |
| **XvB donation mining** (only while donating) | `na.xmrvsbeast.com:4247` | **your real home IP** | ❌ **clearnet** | on while donating | ⏳ Tor-by-default in v1.1 (#166). Disable XvB to stop it |
| Dashboard **update check** (#224) | `api.github.com` | nothing about you — GitHub sees a **Tor exit**, not your IP | ✅ Tor (`socks5h`) | **on** | `dashboard.check_for_updates: false` to opt out; cached, fails silently offline |
| **Caddy** TLS (dashboard HTTPS) | local only | — | n/a — `tls internal`, **no ACME / no external CA** | on | clean (no egress) |
| **Telegram** alerts (#121) | Telegram API | your IP | ❌ | **off** | opt-in only |
| **Healthchecks** pings (#79) | external | your IP | ❌ | **off** | opt-in only |

`socks5h` (used for the XvB stats fetch) routes **DNS resolution through Tor too**, so the hostname
isn't resolved on the clearnet either. The host-networked dashboard reaches the bridge's Tor SOCKS
at `172.28.0.25:9050`.

---

## Build / setup-time egress

These run **once**, at install or `pithead apply`, and inherently reveal your IP to the host you
download from. They cannot be Tor-routed transparently, but they are **integrity-pinned** so a
network attacker can't substitute what you receive.

| What | Destination | When |
|---|---|---|
| Source clone / release bundle | `github.com` | install / update (`git checkout vX.Y.Z` or downloading the release bundle) |
| Component binaries (monerod / p2pool / xmrig-proxy) | `downloads.getmonero.org`, `github.com` | **image build only** — verified against a published **SHA256** / checksum. A release install *pulls* prebuilt images instead, so it never runs these. |
| Container images | **`ghcr.io`** (the `pithead-*` images, #44), `quay.io` (Tari), Docker Hub (caddy, socket-proxy) | image **pull** on a release install / `pithead upgrade`, or build from source. All pinned by **`@sha256:` digest** (#135). |

**Mitigation:** run the install/build behind a **VPN** or with `torsocks`, or pre-pull the images and
clone on another machine and copy them over. The downloads are pinned (SHA256 + image digests), so
the risk is the **one-time IP disclosure**, not tampering.

---

## Hardening the clearnet paths

The **XvB donation** path still uses clearnet by default (Tor-by-default tracked in #166) — close it
today by disabling XvB, or see below. **P2Pool's outbound peers now route over Tor by default** as of
v1.1 (#165), documented here for completeness.

### P2Pool outbound peers (#165) — ✅ Tor by default

P2Pool advertises its onion for *inbound* peers but, without a SOCKS proxy, would dial *outbound*
sidechain peers over clearnet, exposing your IP to the P2Pool network. As of v1.1 `pithead` injects
`--socks5 <tor-ip>:9050 --socks5-proxy-type tor` into P2Pool's `command:` **by default**, so outbound
dials go through Tor — no action needed.

**Opt out** for maximum yield (lower stale/uncle rate + a larger peer set, at the cost of exposing
your IP — worse on `--mini`/`--nano`): set `p2pool.clearnet: true` in `config.json` and re-run
`pithead apply`. For the strictest posture — refuse clearnet peers entirely (onion-only) — P2Pool
also has a `--no-clearnet-p2p` flag, not yet wired to its own config knob.

Then `docker compose up -d p2pool`. **Trade-off:** Tor adds latency to share propagation, which can
raise your orphan/uncle rate (most noticeable on mini/nano), and `--no-clearnet-p2p` shrinks your
peer set to onion-only. Measure the effect on your earnings before keeping it — which is exactly why
the Tor-by-default flip is a benchmarked **v1.1** change (#165), not a v1.0 default. (This hand-edit
lives in `docker-compose.yml`, so re-apply it after a stack update until #165 lands.)

### XvB donation mining (#166)

When the optimizer donates to XMRvsBeast (XvB), it points the proxy at `na.xmrvsbeast.com:4247`
over clearnet, exposing your IP to XvB. Pool stratum over Tor is high-latency and hurts share
acceptance, so there's no clean Tor fix yet. To stop the egress entirely, **disable XvB**:

```jsonc
// config.json
"xvb": { "enabled": false }
```

This also stops the (already Tor-routed) stats fetch. v1.1 adds an `xvb.tor` opt-in to route donation
mining through Tor and pins `--donate-level 0`.

---

## Optional clearnet initial sync (off by default)

Routing **everything** over Tor is correct for ongoing operation, but it makes the **one-time initial
blockchain sync** (IBD) painfully slow: Tor circuits are bandwidth-capped and flaky, so a full Monero
sync can crawl at near-zero blocks/sec and stall for long stretches, and Tari's large chain is no
better. The standard pattern for Tor-based nodes is to **sync once over clearnet (fast), then lock
back to Tor.** This stack supports that as an explicit, default-off opt-in (#183).

**Per-component flags in `config.json`, both `false` by default:**

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

**What is exposed while a flag is on:** your host's **IP address**, to the P2P network of the enabled
chain — i.e. "this IP is running a Monero/Tari node." A few **DNS lookups** also happen over clearnet
during the window: for Monero, the two P2Pool-recommended priority-node hostnames
(`p2pmd.xmrvsbeast.com`, `nodes.hashvault.pro`); for Tari, `seeds.tari.com` (to the configured
resolvers `1.1.1.1` / `8.8.8.8` / `9.9.9.9`) to discover clearnet peers. This is the same exposure as
any ordinary clearnet node — which is exactly what this window temporarily is.

**What is *not* exposed:**

- **Your wallet addresses / payouts** — there is no wallet activity during a sync.
- **Monero transaction origin** — `tx-proxy=tor` is left in place, so any tx broadcast still goes over
  Tor. (And there's no broadcasting during IBD anyway.)
- Nothing about *what* you mine — only that an IP runs a node.

That's the same exposure as running any ordinary (non-Tor) full node, scoped to the sync window. For
a privacy-first deployment it's still a real disclosure, which is why it is **off by default** and
must be **explicitly opted into**.

### It switches back to Tor automatically (#234)

You don't have to babysit it. The dashboard already tracks each chain's sync state; the **first time
a clearnet node reports fully synced, it switches that node back to Tor for you** — it writes a
persistent "sync complete" marker and restarts the daemon, which comes back up Tor-only. From then
on the node stays on Tor across restarts, `apply`, and reboots (the marker, not the flag, is the
source of truth — so a restart can never silently re-expose a synced node). Monero and Tari transition
independently, each as soon as *it* finishes.

You can leave `clearnet_initial_sync: true` in `config.json`; it's effectively spent once the sync
completes. (To deliberately re-sync over clearnet later — e.g. after wiping a chain — toggle the flag
off and on again with `./pithead apply`, which re-arms it.)

### It is loud and always-visible

You can't enable this by accident or miss that it's active:

- **`./pithead apply`** prints a `⚠`-flagged, disruptive-change confirmation describing exactly what
  becomes exposed before it recreates the daemon.
- **`./pithead status`** and **`./pithead up`** print a prominent **"CLEARNET INITIAL SYNC ACTIVE —
  node IP exposed"** banner the whole time a node is actually on clearnet — and it **clears by itself**
  once the auto-transition completes.
- **`./pithead doctor`** raises a `⚠ WARN` while a node is exposed and flips back to a green
  `✓ OK "all node P2P is Tor-only"` once it's switched back.
- The **dashboard** shows the clearnet state live, and the **daemon container logs** a matching
  warning on every start until the transition completes.

If the automatic switch ever fails (e.g. the dashboard couldn't restart the container), it is
**fail-safe**: the marker is written before the restart, so any later restart still comes up Tor-only,
and the supervisor keeps retrying — a node is never silently stranded on clearnet. The banners and
`doctor` warning stay up until it's genuinely back on Tor.

---

## Local trust boundary & known limitations

Everything above is about **network** egress — what leaves the host. On the **host itself**, the
stack assumes the local machine and the private Docker bridge are trusted, which is the right model
for a single-purpose appliance. One consequence is worth recording explicitly:

- **The monerod RPC credential appears in the p2pool container's process arguments (#57).** p2pool
  accepts the monerod RPC login (`--rpc-login`) **only** as a command-line argument — it has no
  environment-variable or config-file equivalent — so the username/password are visible in the
  p2pool process's argv to any local process that can read it (`ps`, `/proc/<pid>/cmdline`). This is
  **local-only** (never remotely reachable) and the credential is an **auto-generated random secret**
  guarding a `restricted-rpc` (read-only, public-safe) endpoint that by default is bound to localhost
  plus the Docker bridge — **not** the LAN (set `monero.rpc_lan_access: true` to expose it, in which
  case the credential matters more). Moving it off argv isn't possible without removing RPC
  authentication (a worse trade-off — it's defense-in-depth on the internal path) or an upstream
  p2pool change, so it's **accepted as a known limitation** rather than fixed. Practical guidance: on
  a single-user appliance this is a non-issue; if you **co-host** the stack on a machine shared with
  other local users, treat the monerod RPC credential as visible to them and prefer a single-purpose
  host for stronger isolation.

## Maximum-privacy checklist

- [ ] Keep `:3333` off the public internet — firewall it to your LAN, set `p2pool.stratum_bind`,
  and/or require a `p2pool.stratum_password` (`pithead doctor` flags public-IP exposure).
- [ ] Route P2Pool outbound through Tor by editing its compose `command:` (above) if you accept the latency.
- [ ] Set `xvb.enabled: false` if you don't want any XvB egress.
- [ ] Leave `monero.clearnet_initial_sync` / `tari.clearnet_initial_sync` **off** (the default) to keep all node P2P on Tor. If you do use a clearnet sync, the dashboard switches each node back to Tor automatically once it's synced — `pithead doctor` flags it while exposed and clears when done.
- [ ] Run the initial install/build behind a VPN or `torsocks`.
- [ ] Leave Telegram (#121) and Healthchecks (#79) **off** unless you accept the inherent IP exposure.
- [ ] Run `pithead doctor` — it surfaces the public-IP exposure check among its diagnostics.

---

See also: [Architecture › Privacy by design](architecture.md#privacy-by-design) ·
[Connecting miners › Firewall](workers.md#firewall) · the privacy-egress epic (#160).
