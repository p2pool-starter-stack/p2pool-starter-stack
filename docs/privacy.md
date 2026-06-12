# Privacy & network egress

This is the single source of truth for **every connection the stack makes off your box** — where it
goes, whether it's routed over Tor, whether it's on by default, and how to lock it down.

**North-star:** nothing should leave the host to the internet except through Tor. Where that isn't
possible (or trades away yield), the connection must be **off or Tor-routed by default**, have a
**documented toggle**, and be **listed here**.

Honesty first: the stack is **Tor-first, not yet Tor-only**. Monero and Tari — including the DNS
lookups they used to leak — are fully Tor-routed. But as of v1.0 **two outbound yield paths still
use clearnet** (P2Pool's outbound peers and XvB donation mining), and **install/build reveals your
IP once**. Those are called out below with how to mitigate each today, and both clearnet yield paths
are slated to move to Tor-by-default (with an opt-out) in v1.1.

---

## Inbound — no port forwarding

Every service that accepts inbound connections does so through a **Tor hidden service (onion
address)**: monerod, Tari, and P2Pool each get one from the built-in Tor daemon. So:

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
| **monerod** P2P + tx broadcast | Monero network | — | ✅ Tor (`proxy=` / `tx-proxy=`) | on | always Tor |
| **monerod** DNS (checkpoints, blocklist, update check, priority-node hostnames) | DNS resolvers | "this IP runs Monero" | ✅ **closed** — `disable-dns-checkpoints`, `check-updates=disabled`, `enable-dns-blocklist=0`, hostname priority-nodes dropped (#161) | n/a | — |
| **monerod RPC to a remote node** (only if `monero.mode: remote`) | the node you configured | **your real home IP**, to that node's operator | ❌ clearnet | **off** — the bundled local node is the default and has no remote-RPC egress | use a node you run/trust, or one reachable as a `.onion` over Tor |
| **Tari** P2P | Tari network | — | ✅ Tor (`transport = "tor"`) | on | always Tor |
| **Tari** DNS seeds + Pulse (`seeds.tari.com`, `checkpoints.tari.com`) | DNS resolvers | "this IP runs Tari" | ✅ **closed** — `dns_seeds = []`, onion `peer_seeds`, resolver pointed at a dead address (#162) | n/a | — |
| **P2Pool** inbound peers | reach you via onion | — | ✅ onion hidden service | on | — |
| **P2Pool** outbound sidechain peers | clearnet P2Pool peers | **your real home IP** | ❌ **clearnet** | **on** | ⏳ Tor-by-default in v1.1 (#165). Harden now → [below](#hardening-the-clearnet-paths) |
| Dashboard **XvB stats** fetch | `xmrvsbeast.com` | your Monero **wallet** (no longer your IP) | ✅ Tor (`socks5h`, #163) | on, only if XvB enabled | `XVB_ENABLED=false` stops it |
| **XvB donation mining** (only while donating) | `na.xmrvsbeast.com:4247` | **your real home IP** | ❌ **clearnet** | on while donating | ⏳ Tor-by-default in v1.1 (#166). Disable XvB to stop it |
| Dashboard **update check** (#224) | `api.github.com` | "this IP runs Pithead" (+ which version) | ✅ Tor (`socks5h`) | **off** — opt-in `dashboard.check_for_updates` | enable per-config; routed via Tor, cached, fails silently offline |
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
| Source clone / release assets | `github.com` | install / update |
| Monero binaries | `downloads.getmonero.org` | image build (verified against a published **SHA256**) |
| Container images | `quay.io`, Docker Hub | image build / pull (pinned by **`@sha256:` digest**, #135) |

**Mitigation:** run the install/build behind a **VPN** or with `torsocks`, or pre-pull the images and
clone on another machine and copy them over. The downloads are pinned (SHA256 + image digests), so
the risk is the **one-time IP disclosure**, not tampering.

---

## Hardening the clearnet paths

Two outbound yield paths use clearnet in v1.0. Here's how to close each one **today**; v1.1 will make
the Tor routing the default.

### P2Pool outbound peers (#165)

P2Pool advertises its onion for *inbound* peers but dials *outbound* sidechain peers over clearnet,
exposing your IP to the P2Pool network. **v1.0 has no config knob for this yet** (#165 adds a
`p2pool.clearnet` toggle); to route those dials through Tor today, hand-edit P2Pool's `command:` in
`docker-compose.yml`, adding the SOCKS flags just before `${P2POOL_FLAGS}`:

```yaml
# docker-compose.yml — the p2pool service `command:`
      - --socks5
      - 172.28.0.25:9050
      - --socks5-proxy-type
      - tor
      # add '--no-clearnet-p2p' (its own line) to refuse clearnet peers entirely (onion-only)
      - ${P2POOL_FLAGS}
```

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
- [ ] Run the initial install/build behind a VPN or `torsocks`.
- [ ] Leave Telegram (#121) and Healthchecks (#79) **off** unless you accept the inherent IP exposure.
- [ ] Run `pithead doctor` — it surfaces the public-IP exposure check among its diagnostics.

---

See also: [Architecture › Privacy by design](architecture.md#privacy-by-design) ·
[Connecting miners › Firewall](workers.md#firewall) · the privacy-egress epic (#160).
