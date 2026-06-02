# Configuration

`config.json` is the **single source of truth** for the entire stack. The interactive `setup`
writes a minimal one for you; from then on you change the stack by editing `config.json` and
running `./stack.sh apply`.

## The minimal config

Only a few keys are required — your wallets, the node mode/credentials, the pool, and whether
the dashboard is served securely. **Every other key is optional and falls back to a sensible
default**, so leave it out unless you want to change it.

A fresh `config.json` looks like this (see [`config.json.template`](../config.json.template)):

```json
{
    "monero": {
        "mode": "local",
        "wallet_address": "your_monero_wallet_address",
        "node_username": "create_a_username_for_node",
        "node_password": "create_a_password_for_node"
    },
    "tari": {
        "wallet_address": "your_tari_wallet_address"
    },
    "p2pool": {
        "pool": "main"
    },
    "dashboard": {
        "secure": true
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
2. Run `./stack.sh apply`.

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
./stack.sh apply        # shows the changes and asks before disruptive ones
./stack.sh apply -y     # skip the confirmation prompt (for scripting)
```

For example, to switch P2Pool from `main` to `mini`, or to flip the dashboard from HTTPS to
plain HTTP, edit `config.json` and run `./stack.sh apply`.

---

## Configuration reference

| Key | Default | Description |
|---|---|---|
| `monero.mode` | `local` | `local` runs the bundled Monero node; `remote` connects to an external node (see `monero.remote`). |
| `monero.wallet_address` | _required_ | Your Monero payout address. |
| `monero.node_username` / `node_password` | _auto (local)_ | Credentials for the local node's RPC. `setup` auto-generates them; they're internal to the stack (monerod, p2pool, and the dashboard use them — the dashboard reads the node's `get_info` RPC for sync status). For a remote node, set only if it requires auth. |
| `monero.prune` | `true` | Prune the Monero blockchain to save disk space. |
| `monero.prep_blocks_threads` | `auto` | Block-verification threads during sync. `auto` = host cores − 2, clamped to 4–8. |
| `monero.rpc_lan_access` | `false` | `true` publishes the node's RPC on the LAN (`0.0.0.0`) for wallets on other machines; default is localhost-only. |
| `monero.remote.host` / `rpc_port` / `zmq_port` | — / `18081` / `18083` | Remote node connection details (used when `mode` is `remote`). |
| `monero.data_dir` | `auto` | Where the Monero blockchain lives on the host. `auto` = `./data/monero`. Point this at an existing `.bitmonero` directory to reuse a synced node — see [Reusing an existing node](#reusing-an-existing-node). |
| `tari.wallet_address` | _required_ | Your Tari (Minotari) payout address. |
| `tari.data_dir` | `auto` | Where the Tari node data lives on the host. `auto` = `./data/tari`. |
| `p2pool.pool` | `main` | P2Pool sidechain: `main`, `mini`, or `nano`. |
| `p2pool.data_dir` | `auto` | Where P2Pool data lives on the host. `auto` = `./data/p2pool`. |
| `xvb.enabled` | `true` | Enable XMRvsBeast bonus-round hashrate switching. |
| `xvb.url` | `na.xmrvsbeast.com:4247` | XMRvsBeast pool endpoint. |
| `xvb.donor_id` | `auto` | XvB donor id. `auto` = the first 8 characters of your Monero address. |
| `xvb.donation_level` | `auto` | Donation tier to target: `auto` (the highest tier your hashrate can sustain) or a specific tier (`donor` / `vip` / `whale` / `mega`). A specific tier is honored even if your hashrate can't hold it — the dashboard shows a warning badge in that case. See [Architecture › Algorithmic switching](architecture.md#algorithmic-switching). |
| `tor.data_dir` | `auto` | Where Tor's state (including onion keys) lives. `auto` = `./data/tor`. |
| `dashboard.secure` | `true` | `true` serves the dashboard over HTTPS (Caddy `tls internal`); `false` uses plain HTTP. |
| `dashboard.host` | `auto` | Hostname you use to reach the dashboard. `auto` = this machine's hostname. |
| `dashboard.data_dir` | `auto` | Where the dashboard's database lives. `auto` = `./data/dashboard`. |

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

Then run `./stack.sh apply`. Moving a data directory is treated as a disruptive change, so
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

Then run `./stack.sh apply`. The bundled `monerod` reuses the blockchain in place — no re-sync
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

- [Operations & Maintenance](operations.md) — the full `stack.sh` command reference and
  troubleshooting.
- [Architecture](architecture.md) — how the services use these settings, and the XvB switching
  engine behind `xvb.*`.
