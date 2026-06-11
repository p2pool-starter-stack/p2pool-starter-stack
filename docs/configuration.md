# Configuration

`config.json` is the **single source of truth** for the entire stack. The interactive `setup`
writes a minimal one for you; from then on you change the stack by editing `config.json` and
running `./pithead apply`.

## The minimal config

Only your two **wallet addresses** are required. **Every other key is optional and falls back to
a sensible default** — the node runs locally, on the `main` pool, with a secure dashboard, and the
local node's RPC credentials are **auto-generated** for you — so leave a key out unless you want to
change it.

A fresh `config.json` is just this (see [`config.json.template`](../config.json.template)):

```json
{
    "monero": {
        "wallet_address": "your_monero_wallet_address"
    },
    "tari": {
        "wallet_address": "your_tari_wallet_address"
    }
}
```

For the complete shape with **every** key and its default, see
[`config.advanced.example.json`](../config.advanced.example.json) and copy in only the keys you
want to override.

> The string `"auto"` anywhere means **"let the stack pick the default"** — a default path, the
> machine's hostname, a derived donor id, and so on.

---

## Changing settings later

1. Edit `config.json`.
2. Run `./pithead apply`.

`apply` is designed to be safe to run anytime:

- It **previews exactly what will change**, diffing your edited `config.json` against the running
  configuration.
- It **warns before anything disruptive** — switching the Monero node local↔remote, toggling
  pruning, changing a payout address, exposing the RPC to your LAN, or moving a data directory all
  trigger a confirmation prompt.
- It then regenerates the `.env`, Caddy, and Tari configs and recreates **only** the containers
  that actually need it.
- It does **not** re-provision Tor, touch GRUB, or rotate the proxy token. If nothing changed, it
  does nothing.

```bash
# edit config.json, then:
./pithead apply        # shows the changes and asks before disruptive ones
./pithead apply -y     # skip the confirmation prompt (for scripting)
```

For example, to switch P2Pool from `main` to `mini`, or to flip the dashboard from HTTPS to
plain HTTP, edit `config.json` and run `./pithead apply`.

---

## Configuration reference

| Key | Default | Description |
|---|---|---|
| `monero.mode` | `local` | `local` runs the bundled Monero node; `remote` connects to an external node (see `monero.remote`). |
| `monero.wallet_address` | _required_ | Your Monero payout address. |
| `monero.node_username` / `node_password` | _auto (local)_ | Credentials for the local node's RPC, used only inside the stack (monerod, p2pool, and the dashboard, which reads the node's `get_info` for sync status). **Leave them blank** — on `setup` and on every `apply`, the stack fills in anything missing (username `admin`, a random alphanumeric password) and writes the values back into `config.json`, so they stay stable and you can see what was set. Set these yourself only for a **remote** node that requires RPC auth. |
| `monero.prune` | `true` | Prune the Monero blockchain to save disk space. The dashboard's Monero panel shows the resulting **Pruned**/**Full** mode and the node's on-disk DB size, so you can spot a config-vs-data mismatch when reusing a chain. |
| `monero.prep_blocks_threads` | `auto` | Block-verification threads during sync. `auto` = host cores − 2, clamped to 4–8. |
| `monero.rpc_lan_access` | `false` | `true` publishes the node's RPC on the LAN (`0.0.0.0`) for wallets on other machines; default is localhost-only. |
| `monero.remote.host` / `rpc_port` / `zmq_port` | — / `18081` / `18083` | Remote node connection details (used when `mode` is `remote`). |
| `monero.data_dir` | `auto` | Where the Monero blockchain lives on the host. `auto` = `./data/monero`. Point this at an existing `.bitmonero` directory to reuse a synced node — see [Reusing an existing node](#reusing-an-existing-node). |
| `monero.mem_limit` | `auto` | Upper limit on the monerod container's memory, so a leak/runaway OOM-restarts monerod alone instead of the host's OOM-killer picking a victim. `auto` is a generous ceiling (**6 GB**) that won't trip during normal operation **or initial sync** — monerod's OOM-triggering memory is small (~0.1 GiB at rest, ~1–3 GiB during sync) while its multi-GB blockchain DB is reclaimable, memory-mapped page cache that the kernel evicts under pressure rather than OOM-killing. Lower it only to free RAM; **raise it** for a **full (unpruned) node** doing a heavy initial sync on a fast disk, or if a low-RAM host ever OOMs monerod during IBD (it restarts and resumes — the on-disk chain is transactional, no data loss). Accepts any Docker memory value, e.g. `"8g"`. (Tari has its own `tari.mem_limit`; the dashboard, P2Pool, Tor, and the proxies are small and carry fixed conservative ceilings in `docker-compose.yml`.) |
| `tari.wallet_address` | _required_ | Your Tari (Minotari) payout address. |
| `tari.data_dir` | `auto` | Where the Tari node data lives on the host. `auto` = `./data/tari`. |
| `tari.mem_limit` | `auto` | Upper limit on the Tari container's memory, so a runaway Tari restarts cleanly on its own instead of dragging down the whole host. `auto` picks a safe size for your machine — leave it unless you want to give Tari less RAM (to free it for other apps) or more (if it ever restarts too often). Accepts any Docker memory value, e.g. `"8g"`. |
| `p2pool.pool` | `main` | P2Pool sidechain: `main`, `mini`, or `nano`. |
| `p2pool.stratum_bind` | `0.0.0.0` | Host **bind address** for the stratum port (`3333`) your rigs connect to — a single IPv4 address (maps to Docker's port-publish host IP), **not** a subnet/CIDR. Default `0.0.0.0` reaches the whole LAN out of the box; set a specific LAN IP (e.g. `192.168.1.10`) to limit it to one interface, or `127.0.0.1` to disable LAN access entirely. To restrict *which source subnet* may connect, use a firewall — see [Connecting Miners › Firewall](workers.md#firewall). |
| `p2pool.data_dir` | `auto` | Where P2Pool data lives on the host. `auto` = `./data/p2pool`. |
| `xvb.enabled` | `true` | Enable XMRvsBeast bonus-round hashrate switching. |
| `xvb.url` | `na.xmrvsbeast.com:4247` | XMRvsBeast pool endpoint. |
| `xvb.donor_id` | `auto` | XvB donor id. `auto` = the first 8 characters of your Monero address. |
| `xvb.donation_level` | `auto` | Donation tier to target: `auto` (the highest tier your hashrate can sustain) or a specific tier (`donor` / `vip` / `whale` / `mega`). A specific tier is honored even if your hashrate can't hold it — the dashboard shows a warning badge in that case. See [Architecture › Algorithmic switching](architecture.md#algorithmic-switching). |
| `tor.data_dir` | `auto` | Where Tor's state (including onion keys) lives. `auto` = `./data/tor`. |
| `dashboard.secure` | `true` | `true` serves the dashboard over HTTPS (Caddy `tls internal`); `false` uses plain HTTP. |
| `dashboard.host` | `auto` | Hostname you use to reach the dashboard. `auto` = this machine's hostname. |
| `dashboard.timezone` | `auto` | Timezone for the dashboard's timestamps and charts. `auto` = **the host machine's timezone** (auto-detected, falling back to `Etc/UTC`); set an IANA name (e.g. `America/Chicago`) to override. |
| `dashboard.data_dir` | `auto` | Where the dashboard's database lives. `auto` = `./data/dashboard`. |
| `dashboard.tari_required` | `true` | How much a Tari problem holds up the rest of the stack. Monero is **required** to mine, so its behavior isn't configurable: a monerod outage always rejects workers (stops `xmrig-proxy` so miners **fail over to their backup pools**), and the miner is always held until monerod finishes syncing. Tari is **only needed for merge mining**, so this one flag decides how much it blocks. **`true` (default):** a Tari outage also rejects workers, the miner waits for Tari's initial sync too, and a Tari-only (re)sync shows the full-screen Sync view. **`false` (non-blocking):** keep mining Monero through a Tari outage, start mining as soon as Monero is synced (Tari finishes in the background), and keep the normal dashboard — with a `Tari syncing` indicator — instead of the takeover screen. |
| `network.subnet` | `172.28.0.0/24` | The private Docker bridge the stack's containers run on. Change it **only** if install fails with `Pool overlaps with other one on this address space` — i.e. your host already uses `172.28.0.0/24` for another Docker network or interface. Must be a free **`X.Y.Z.0/24`** block (e.g. `"172.30.0.0/24"`); the services keep their fixed host octets (`.25`–`.31`) within it, so the structured addressing the dashboard and the worker SSRF guard rely on is preserved. |

---

## Data directories

Every stateful service stores its data in a host directory that you can place anywhere. By
default each one lives under `./data/<service>` inside the repo:

| Service | Config key | Default path | Mounted in container at |
|---|---|---|---|
| Monero | `monero.data_dir` | `./data/monero` | `/root/.bitmonero` |
| Tari | `tari.data_dir` | `./data/tari` | `/var/tari/node` |
| P2Pool | `p2pool.data_dir` | `./data/p2pool` | `/root` |
| Tor | `tor.data_dir` | `./data/tor` | `/var/lib/tor` |
| Dashboard | `dashboard.data_dir` | `./data/dashboard` | `/data` |

Set any `data_dir` to an absolute path to move that service's storage — for example, to put the
Monero blockchain on a dedicated SSD:

```json
{
    "monero": {
        "mode": "local",
        "wallet_address": "...",
        "data_dir": "/mnt/ssd/monero"
    }
}
```

Then run `./pithead apply`. Moving a data directory is treated as a disruptive change, so
`apply` confirms before recreating the affected container. `apply` creates any missing directory
and sets ownership automatically (Monero/Tari/P2Pool to your user, Tor to the container's user).

> **Note:** `apply` does **not** copy your existing data into a new location — it only points the
> container at the new path. If you're relocating data you already have, move the files yourself
> first (with the stack stopped), then update `data_dir` and run `apply`.

---

## Reusing an existing node

If you already run a synced Monero node, you can skip most — or all — of the initial blockchain
sync. There are two ways to do it.

### Option A — Point the bundled node at your existing blockchain

The Monero data directory mounts to `/root/.bitmonero` inside the container, the same layout a
standard `monerod` uses. To have the bundled node adopt a blockchain you've already downloaded,
point `monero.data_dir` at your existing `.bitmonero` directory:

```json
{
    "monero": {
        "mode": "local",
        "wallet_address": "...",
        "data_dir": "/home/me/.bitmonero"
    }
}
```

Then run `./pithead apply`. The bundled `monerod` reuses the blockchain in place — no re-sync
from genesis, just a quick catch-up of any blocks produced since your node last ran.

A few things to keep in mind:

- **Stop your other node first.** Two `monerod` processes must never use the same data directory
  at the same time, or they'll corrupt the database.
- **Match the prune setting.** A pruned blockchain needs `monero.prune: true` (the default); an
  unpruned (full) blockchain needs `monero.prune: false`. They're not interchangeable.
- **Ownership.** The host directory must be readable/writable by the user that runs the stack.
  `apply` sets ownership on directories it creates, but won't change an existing tree out from
  under you.

### Option B — Connect to a remote node

If your existing Monero node runs on another machine — or you want to use a node you don't host —
switch to **remote mode** and the stack won't run its own `monerod` at all. See
[Connecting to a remote Monero node](#connecting-to-a-remote-monero-node) below.

> **Tari** uses the same mechanism: point `tari.data_dir` at an existing Minotari node directory
> (mounted at `/var/tari/node`) to reuse its synced chain.

---

## Connecting to a remote Monero node

To connect to an external Monero node instead of running one locally, set `monero.mode` to
`remote` and fill in `monero.remote`:

```json
{
    "monero": {
        "mode": "remote",
        "wallet_address": "...",
        "remote": {
            "host": "node.example.com",
            "rpc_port": 18081,
            "zmq_port": 18083
        }
    }
}
```

- The bundled `monerod` container is not started in remote mode.
- The remote node must be set up for **P2Pool mining** — with **ZMQ publishing enabled**
  (`zmq-pub`, port `18083` by default) and its RPC reachable by P2Pool. In practice that means a
  node **you run and control**; general-purpose public "open node" endpoints do **not** work,
  since they don't expose ZMQ.
- If the remote node requires RPC authentication, set `monero.node_username` / `node_password`
  to match it; otherwise leave them out.

Switching between `local` and `remote` is a disruptive change, so `apply` will confirm before
applying it.

---

## See also

- [Operations & Maintenance](operations.md) — the full `pithead` command reference and
  troubleshooting.
- [Architecture](architecture.md) — how the services use these settings, and the XvB switching
  engine behind `xvb.*`.
