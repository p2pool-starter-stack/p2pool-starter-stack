# Operations & Maintenance

Command reference for `pithead`, the CLI that manages the stack. Run `./pithead help` for the same list.

## Command reference

| Command | Description |
|---|---|
| `./pithead setup` | First-time setup (interactive): dependency check, config, Tor provisioning, kernel optimization, and start. `--skip-optimize` skips kernel/GRUB tuning; `--skip-deps` skips the dependency check/install. |
| `./pithead apply` | Preview and apply `config.json` changes. Warns before disruptive ones and recreates only what changed. `-y` / `--yes` skips the prompt. |
| `./pithead up` | Start the stack. |
| `./pithead down` | Stop the stack. |
| `./pithead restart` | Restart the stack. |
| `./pithead upgrade` | Re-render the generated config, then **pull** (release bundle) or **rebuild** (source checkout) the images and restart. Run after downloading a newer bundle or a `git pull`. |
| `./pithead logs [service]` | Follow logs for all containers, or a single service (e.g. `logs p2pool`). |
| `./pithead status` | Show container status and health-check every expected service. Warns about anything down/unhealthy and exits non-zero if so (handy for cron/monitoring). Profile-aware, and treats a stopped `p2pool`/`xmrig-proxy` as intentional during a node-down failover or while the miner is held until the chains sync. |
| `./pithead doctor` | Read-only diagnostics: deps, Docker, AVX2, HugePages, RAM/disk, `.env`/onion state, and container status — plus four runtime checks: the Tor-egress firewall rules are actually installed (a reboot silently drops them while the containers auto-restart), something is listening on stratum `:3333`, the dashboard app answers behind its container, and a clearnet request through Tor's SOCKS succeeds (a failing Tor guard breaks Healthchecks/Telegram/XvB while mining still works — restart the tor container to pick fresh guards). A paste-able health report. |
| `./pithead backup` | Save `config.json`, `.env`, `Caddyfile`, the Tor onion keys, and the dashboard's database (your hashrate history & settings) to a timestamped `tar.gz` under `backups/` (checks free space first; stops a running stack for a clean copy, then restarts it). `--with-chains` also includes the blockchain data; `-y` / `--yes` skips the prompts (low free space and stopping the stack). |
| `./pithead restore <archive>` | Restore those files from a backup archive (asks before overwriting; fixes Tor key ownership). `-y` / `--yes` skips the prompt. |
| `./pithead reset-dashboard` | **DESTRUCTIVE**. Wipes and recreates the dashboard and P2Pool data. `-y` / `--yes` skips the prompt. |
| `./pithead version` | Print the installed stack version on one line (also `-V` / `--version`). Offline; no update check. `doctor` repeats it in its header. |
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

`status` prints the usual compose table, then a per-service health check: a green ✓ for each
running (and healthy) service, and a ⚠/✗ for anything unhealthy, restarting, stopped, or missing.
It exits non-zero when something needs attention, so you can wire it into a cron/monitoring check.
A stopped `p2pool`/`xmrig-proxy` is reported as intentional, not an error: the dashboard stops it
either to fail workers over a node-down outage or while the miner is held until the required chains
finish their initial sync. When a chain is still syncing, `status` reads the dashboard's own
`/api/state` and prints its progress inline — a line per chain with the percent and the number of
blocks left, so you don't have to open the dashboard to see how far off release is. No ETA is
shown: block rate isn't sampled, so the blocks-remaining count is the honest figure. The lines are
skipped once both chains are synced, or when the dashboard app isn't answering yet.

**Start / stop / restart:**

```bash
./pithead up
./pithead down
./pithead restart
```

**Change a setting:** edit `config.json`, then run `./pithead apply`. See
[Configuration › Changing settings later](configuration.md#changing-settings-later).

**Changing the payout wallet:** `apply` asks you to type the first 8 characters of the new address
(a bare `y` is not enough for the one change that redirects every future reward; `apply -y` skips
the prompt for automation). Changing both the Monero and Tari addresses in one `apply` prompts
once per address. The dashboard also watches the wallet p2pool actually mines to: any
change raises a `wallet_changed` [Telegram alert](telegram.md) and a 72-hour top-bar banner —
including a change you made yourself. Treat that pair as confirmation; if you didn't change it,
your rewards are being redirected — check `config.json` and re-apply the correct address.

**Reboot resilience:** every service runs with `restart: unless-stopped`, so the stack restarts
after a reboot or power loss, provided the Docker daemon starts at boot. Ubuntu's packaged Docker
enables this by default; a custom/rootless install (or `setup --skip-deps`) may leave it disabled.
`./pithead doctor` checks this and warns if Docker isn't boot-enabled. Fix it with
`sudo systemctl enable --now docker`.

---

## Updating the stack

The update path depends on how you installed (see [Getting Started](getting-started.md#2-get-the-code)).

**Release bundle (the default):** from the install directory, re-download the latest bundle over it,
then upgrade. `upgrade` **pulls** the new published images:

```bash
curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz --strip-components=1
./pithead upgrade
```

**Source checkout:** pull the latest code, then upgrade. `upgrade` **rebuilds** the images locally:

```bash
git pull
./pithead upgrade
```

Either way, `upgrade` re-renders the generated config (`.env`, the Caddyfile, and the Tari config) for
the new release *before* pulling/rebuilding, so a release that changes a config template or adds an
`.env` var takes effect, not just the new image. Data directories and `config.json` are untouched, so
blockchain sync and settings survive an upgrade.

Run `./pithead version` to see what is currently installed before and after an upgrade.

### Switching a source checkout to release images

A cloned repo builds `:dev` images locally and shows a `dev · branch @ commit` version badge. To run
the published images instead (clean version badge, working update-checker, no local build), convert the
install in place. `config.json`, `.env`, the Tor onion keys, and data directories are preserved:

```bash
./pithead backup -y          # safety snapshot: config.json, .env, onion keys, dashboard db (chains excluded)
# overlay the published release files — leaves config.json, .env, .git, and your data dirs untouched:
curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz --strip-components=1
rm -f build/*/Dockerfile     # remove the image Dockerfiles → pithead switches from build to pull
./pithead upgrade            # re-render config, pull :vX.Y.Z, recreate
```

`pithead` chooses build-vs-pull by whether the image Dockerfiles are present (`build/<svc>/Dockerfile`).
Deleting them flips it from building `:dev` locally to pulling the published `:vX.Y.Z`. To go back to
building from source, `git checkout vX.Y.Z` (or `git pull`) restores the Dockerfiles, then
`./pithead upgrade` rebuilds locally. `upgrade` refuses to start on a non-primary Monero payout address,
so confirm yours is a `4…`/95-char address first (see [Configuration](configuration.md)).

> **Moving the install?** Data directories are stored as absolute paths in `.env`, so relocating or
> copying the stack to a different path (or running a second checkout) points it at a *different,
> empty* `data/`: a full re-sync, and the dashboard history is orphaned. If you move the install,
> move its `data/` with it, or set absolute `data_dir` paths in `config.json` and run `./pithead
> apply`. `./pithead up` and `./pithead doctor` now warn when a data directory named in `.env` is missing.

---

## Backups

State lives in the data directories (by default under `./data/`, or wherever each `*.data_dir`
points; see [Configuration › Data directories](configuration.md#data-directories)):

- **`config.json`**: settings. `chmod 600`; keep a copy off-host.
- **`data/tor/`**: onion service keys. Back up to keep the same onion addresses across a rebuild.
- **`data/monero/`**, **`data/tari/`**: the blockchains. Large; backing them up saves a re-sync,
  but they re-download from the network if lost.
- **`data/dashboard/`**: the dashboard database (hashrate history and settings). Small and
  irreplaceable — it does not re-sync — so it is part of the default `backup`.

Stop the stack (`./pithead down`) before copying data directories by hand, so files are consistent.

### `backup` / `restore`

Instead of copying files by hand, run:

```bash
./pithead backup
```

This writes a timestamped `tar.gz` under `backups/` holding the irreplaceable state: `config.json`,
`.env` (secrets), the `Caddyfile` (if present), the Tor onion keys, and the dashboard database
(hashrate history and settings). Blockchains are excluded (they re-sync), so the archive is small.
The archive is `chmod 600`, and `pithead` prints its path when done. Before writing, `backup` checks
free space and prompts if it looks tight. On a source checkout, `backups/` is git-ignored — the
archive carries `.env` and the onion private keys, and secret scanners can't see inside a tarball.

If the stack is running, `backup` stops it for a consistent copy and restarts it when done. Pass
`-y` / `--yes` to skip both prompts (low-space warning, stop-the-stack question).

Include the blockchains (larger, slower) with:

```bash
./pithead backup --with-chains   # also include the blockchain data
```

To recover (on a new machine, or after a wipe) copy the archive back and run:

```bash
./pithead down                       # stop the stack first so files restore cleanly
./pithead restore backups/pithead-backup-YYYYmmdd-HHMMSS.tar.gz
./pithead up
```

`restore` prompts before overwriting anything (pass `-y` / `--yes` to skip). It puts the files back,
fixes Tor key ownership so the onion address returns unchanged, and restores hashrate history and
dashboard settings.

> NOTE: After a restore, Caddy regenerates the dashboard's HTTPS certificate, so the browser shows
> its "not trusted" warning once. Accept it as on first setup.

---

## Troubleshooting

**The dashboard is stuck on Sync Mode.**
A chain is still downloading. Confirm steady progress:

```bash
./pithead logs monerod
./pithead logs tari
```

If a node is stalled (no new blocks over a long period), restart it with `./pithead restart`. To
skip the wait, point the stack at an existing synced blockchain or a remote node. See
[Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node).

**Tari shows high memory use.**
Most of it is reclaimable disk cache, not a leak. Tari runs under an auto-sized memory limit
(`tari.mem_limit`) that caps a runaway from affecting the rest of the stack. Change it only if Tari
restarts repeatedly (raise it) or you need RAM for other apps (lower it), then run `./pithead apply`.

**Browser warns "your connection is not private."**
Expected with `dashboard.secure: true`: Caddy uses a self-signed certificate. Accept the warning
once. To use plain HTTP, set `dashboard.secure: false` and run `./pithead apply`.

**Workers don't show up in the dashboard.**
Check that each rig points at `YOUR_STACK_IP:3333` and that port `3333` is reachable from the
worker (firewall on the stack host?). See [Connecting Miners](workers.md).

**Hashrate reads zero or the chart is blank.**
Stats take about a minute to populate after a worker connects. Confirm the worker is hashing
(`./pithead logs xmrig-proxy`).

**P2Pool can't connect to a remote node.**
The node must be set up for mining: **ZMQ publishing enabled** (`zmq-pub`) and its RPC reachable
by P2Pool. Public "open node" endpoints don't qualify; use a node you run and control. See
[Configuration › Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node).

**HugePages shows as disabled / low.**
Persistent HugePages require a GRUB change and a **reboot**. Re-run `./pithead setup` (without
`--skip-optimize`) and reboot when prompted.

**The dashboard data looks broken and you want a clean slate.**
`./pithead reset-dashboard` wipes and recreates the dashboard and P2Pool data. This is
**destructive**: it drops P2Pool sidechain state and dashboard history (blockchains and wallets are
unaffected). Pass `-y` / `--yes` to skip the confirmation prompt.

---

## For developers

- **Run the test suites locally** (mirrors CI): `make test`, or individually `make
  test-dashboard`, `make test-stack`, `make test-compose`, `make lint`.
- **Dashboard development**: see [`build/dashboard/README.md`](../build/dashboard/README.md) for
  the package layout, local dev setup, and the hermetic test suite.
