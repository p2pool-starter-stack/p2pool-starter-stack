# Connecting Miners

This stack is the **orchestrator** for your mining operation: every miner you own connects to a
**single endpoint**, and the stack routes their combined hashrate — handling pool selection,
payouts, and the P2Pool/XvB split centrally. Your miners stay dead simple; all the coordination
lives here.

The endpoint is the `xmrig-proxy` service on port **3333**.

> **You do not put a wallet address in your miner config.** Payouts are managed by the P2Pool
> service on the stack — miners only need to know *where the stack is*.

---

## Already have miners? Connect them

If you already run [XMRig](https://github.com/xmrig/xmrig) (or any RandomX miner), point it at the
stack and you're done. Use the machine running the stack as the host, on port `3333`:

```json
{
    "pools": [
        {
            "url": "YOUR_STACK_IP:3333",
            "user": "my-rig-01"
        }
    ]
}
```

That's the whole pool config. Start the miner and it appears in the dashboard's **Workers Alive**
table within a few seconds.

- **`user` is just a label** for the rig — use its hostname so you can tell workers apart on the
  dashboard. (No wallet address — see above.)
- **Point all your rigs at the same `YOUR_STACK_IP:3333`.** The stack aggregates them; there's
  nothing per-rig to configure beyond the label.
- **`YOUR_STACK_IP`** is the stack host's IP or a DNS-resolvable hostname. For a stable address
  on a home LAN, set a DHCP reservation (or a static IP) for the stack host.

### Miner version & compatibility

There's **no required miner version**. The stack's `xmrig-proxy` and P2Pool speak the standard
Stratum protocol and accept any miner that supports NiceHash (XMRig enables this automatically when
it connects through a proxy). Any reasonably recent **XMRig (5.0+, which introduced RandomX)** works
— the stack's component versions don't dictate a miner version. When in doubt, run the latest XMRig.

### Networking notes

- Miners connect over your local network (plain stratum). The Tor layer is for the stack's
  *upstream* connections to the Monero/Tari/P2Pool networks — **your rigs don't need Tor**.

### Firewall

- Port **3333** must be reachable from each miner to the stack machine. If the stack host has a
  firewall, allow inbound `3333` from your LAN.
- By default the stack publishes `3333` on **all** of the host's interfaces (`0.0.0.0`) so any rig
  on your LAN can connect with no extra setup. **On a host with a public IP, that port is reachable
  from the internet** — plain stratum is unauthenticated by default, so it should never be exposed
  there. Lock it down with controls that complement each other: narrow the **bind address** with
  [`p2pool.stratum_bind`](configuration.md#configuration-reference), restrict the **source range**
  with a host firewall, and/or require a **password** with [`p2pool.stratum_password`](#authentication).
- **`pithead setup` and `doctor` flag this for you**: when the host has a public IP and stratum is
  bound to all interfaces, they print a warning pointing back here. A NAT'd home host — no public IP
  on its own interfaces — sees nothing, so this only nudges the hosts that are actually exposed.

#### `p2pool.stratum_bind` — which interface to listen on

This is the host **bind address**: it controls *which network interface* the `3333` port is
published on. It takes a **single IPv4 address** (it maps directly to Docker's port-publish host
IP), **not** a subnet/CIDR — `192.168.1.0/24` is invalid and is rejected at setup.

| Value | Effect |
|---|---|
| `0.0.0.0` (default) | All interfaces — every rig on the LAN can connect (and the public IP, if any). |
| `192.168.1.10` | Only the interface holding that LAN IP — not published on a public/WAN interface. Must be an IP actually assigned to the host. |
| `127.0.0.1` | Loopback only — disables LAN access entirely (e.g. when every worker runs on the stack host itself). |

Narrowing the bind to a LAN IP stops the port appearing on a public interface, but **any host that
can route to that LAN IP can still connect**. To allow only a specific subnet, use a firewall.

#### Restricting by subnet — use a firewall

Limiting *which source addresses* may connect (e.g. only `192.168.1.0/24`) is source-based access
control, which a bind address can't express — that's a firewall rule. Examples that allow your LAN
subnet and drop everything else on `3333`:

```bash
# ufw (Ubuntu's default): allow the LAN subnet, deny the rest
sudo ufw allow from 192.168.1.0/24 to any port 3333 proto tcp
sudo ufw deny 3333/tcp
```

```bash
# nftables: allow 192.168.1.0/24, drop other inbound 3333
sudo nft add rule inet filter input tcp dport 3333 ip saddr 192.168.1.0/24 accept
sudo nft add rule inet filter input tcp dport 3333 drop
```

Adjust `192.168.1.0/24` to your own LAN range. Combining both — bind to the LAN IP **and**
firewall the subnet — is the belt-and-suspenders setup for a host that also has a public IP.

If a worker doesn't show up, see
[Operations › Troubleshooting](operations.md#troubleshooting).

### Authentication

By default `3333` accepts **any** rig that can reach it — the stratum `pass` is ignored. To require a
shared secret, set [`p2pool.stratum_password`](configuration.md#configuration-reference); the proxy
then rejects any rig whose stratum `pass` doesn't match, so only devices you've configured can mine.
That also means only they can register a worker name, which shrinks the worker-name **SSRF** surface
(a malicious worker name is how an untrusted device could otherwise probe the dashboard's internals).

```jsonc
// config.json — "auto" generates a stable random secret; or set your own string
"p2pool": { "stratum_password": "auto" }
```

After `pithead apply`, the stack prints the password (it's also saved in `.env` as
`PROXY_STRATUM_PASSWORD`). Add it as the `pass` field on **every** rig — rigs without it are rejected:

```json
{
    "pools": [
        {
            "url": "YOUR_STACK_IP:3333",
            "user": "my-rig-01",
            "pass": "the-stratum-password"
        }
    ]
}
```

Using **[RigForge](https://github.com/p2pool-starter-stack/rigforge)** (below)? It's the same
`pools[].pass` field — set it in the rig's `config.json` and run `rigforge apply`. See
[RigForge › Pithead Integration › Stratum authentication](https://github.com/p2pool-starter-stack/rigforge/blob/main/docs/pithead-integration.md#stratum-authentication-optional).

**Caveat:** the password travels in **cleartext** over the LAN (plain stratum has no TLS), so this is
access control — *who may mine* — not eavesdropping protection. On a trusted LAN it's enough; if you
must expose `3333` more widely, combine it with `stratum_bind` and a firewall (above). Leaving it
unset (`""`, the default) keeps the open, no-password behavior.

---

## New to mining? Start with RigForge

If you don't have miners set up yet — or you want the best hashrate without hand-tuning — use
**[RigForge](https://github.com/p2pool-starter-stack/rigforge)**, the companion miner kit for this
stack.

RigForge turns a fresh machine into a fully tuned worker in one command: it builds XMRig from
source, applies CPU- and kernel-level tuning (HugePages, MSR, NUMA), and runs it as a managed
service. During setup it asks for your stack's hostname and wires up the `3333` connection for you.

```bash
git clone https://github.com/p2pool-starter-stack/rigforge.git
cd rigforge
chmod +x rigforge.sh
sudo ./rigforge.sh
```

See the **[RigForge README](https://github.com/p2pool-starter-stack/rigforge)** for the full guide,
including **[worker hardware requirements](https://github.com/p2pool-starter-stack/rigforge#-hardware-requirements)**,
kernel tuning, and verification.

---

## See also

- [Getting Started](getting-started.md) — first-run setup and what to expect while the node syncs.
- [The Dashboard](dashboard.md) — the Workers Alive table and per-worker stats.
- [Hardware Requirements](hardware.md) — sizing the **stack host** (miners are sized in RigForge).
