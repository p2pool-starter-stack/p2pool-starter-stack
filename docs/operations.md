# Operations & Maintenance

Everything you do to the stack runs through `stack.sh`. Run `./stack.sh help` at any time to see
the full list.

## Command reference

| Command | Description |
|---|---|
| `./stack.sh setup` | First-time setup (interactive): dependency check, config, Tor provisioning, kernel optimization, and start. `--skip-optimize` skips kernel/GRUB tuning; `--skip-deps` skips the dependency check/install. |
| `./stack.sh apply` | Preview and apply `config.json` changes — warns before disruptive ones and recreates only what changed. `-y` / `--yes` skips the prompt. |
| `./stack.sh up` | Start the stack. |
| `./stack.sh down` | Stop the stack. |
| `./stack.sh restart` | Restart the stack. |
| `./stack.sh upgrade` | Rebuild and restart the containers (run after a `git pull`). |
| `./stack.sh logs [service]` | Follow logs for all containers, or a single service (e.g. `logs p2pool`). |
| `./stack.sh status` | Show container status **and health-check every expected service** — warns about anything down/unhealthy and exits non-zero if so (handy for cron/monitoring). Profile-aware, and treats a stopped `p2pool`/`xmrig-proxy` as intentional during a node-down failover or while the miner is held until the chains sync. |
| `./stack.sh reset-dashboard` | **DESTRUCTIVE** — wipes and recreates the dashboard and P2Pool data. |
| `./stack.sh help` | Show all commands. |

Service names for `logs` match the containers: `monerod`, `p2pool`, `tari`, `xmrig-proxy`,
`tor`, `dashboard`, `docker-proxy`, `docker-control`, `caddy`.

---

## Day-to-day

**Check status and watch logs:**

```bash
./stack.sh status
./stack.sh logs                 # everything
./stack.sh logs p2pool          # one service
```

`status` prints the usual compose table, then a per-service health check — a green ✓ for each
running (and healthy) service, and a ⚠/✗ for anything unhealthy, restarting, stopped, or missing.
It exits non-zero when something needs attention, so you can wire it into a cron/monitoring check.
A stopped `p2pool`/`xmrig-proxy` is reported as **intentional**, not an error: the dashboard stops
it either to fail workers over a node-down outage or while the miner is held until the required
chains finish their initial sync — check the dashboard to see which.

**Start / stop / restart:**

```bash
./stack.sh up
./stack.sh down
./stack.sh restart
```

**Change a setting:** edit `config.json`, then `./stack.sh apply`. See
[Configuration › Changing settings later](configuration.md#changing-settings-later).

---

## Updating the stack

Pull the latest changes, then rebuild and restart:

```bash
git pull
./stack.sh upgrade
```

`upgrade` rebuilds the container images and restarts the stack. Your data directories and
`config.json` are untouched, so your blockchain sync and settings are preserved across upgrades.

---

## Backups

Your important state lives in the data directories (by default under `./data/`, or wherever you
pointed each `*.data_dir` — see [Configuration › Data directories](configuration.md#data-directories)):

- **`config.json`** — your settings (keep a copy somewhere safe; it's `chmod 600`).
- **`data/tor/`** — your **onion service keys**. Back these up if you want to keep the same onion
  addresses across a rebuild.
- **`data/monero/`**, **`data/tari/`** — the blockchains. Large, but backing them up saves a
  re-sync; they can also be re-downloaded from the network if lost.
- **`data/dashboard/`** — the dashboard's historical stats database.

Stop the stack (`./stack.sh down`) before copying data directories so files are in a consistent
state.

---

## Troubleshooting

**The dashboard is stuck on Sync Mode.**
This usually just means a chain is still downloading. Confirm steady progress:

```bash
./stack.sh logs monerod
./stack.sh logs tari
```

If a node looks genuinely stalled (no new blocks over a long period), restart it with
`./stack.sh restart`. To avoid the wait entirely, point the stack at an existing synced
blockchain or a remote node — see
[Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

**Tari is using a lot of RAM, or keeps restarting.**
Both can be normal. Tari's memory grows over time (it's commonly seen using 10+ GB) — that by
itself isn't a problem as long as the host has headroom (`free -h`, `docker stats`). To stop a
*runaway* from taking the whole machine down, the Tari container has a **safety ceiling**
(`tari.mem_limit`, `auto` by default). `auto` sizes it from the RAM left after the ~6 GB RandomX
HugePages reservation, holding back ~25% of the rest for Monero/P2Pool/the OS — so ~7.5 GB on a
16 GB host, ~19 GB on 32 GB. If Tari ever hits the ceiling it restarts cleanly on its own while
Monero and P2Pool keep mining.

- **Tari restarts too often** — the ceiling is below Tari's real working set. Raise it, e.g.
  `"tari": { "mem_limit": "16g" }`, then `./stack.sh apply`.
- **You want to reserve more RAM for other apps on the box** — lower it, e.g.
  `"tari": { "mem_limit": "6g" }`, then `./stack.sh apply`. Set it too low and Tari may OOM-loop
  (restart repeatedly, never finishing its initial sync) — give it more.

See [Configuration reference](configuration.md#configuration-reference).

**Browser warns "your connection is not private."**
Expected with `dashboard.secure: true` — Caddy uses a self-signed certificate. Accept the
warning once. To use plain HTTP, set `dashboard.secure: false` and run `./stack.sh apply`.

**Workers don't show up in the dashboard.**
Check that each rig points at `YOUR_STACK_IP:3333` and that port `3333` is reachable from the
worker (firewall on the stack host?). See [Adding Workers](workers.md).

**Hashrate reads zero or the chart is blank.**
Give it a minute after a worker connects for stats to populate. Confirm the worker is actually
hashing (`./stack.sh logs xmrig-proxy`).

**P2Pool can't connect to a remote node.**
The node must be set up for mining — **ZMQ publishing enabled** (`zmq-pub`) and its RPC reachable
by P2Pool. Public "open node" endpoints don't qualify — use a node you run and control. See
[Configuration › Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node).

**HugePages shows as disabled / low.**
Persistent HugePages require a GRUB change and a **reboot**. Re-run `./stack.sh setup` (without
`--skip-optimize`) and reboot when prompted.

**Something looks broken in the dashboard data and you want a clean slate.**
`./stack.sh reset-dashboard` wipes and recreates the dashboard and P2Pool data. This is
**destructive** — you'll lose P2Pool sidechain state and dashboard history (your blockchains and
wallets are unaffected).

---

## For developers

- **Run the test suites locally** (mirrors CI): `make test` — or individually `make
  test-dashboard`, `make test-stack`, `make test-compose`, `make lint`.
- **Dashboard development** — see [`build/dashboard/README.md`](../build/dashboard/README.md) for
  the package layout, local dev setup, and the hermetic test suite.
