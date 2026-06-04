# Operations & Maintenance

Everything you do to the stack runs through `pithead`. Run `./pithead help` at any time to see
the full list.

## Command reference

| Command | Description |
|---|---|
| `./pithead setup` | First-time setup (interactive): dependency check, config, Tor provisioning, kernel optimization, and start. `--skip-optimize` skips kernel/GRUB tuning; `--skip-deps` skips the dependency check/install. |
| `./pithead apply` | Preview and apply `config.json` changes — warns before disruptive ones and recreates only what changed. `-y` / `--yes` skips the prompt. |
| `./pithead up` | Start the stack. |
| `./pithead down` | Stop the stack. |
| `./pithead restart` | Restart the stack. |
| `./pithead upgrade` | Rebuild and restart the containers (run after a `git pull`). |
| `./pithead logs [service]` | Follow logs for all containers, or a single service (e.g. `logs p2pool`). |
| `./pithead status` | Show container status **and health-check every expected service** — warns about anything down/unhealthy and exits non-zero if so (handy for cron/monitoring). Profile-aware, and treats a stopped `p2pool`/`xmrig-proxy` as intentional during a node-down failover or while the miner is held until the chains sync. |
| `./pithead doctor` | Read-only diagnostics: deps, Docker, AVX2, HugePages, RAM/disk, `.env`/onion state, and container status — a paste-able health report. |
| `./pithead backup` | Save `config.json`, `.env`, `Caddyfile`, and the Tor onion keys to a timestamped `tar.gz` under `backups/` (checks free space first). `--with-chains` also includes the blockchain data; `--force` skips the space check. |
| `./pithead restore <archive>` | Restore those files from a backup archive (asks before overwriting; fixes Tor key ownership). |
| `./pithead reset-dashboard` | **DESTRUCTIVE** — wipes and recreates the dashboard and P2Pool data. |
| `./pithead help` | Show all commands. |

Service names for `logs` match the containers: `monerod`, `p2pool`, `tari`, `xmrig-proxy`,
`tor`, `dashboard`, `docker-proxy`, `docker-control`, `caddy`.

---

## Day-to-day

**Check status and watch logs:**

```bash
./pithead status
./pithead logs                 # everything
./pithead logs p2pool          # one service
```

`status` prints the usual compose table, then a per-service health check — a green ✓ for each
running (and healthy) service, and a ⚠/✗ for anything unhealthy, restarting, stopped, or missing.
It exits non-zero when something needs attention, so you can wire it into a cron/monitoring check.
A stopped `p2pool`/`xmrig-proxy` is reported as **intentional**, not an error: the dashboard stops
it either to fail workers over a node-down outage or while the miner is held until the required
chains finish their initial sync — check the dashboard to see which.

**Start / stop / restart:**

```bash
./pithead up
./pithead down
./pithead restart
```

**Change a setting:** edit `config.json`, then `./pithead apply`. See
[Configuration › Changing settings later](configuration.md#changing-settings-later).

---

## Updating the stack

Pull the latest changes, then rebuild and restart:

```bash
git pull
./pithead upgrade
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

Stop the stack (`./pithead down`) before copying data directories so files are in a consistent
state.

### `backup` / `restore`

Rather than copying files by hand, let `pithead` do it for you:

```bash
./pithead backup
```

That's it. This saves the things you can't get back — your `config.json`, your secrets
(`.env`), and the **Tor onion address keys** — into a small, timestamped file under `backups/`.
It's quick and small because your blockchains are **not** included (they just re-sync). The
archive is locked down to `chmod 600`, and `pithead` prints its path when it's done. Before it
writes anything, it does a quick free-space check so a backup can't fill your disk.

**Optional extras** (you usually don't need these):

```bash
./pithead backup --with-chains   # also include the blockchain data — much bigger and slower
./pithead backup --force         # skip the free-space check and back up anyway
```

To recover — on a new machine, or after a wipe — copy the archive back and run:

```bash
./pithead down                       # stop the stack first so files restore cleanly
./pithead restore backups/pithead-backup-YYYYmmdd-HHMMSS.tar.gz
./pithead up
```

`restore` always **asks before it overwrites anything**, so you can change your mind. It puts
the files back where they belong and sorts out the Tor key ownership for you, so your onion
address comes back exactly as it was.

---

## Troubleshooting

**The dashboard is stuck on Sync Mode.**
This usually just means a chain is still downloading. Confirm steady progress:

```bash
./pithead logs monerod
./pithead logs tari
```

If a node looks genuinely stalled (no new blocks over a long period), restart it with
`./pithead restart`. To avoid the wait entirely, point the stack at an existing synced
blockchain or a remote node — see
[Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

**Tari shows high memory use.**
Usually nothing to worry about — most of it is reclaimable disk cache, not a leak. Tari has an
auto-sized memory limit (`tari.mem_limit`) that keeps a genuine runaway from affecting the rest of
the stack. Only change it if Tari restarts repeatedly (give it more) or you want to free RAM for
other apps (give it less), then run `./pithead apply`.

**Browser warns "your connection is not private."**
Expected with `dashboard.secure: true` — Caddy uses a self-signed certificate. Accept the
warning once. To use plain HTTP, set `dashboard.secure: false` and run `./pithead apply`.

**Workers don't show up in the dashboard.**
Check that each rig points at `YOUR_STACK_IP:3333` and that port `3333` is reachable from the
worker (firewall on the stack host?). See [Connecting Miners](workers.md).

**Hashrate reads zero or the chart is blank.**
Give it a minute after a worker connects for stats to populate. Confirm the worker is actually
hashing (`./pithead logs xmrig-proxy`).

**P2Pool can't connect to a remote node.**
The node must be set up for mining — **ZMQ publishing enabled** (`zmq-pub`) and its RPC reachable
by P2Pool. Public "open node" endpoints don't qualify — use a node you run and control. See
[Configuration › Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node).

**HugePages shows as disabled / low.**
Persistent HugePages require a GRUB change and a **reboot**. Re-run `./pithead setup` (without
`--skip-optimize`) and reboot when prompted.

**Something looks broken in the dashboard data and you want a clean slate.**
`./pithead reset-dashboard` wipes and recreates the dashboard and P2Pool data. This is
**destructive** — you'll lose P2Pool sidechain state and dashboard history (your blockchains and
wallets are unaffected).

---

## For developers

- **Run the test suites locally** (mirrors CI): `make test` — or individually `make
  test-dashboard`, `make test-stack`, `make test-compose`, `make lint`.
- **Dashboard development** — see [`build/dashboard/README.md`](../build/dashboard/README.md) for
  the package layout, local dev setup, and the hermetic test suite.
