# Connecting Miners

How to point miners at the stack. Every miner connects to one endpoint; the stack handles pool
selection, payouts, and the P2Pool/XvB split centrally.

The endpoint is the `xmrig-proxy` service on port `3333`.

> Do not put a wallet address in your miner config. The P2Pool service on the stack handles payouts.
> Miners only need to know where the stack is.

---

## Already have miners? Connect them

If you already run [XMRig](https://github.com/xmrig/xmrig) (or any RandomX miner), point it at the
stack host on port `3333`:

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

That is the whole pool config. Start the miner; it appears in the dashboard's Workers Alive table
within a few seconds. Until the first worker connects, that table shows this connect hint with the
stack's address filled in.

- `user` is a label for the rig. Use its hostname to tell workers apart on the dashboard. (No wallet
  address; see above.)
- Point every rig at the same `YOUR_STACK_IP:3333`. The stack aggregates them; nothing per-rig to
  configure beyond the label.
- `YOUR_STACK_IP` is the stack host's IP or a DNS-resolvable hostname. For a stable address on a home
  LAN, set a DHCP reservation (or a static IP) for the stack host.
- Add a backup pool for failover. List a second entry in `pools` (a public pool, or another stack).
  If the Monero node goes down or is still syncing, the stack stops accepting work so rigs fail over
  to the backup, then switch back when it recovers.

### Miner version & compatibility

There's no required miner version. The stack's `xmrig-proxy` and P2Pool speak the standard Stratum
protocol and accept any miner that supports NiceHash (XMRig enables this automatically when it
connects through a proxy). Any reasonably recent XMRig (5.0+, which introduced RandomX) works; the
stack's component versions don't dictate a miner version. When in doubt, run the latest XMRig.

### Networking notes

- Miners connect over your local network (plain stratum). The Tor layer is for the stack's upstream
  connections to the Monero/Tari/P2Pool networks. Your rigs don't need Tor.

### Firewall

- Port `3333` must be reachable from each miner to the stack machine. If the stack host has a
  firewall, allow inbound `3333` from your LAN.
- By default the stack publishes `3333` on all of the host's interfaces (`0.0.0.0`) so any rig on
  your LAN can connect with no extra setup. On a host with a public IP, that port is reachable from
  the internet, and plain stratum is unauthenticated by default, so it should never be exposed there.
  Lock it down with controls that complement each other: narrow the bind address with
  [`p2pool.stratum_bind`](configuration.md#configuration-reference), restrict the source range with a
  host firewall, and/or require a password with [`p2pool.stratum_password`](#authentication).
- `pithead setup` and `doctor` flag this for you: when the host has a public IP and stratum is bound
  to all interfaces, they print a warning pointing back here. A NAT'd home host (no public IP on its
  own interfaces) sees nothing, so this only nudges the hosts that are actually exposed.

#### `p2pool.stratum_bind` — which interface to listen on

This is the host bind address: it controls which network interface the `3333` port is published on.
It takes a single IPv4 address (it maps directly to Docker's port-publish host IP), not a
subnet/CIDR. `192.168.1.0/24` is invalid and is rejected at setup.

| Value | Effect |
|---|---|
| `0.0.0.0` (default) | All interfaces. Every rig on the LAN can connect (and the public IP, if any). |
| `192.168.1.10` | Only the interface holding that LAN IP, not published on a public/WAN interface. Must be an IP actually assigned to the host. |
| `127.0.0.1` | Loopback only. Disables LAN access entirely (e.g. when every worker runs on the stack host itself). |

Narrowing the bind to a LAN IP stops the port appearing on a public interface, but any host that can
route to that LAN IP can still connect. To allow only a specific subnet, use a firewall.

#### Restricting by subnet — use a firewall

Limiting which source addresses may connect (e.g. only `192.168.1.0/24`) is source-based access
control, which a bind address can't express. That's a firewall rule. Examples that allow your LAN
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

Adjust `192.168.1.0/24` to your own LAN range. Combining both (bind to the LAN IP and firewall the
subnet) is the belt-and-suspenders setup for a host that also has a public IP.

If a worker doesn't show up, see
[Operations › Troubleshooting](operations.md#troubleshooting).

#### Non-standard stratum port

The stratum endpoint is published on `3333` by default. That's the standard path and needs no
configuration — every example on this page assumes it. Only change it if another service on the
host already holds `3333`. Set the port with [`p2pool.stratum_port`](configuration.md#configuration-reference):

```jsonc
// config.json
"p2pool": { "stratum_port": 4444 }
```

After `pithead apply`, point every rig at the new port (`YOUR_STACK_IP:4444`) — a rig still on the
old port can't connect. `apply` flags a port change as destructive for exactly this reason, and the
firewall rules above must allow the new port instead of `3333`. On [RigForge](https://github.com/p2pool-starter-stack/rigforge),
set the matching `pool.port` and run `rigforge apply`.

Only the operator-facing published port moves. P2Pool's own container-internal stratum stays on
`3333` (only `xmrig-proxy` dials it, on the Docker bridge — nothing outside the stack sees it), so
the internal wiring is untouched.

### Authentication

By default `3333` accepts any rig that can reach it; the stratum `pass` is ignored. To require a
shared secret, set [`p2pool.stratum_password`](configuration.md#configuration-reference). The proxy
then rejects any rig whose stratum `pass` doesn't match, so only devices you've configured can mine.
That also means only they can register a worker name, which shrinks the worker-name SSRF surface (a
malicious worker name is how an untrusted device could otherwise probe the dashboard's internals).

```jsonc
// config.json — "auto" generates a stable random secret; or set your own string
"p2pool": { "stratum_password": "auto" }
```

After `pithead apply`, the stack prints the password (it's also saved in `.env` as
`PROXY_STRATUM_PASSWORD`). Add it as the `pass` field on every rig; rigs without it are rejected:

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

Using [RigForge](https://github.com/p2pool-starter-stack/rigforge) (below)? It's the same
`pools[].pass` field. Set it in the rig's `config.json` and run `rigforge apply`. See
[RigForge › Pithead Integration › Stratum authentication](https://github.com/p2pool-starter-stack/rigforge/blob/main/docs/pithead-integration.md#stratum-authentication-optional).

NOTE: the password travels in cleartext over the LAN (plain stratum has no TLS), so this is access
control (who may mine), not eavesdropping protection. On a trusted LAN it's enough; if you must
expose `3333` more widely, combine it with `stratum_bind` and a firewall (above). Leaving it unset
(`""`, the default) keeps the open, no-password behavior.

### Reading each worker's stats (the dashboard's worker API probe)

Beyond what the proxy reports, the dashboard fetches each connected miner's own xmrig HTTP API
(`http://<miner-ip>:8080/1/summary`) for uptime and per-miner hashrate. It does this one way, chosen
by config; there's no trial-and-error. Defaults match a stock
[RigForge](https://github.com/p2pool-starter-stack/rigforge) worker: an open, read-only API (xmrig
`http.restricted` with no `access-token`) on port `8080`, so the standard stack needs no
configuration.

To point it at a differently-configured fleet, set
[`workers.api_auth`](configuration.md#configuration-reference) (and `workers.api_port` /
`workers.api_token`):

| `workers.api_auth` | Use when… | Bearer sent |
|---|---|---|
| `none` *(default)* | miners expose an open, restricted API (no token) | — |
| `name` | each miner's `access-token` equals its stratum name | the worker's name |
| `token` | all miners share one API token | `workers.api_token` |

Only the worker's validated IP is ever contacted; a miner-controlled worker name is never used as a
request host (the SSRF guard). If a probe fails, the worker isn't dropped: it keeps its
proxy-reported hashrate and is flagged `api ⚠` on the dashboard, with a single log line naming the
URL, status, and likely fix, so a misconfigured API reads differently from an offline miner.

> Upgrading? Earlier builds provisioned each miner with `access-token = <worker name>`. If your
> miners still carry a token, set `workers.api_auth: name`, otherwise the new no-auth default probe
> gets `401` and every worker shows `api ⚠`. (Reprovisioning the miners to drop the token is the
> other option; new RigForge workers ship open by default.)

#### Per-worker overrides

`workers.api_auth`/`api_port`/`api_token` set the probe for the *whole* fleet. When one rig differs
— its API is on a different port, on another interface than the address it mines from (NAT,
multi-homed), or carries its own token — override just that rig with
[`workers.list`](configuration.md#configuration-reference), a list of
`{name, host?, port?, token?, watts?, control_port?}` objects. Every field but `name` is optional:

```jsonc
// config.json — the rest of the fleet keeps the workers.* defaults
"workers": {
    "list": [
        { "name": "rig-01", "port": 18080 },
        { "name": "rig-02", "host": "10.0.0.9", "token": "rig-02-secret" }
    ]
}
```

`dashboard.workers` is a deprecated alias for `workers.list` (#506): a config from before the move
still works — the old location is read as a fallback with a one-time warning — but setting both is
refused at apply, and the old location is removed in v1.9.

The merge rule is: **per-worker field > fleet default > built-in default.** A rig with no entry (or
an entry that only sets `port`) inherits everything else from `workers.*`. A per-worker `token`
turns on token-auth for that one rig regardless of the fleet-wide `api_auth` mode.

`watts` is a manual power-draw estimate (in watts) for the dashboard's
[energy & profit calculator](dashboard.md#energy--profit). Set it only for a rig whose enriched feed
reports no measured watts — macOS (the RAPL probe is Linux-only), a non-RigForge miner, or an older
kit — so the fleet power total still counts it (marked *estimated*). A RigForge rig on Linux reports
its own watts and needs no estimate.

`control_port` (default `8082`) is the rig's writable control API port, used by
[Worker Inspect](dashboard.md#worker-inspect) to push config changes from the dashboard. Set it
alongside `host` and `token` to make a rig editable; leave the whole feature off by not enabling the
dashboard control channel. The token is the rig's `ACCESS_TOKEN` and never leaves the stack host — the
dashboard container doesn't hold it.

! The control token is **write-capable** and travels in **cleartext HTTP** over the LAN (like the
stratum password): a change can alter a rig's pools or its thermal `watchdog`/`max_temp_c`, so anyone
who can sniff or MITM the mining LAN and capture the token can push config to your rigs. Keep the
mining LAN isolated from untrusted devices, and treat the token as a secret (it lives only in the
owner-only `config.json`/`.env`, never in the dashboard container).

Entries are matched by `name` — the rig's stratum worker name (the part before any `+` suffix).
On a name miss the dashboard falls back to matching by the rig's connecting IP against an
operator-set `host`, which covers a rig that renamed itself but still connects from its declared
address. Duplicate names are legal but only the first-declared entry wins, so **renaming a rig means
updating its entry** here.

`host` exists for the case where a rig's API isn't reachable at the address it mines from. It must
be set by you in `config.json` and is never taken from anything a miner advertises: the dashboard
will not send a configured token to a host a miner could control (the same [SSRF guard](#authentication)
as the worker-name rule). Pinning `host` alongside `token` is the recommended pair — it stops an
imposter that claims a listed rig's name from pulling that rig's token to its own address.

The standard fleet — everyone on `8080`, token = rig name or open — needs no `workers.list`
at all.

#### RigForge enriched feed

A [RigForge](https://github.com/p2pool-starter-stack/rigforge) rig also serves an enriched read API
on port `8081`: the same `/1/summary` the dashboard already polls, plus a `rigforge` block carrying
the rig's RigForge version, tuning state, power draw and efficiency, CPU/firmware health, and
watchdog temperatures. Point that rig's descriptor `port` at it to pick the block up:

```jsonc
"dashboard": {
    "workers": [
        { "name": "rig-01", "port": 8081 }
    ]
}
```

Nothing else changes — the enriched feed is a superset, so uptime and per-miner hashrate come from
the same response. The dashboard then shows a RigForge version badge and health/power/tune/watchdog
chips for that rig (see [Dashboard › Workers Alive](dashboard.md#workers-alive)). A plain-xmrig rig
on `8080` sends no `rigforge` block and reads exactly as before — no chips, no error. Auth is
unchanged: send the rig's `token` only if it sets an `ACCESS_TOKEN` (the read API is open otherwise).

If the block also carries a `control` object — `{change_id, status, reason}`, mirroring the rig's
own control-API `/status` response read-only — the dashboard reconciles it against the [Worker
Inspect](dashboard.md#worker-inspect) change history (#579): a still-`accepted` row whose
`change_id` matches is updated to the reported terminal `status`
(`applied`/`rejected`/`rolled_back`). This is how a rollback slower than the host runner's 20s
status-poll deadline still reaches a terminal state without a second authenticated dial to the
control port.

[TODO: verify upstream — confirm the `rigforge.control` mirror ships in RigForge; until then this
parses to nothing and the row stays `accepted`.]

---

## New to mining? Start with RigForge

If you don't have miners set up yet, use
[RigForge](https://github.com/p2pool-starter-stack/rigforge), the companion miner kit for this stack.

RigForge builds XMRig from source, applies CPU- and kernel-level tuning (HugePages, MSR, NUMA), and
runs it as a managed service. During setup it asks for your stack's hostname and configures the
`3333` connection.

```bash
git clone https://github.com/p2pool-starter-stack/rigforge.git
cd rigforge
chmod +x rigforge.sh
sudo ./rigforge.sh
```

See the [RigForge README](https://github.com/p2pool-starter-stack/rigforge) for the full guide,
including [worker hardware requirements](https://github.com/p2pool-starter-stack/rigforge#-hardware-requirements),
kernel tuning, and verification.

---

## See also

- [Getting Started](getting-started.md) — first-run setup and what to expect while the node syncs.
- [The Dashboard](dashboard.md) — the Workers Alive table and per-worker stats.
- [Hardware Requirements](hardware.md) — sizing the stack host (miners are sized in RigForge).
