# Operations & Maintenance

Command reference for `pithead`, the CLI that manages the stack. Run `./pithead help` for the same
list. The commands that only mean something on [the appliance image](appliance.md) are grouped
separately, [below](#appliance-only-commands).

## Command reference

| Command | Description |
|---|---|
| `./pithead setup` | First-time setup (interactive): dependency check, config, Tor provisioning, kernel optimization, and start. `--skip-optimize` skips kernel/GRUB tuning; `--skip-deps` skips the dependency check/install. |
| `./pithead apply` | Preview and apply `config.json` changes. Warns before disruptive ones and recreates only what changed. `-y` / `--yes` skips the prompt. |
| `./pithead up` | Start the stack. |
| `./pithead down` | Stop the stack. |
| `./pithead restart [tor]` | Restart the stack. `restart tor` restarts only the tor container so it picks fresh guards when Tor clearnet egress is stuck (#424) — every Tor circuit drops and rebuilds, mining onions included. See [Tor egress broken while mining works](#troubleshooting). |
| `./pithead upgrade` | Re-render the generated config, then **pull** (release bundle) or **rebuild** (source checkout) the images and restart. Run after downloading a newer bundle or a `git pull`. |
| `./pithead logs [service]` | Follow logs for all containers, or a single service (e.g. `logs p2pool`). |
| `./pithead status` | Show container status and health-check every expected service. Warns about anything down/unhealthy and exits non-zero if so (handy for cron/monitoring). Profile-aware, and treats a stopped `p2pool`/`xmrig-proxy` as intentional during a node-down failover or while the miner is held until the chains sync. |
| `./pithead doctor` | Read-only diagnostics: deps, Docker, AVX2, HugePages, RAM/disk, `.env`/onion state, and container status — plus runtime checks: the Tor container is actually running while the mining stack runs (a loud FAIL when it's down — the privacy backbone is dead), the Tor-egress firewall rules are actually installed (a reboot silently drops them while the containers auto-restart), something is listening on the stratum port (`p2pool.stratum_port`, default `3333`, and whether that port sits on a public IP), the dashboard app answers behind its container, and a clearnet request through Tor's SOCKS succeeds (a failing Tor guard breaks Healthchecks/Telegram/XvB while mining still works — fix with `./pithead restart tor`, or set `tor.auto_heal: true` to automate it). A paste-able health report. |
| `./pithead backup` | Save `config.json`, `.env`, `Caddyfile`, the Tor onion keys, and the dashboard's database (your hashrate history & settings) to a timestamped, passphrase-encrypted archive under `backups/` (checks free space first; stops a running stack for a clean copy, then restarts it). `--with-chains` also includes the blockchain data; `--no-encrypt` writes a plaintext `tar.gz`; `-y` / `--yes` skips the prompts (low free space and stopping the stack). |
| `./pithead restore <archive>` | Restore those files from a backup archive, encrypted or plaintext (asks before overwriting; fixes Tor key ownership). `-y` / `--yes` skips the prompt. |
| `./pithead reset-dashboard` | **DESTRUCTIVE**. Wipes and recreates the dashboard and P2Pool data. `-y` / `--yes` skips the prompt. |
| `./pithead rotate-secrets` | Regenerate the stack's internal credentials after a suspected leak: the local Monero RPC password, the stratum access-password (only when `p2pool.stratum_password` is `"auto"`), and the xmrig-proxy control-API token. Recreates the affected containers. `-y` / `--yes` skips the prompt. See [Rotating the internal secrets](#rotating-the-internal-secrets). |
| `./pithead onion-client-key` | Print the Tor client-auth line for the dashboard onion. This is the client *private* key, deliberately kept out of `status` — add it to your Tor client's `ClientOnionAuthDir`. See [Remote access over Tor](configuration.md#remote-access-over-tor-onion-service). |
| `./pithead rotate-dashboard-onion` | Mint a new dashboard onion address and client-auth keypair, retiring the old one. Run after a leaked address or key. |
| `./pithead control-run-pending` | Drain the dashboard's control-request spool once. Fired by the `pithead-control` systemd path unit; run it by hand only when debugging the control channel. See [Editing config from the dashboard](#editing-config-from-the-dashboard). |
| `./pithead render` | Regenerate every derived file (`.env`, the Caddyfile, service configs, host units) from `config.json` without touching containers. The appliance runs this every boot; run it by hand after replacing the program under an existing config. |
| `./pithead support-bundle` | Collect a `chmod 600` diagnostics tarball for a bug report: host facts, `doctor` in prose and JSON, a masked config, a redacted `.env`, and the last 200 log lines per container with launch-line credentials scrubbed. Read-only, and nothing leaves the box — review it, then share it. |
| `./pithead config-reset` | **DESTRUCTIVE**. Clear the configuration and reopen the setup wizard, keeping every data directory — chains, wallets, Tor onion keys and dashboard history all stay, so reconfiguring costs no resync. Type-to-confirm unless `-y` / `--yes`. |
| `./pithead uninstall` | **DESTRUCTIVE**. The clean exit: stops the stack, removes its containers and images, the rendered `.env` and Caddyfile, this checkout's control-runner units, and the egress firewall rules. Keeps what's yours — `config.json`, `backups/`, and the data dirs — and lists them for manual removal. Type-to-confirm unless `-y` / `--yes`. |
| `./pithead version` | Print the installed stack version on one line (also `-V` / `--version`). Offline; no update check. `doctor` repeats it in its header. |
| `./pithead help` | Show all commands. |

Service names for `logs` match the containers: `p2pool`, `xmrig-proxy`, `tor`, `dashboard`,
`docker-proxy`, `docker-control`, and `caddy` always; `monerod` only with `monero.mode: local`,
`tari` only with `tari.mode: local`, and `wallet-rpc` / `tari-wallet` only when the matching
`view_key` turns payout confirmation on. A service that isn't running has no logs to follow.

### Appliance-only commands

These exist on every install but only do something on [the appliance image](appliance.md), where the
boot path drives most of them for you:

| Command | Description |
|---|---|
| `./pithead os-update BUNDLE` | Install an OS update bundle into the spare A/B slot (`rauc install`). Refuses a bundle older than the running OS — a signed downgrade re-opens fixed holes — and refuses one below the `/data` migration floor outright. `--allow-downgrade` overrides the first, never the second. On a debug build (SSH baked in) installing a non-debug bundle, it warns first: that install removes the SSH channel you're driving it over. `-y` / `--yes` skips the prompt. |
| `./pithead factory-reset` | **DESTRUCTIVE**, appliance only. Erase the whole data partition back to a blank machine — chains, wallets, Tor keys and settings all go — then reboot into the setup wizard. The resync that follows costs days, so reach for `config-reset` first. Type-to-confirm unless `-y`. |
| `./pithead firstboot-wizard` | Browser-first setup for an unconfigured install: serves a token-gated form on `http://<this-host>/`, validates the answers host-side, then runs setup. A pre-seeded `config.json` skips the form; `--cli` runs the terminal wizard instead. The one-time token prints to the console, and five wrong tries mint a fresh one. |
| `./pithead load-images` | Load the baked container-image archives from `/opt/pithead/images` into the engine when their content changed since the last load. The boot path runs this every boot, so a reinstall or update that ships new images converges with no wizard involvement. |
| `./pithead local-miner` | Converge this machine's RigForge worker to what the machine is: on a coordinator it follows `local_miner.enabled` (RigForge setup in appliance mode when on, the miner stopped when off); on a rig it follows `rig.json`. Run every boot; a no-op outside the appliance. |
| `./pithead render-quadlet` | Render Podman Quadlet units — the appliance runtime — from a rendered `.env`. Defaults to `--env .env` and `--out ./quadlet`. The `os/quadlet/` fixtures pin its output byte for byte. |

### With a node running elsewhere

`monero.mode: remote` and `tari.mode: remote` leave that node's container out of the stack, and the
commands above follow suit:

- `logs` and `restart` have nothing to address for that node — its chain runs on the other host, so
  read its logs there.
- `doctor` drops it from every check it owns: its data directory leaves the disk budget, and its
  inbound onion reports "not needed" rather than missing.
- `status` is profile-aware, so a container that mode turned off is not reported as down.
- Switching a node between local and remote takes effect on `./pithead apply`. Going remote stops and
  removes that node's container first, so the switch can't leave the old one running against a config
  that no longer points at it. Going local mints the inbound onion that mode never provisioned.

### Chaining commands

Run several commands in one invocation — each step in order, left to right:

```bash
./pithead apply upgrade      # apply config changes, then upgrade
./pithead upgrade status     # upgrade, then health-check the result
```

Chainable commands: `apply`, `up`, `down`, `restart`, `upgrade`, `status`, `doctor`, `backup`.
The whole chain is validated before anything runs; a nonsense chain is rejected with nothing
executed. Rejected: a command that isn't chainable (`setup`, `logs`, `restore`,
`reset-dashboard`, and the info commands run alone), a duplicated command, more than one of
`up`/`down`/`restart` in the same chain (`up down` contradicts itself), and `down` anywhere but
last (the steps after it would act on a stopped stack).

A chain fails fast: the first step that exits non-zero stops it, pithead reports which step
failed and what did and didn't run, and the failing step's exit code becomes the chain's.
Flags don't chain — `apply -y upgrade` is a single `apply` invocation (and `apply` rejects the
stray argument), so run flagged commands separately.

### Tab completion

`pithead-completion.bash` (in the repo root and the release bundle) completes subcommands for
`./pithead <TAB>`, service names for `./pithead logs <TAB>`, and `tor` for
`./pithead restart <TAB>`.

bash — add to `~/.bashrc`:

```bash
source /path/to/pithead/pithead-completion.bash
```

zsh — add to `~/.zshrc` (`bashcompinit` needs `compinit` loaded first):

```zsh
autoload -U +X compinit && compinit
autoload -U +X bashcompinit && bashcompinit
source /path/to/pithead/pithead-completion.bash
```

Service-name completion reads `docker-compose.yml` next to the `pithead` you're completing, so
it works from any checkout or bundle directory.

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

**Preview without applying:** `./pithead apply --dry-run` prints the change rows and stops —
nothing is written or recreated. `--porcelain` makes the output machine-readable
(`FLAG<TAB>KEY<TAB>MESSAGE` per row); the dashboard control runner uses exactly this.

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

## Editing config from the dashboard

With `dashboard.control.enabled: true` (default off; needs a `dashboard.auth.password`), the
dashboard gains a [Configuration view](dashboard.md#configuration-view) that stages config changes
for a host-side runner. `apply` (and `setup`/`upgrade`) install two systemd units when the flag is
on, and remove them when it is off:

- `pithead-control.path` — watches `./data/control/requests/` for request files.
- `pithead-control.service` — a root oneshot running `pithead control-run-pending` from the
  install directory. Fixed command, no parameters from the container.

The unit names are global to the host, so removal is ownership-checked: a checkout with the flag
off only removes units whose `ExecStart` points at itself, comparing physical paths so the
`current` symlink and the versioned directory it targets count as the same checkout. Another
checkout on the same box (an e2e harness, a bundle smoke test) therefore cannot delete the live
stack's runner and strand its queued requests.

The runner dispatches a fixed set of actions and rejects everything else: `apply --dry-run
--porcelain` (preview), `apply -y` (commit), a release upgrade — the dashboard's
[Upgrade button](dashboard.md#upgrading-from-the-dashboard), for which the runner re-derives the
target from the GitHub release API itself and refuses any other version — the two worker actions
(`worker-apply`, `worker-upgrade`), which forward a config change or an upgrade to a rig's own
control API rather than touching this host, and the `restart` / `apply` lifecycle pair. An
unrecognized action is rejected and audited, never run.

The spool lives under `./data/control/`: `requests/` (the only directory the dashboard container
can write), `staged/` (host-only), and `results/` + `audit/` + `masked/` (container read-only).
`masked/config.json` is a host-rendered copy of the config with every set secret replaced by a
sentinel ([#440](https://github.com/p2pool-starter-stack/pithead/issues/440)); the Configuration
form prefills from it, and the raw `config.json` is never mounted into the container. It is
re-rendered on every `setup`/`apply`/`upgrade` and on every runner pass.
`audit/control.log` records one JSON line per handled request — timestamp, the logged-in dashboard
user, action, outcome, and the names of the changed settings (never their values) — and the
container cannot rewrite it. The writer trims the log to its newest 2000 entries once it passes
512 KiB, so it never grows unbounded.

To disable the channel, set `dashboard.control.enabled: false` and run `./pithead apply`: the
units are disabled and removed, the routes disappear from the dashboard (404), and the spool
directory is left in place. To inspect or drain the queue by hand, run
`./pithead control-run-pending`. A commit keeps the previous config at `config.json.bak-control`;
a failed apply names it in the result and retries container recreation on the next apply, same as
the CLI.

---

## Watching for intruders

Caddy writes a JSON access log — one line per dashboard request, with timestamp, HTTP status,
method, path, and the authenticated user — to `./data/caddy-logs/access.log`
([#349](https://github.com/p2pool-starter-stack/pithead/issues/349)). It is always on. Caddy
redacts credential headers by default, so no password material lands in it, and Caddy's native
rolling caps it at 4 MiB per file, the current file plus two rolled ones (~12 MiB worst case).
The dashboard's Configuration view surfaces the same data:
[recent accesses and a failed-login count](dashboard.md#access-log-and-recent-config-changes).

How to read it, given the dashboard is reachable over a Tor onion
([#343](https://github.com/p2pool-starter-stack/pithead/issues/343)): every request arrives via
the local Tor daemon, so there is **no source IP** to trace or block — the attack signal is the
rate and pattern of failures, not identity.

- **A burst of 401s** means someone who can already reach the dashboard — they have the onion
  address, and the client-auth key if `dashboard.onion.client_auth` is on (the default) — is
  guessing the password. Rotate it: set a new `dashboard.auth.password` in `config.json` and run
  `./pithead apply`.
- **Unexplained traffic on a client-auth-off onion** means the address itself has leaked (it is
  online-guessable in that mode). Rotate the address: `./pithead rotate-dashboard-onion` mints a
  fresh onion and client key; the old ones stop working immediately
  ([details](configuration.md#remote-access-over-tor-onion-service)).

Config tampering shows in the other log: `./data/control/audit/control.log` (above) names every
change staged through the dashboard and who committed it. A change you didn't make is the same
rotate-now signal. Secret rotation beyond the dashboard password is tracked in
[#378](https://github.com/p2pool-starter-stack/pithead/issues/378).

`control.log` only sees requests that went through the dashboard. The dashboard's own poll loop
additionally watches for two changes it did NOT make and appends them to the same audit trail
([#530](https://github.com/p2pool-starter-stack/pithead/issues/530),
[details](dashboard.md#catching-changes-made-outside-the-dashboard)): a `config.json` edit with no
matching commit (`host-edit`), and a worker's control API reporting a change the dashboard never
sent (`rig-edit`). Both name only what changed — settings or a worker, never a secret value — and
both are the same rotate-now signal as an unexplained `control.log` entry.

Unlike `control.log`, which the writer trims to bound its size, the audit trail served by the
dashboard persists to its own database — mirrored `control.log` rows plus the two out-of-band
kinds above — so the Security panel's range presets, date fields and search look back further than
the log's own trimmed window. Because `rig-edit` reads off the unauthenticated worker feed, it is rate-capped
per worker ([#724](https://github.com/p2pool-starter-stack/pithead/issues/724)): a rig reporting a
fresh change_id every poll can add only a bounded number of `rig-edit` rows per hour before the
rest are dropped behind a single `rate-limited` marker, so no one LAN device can grow the database
without limit. A genuine occasional rig change still records normally; only a flood is capped, and
the cap is visible — the marker names it, and the dashboard logs a warning.

---

## Archiving the XvB winners feed

`scripts/xvb-winners-archive.sh` saves a dated snapshot of the public XvB winners feed
(`https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt`) — the full round schedule with
per-round prize hashrates and qualifier counts — before the feed's ~45-day rolling window drops
the oldest rounds. The fetch runs inside the dashboard container, so it rides the stack's Tor
SOCKS like every other XvB call; the feed is public and carries no wallet. The stack must be
running.

This is optional. The reason to run it: the dashboard's XvB earnings estimate rests on a
measured delivery band — the fraction of the advertised prize that actually arrives on-chain,
measured once in the [XvB delivery study](research/xvb-delivery-study/README.md) (Jun–Aug 2026:
point 0.33, 95% CI 0.28–0.39). XvB can change its payout behaviour at any time, and the winners
feed is the raw material for re-running that measurement; without an archive, anything older
than ~45 days is gone.

Run it daily from cron on the deploy box, and give it an archive directory **outside** the
version directories:

```
10 0 * * * $HOME/mining/current/scripts/xvb-winners-archive.sh $HOME/mining/xvb-winners-archive
```

Snapshots land there as `winners-YYYYMMDD.txt` (UTC date). The directory argument matters:
without it the script defaults to `xvb-winners-archive/` inside the stack directory, and the
deploy layout above rotates old version directories away on upgrade — taking any archive
inside them along. The explicit directory survives every upgrade. Each snapshot is ~90 KB,
so a daily archive grows about 3 MB a month.

---

## Updating the stack

The update path depends on how you installed (see [Getting Started](getting-started.md#2-get-the-code)).

**From the dashboard:** with `dashboard.control.enabled: true`, a release install can run this
whole sequence from the browser — see
[Dashboard › Upgrading from the dashboard](dashboard.md#upgrading-from-the-dashboard). The steps
below are what that button performs, and the only path for source checkouts.

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

On a release install with the release public key on disk (`cosign.pub`, shipped in every signed
bundle), `upgrade` verifies each image's cosign signature before pulling and aborts on any failure —
including when the `cosign` binary itself is missing. Install cosign once and the check runs on
every upgrade; see [Releasing › Verifying a release](dev/releasing.md#verifying-a-release).

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

## The deploy-box layout

A box that installs each release into its own directory keeps code and data apart. This is the
canonical layout — one parent directory holds the version dirs, a `current` symlink, and a shared
data root:

```
~/mining/
├── current -> pithead-v1.5.0      # the live install — maintained by setup/upgrade
├── pithead-v1.5.0/                # code + config.json + generated config (.env, Caddyfile)
├── pithead-v1.4.0/                # ONE previous version dir, kept for rollback
└── data/                          # shared data root — survives every upgrade
    ├── monero/  tari/  p2pool/  tor/
    └── dashboard/                 # the dashboard database lives here too (see below)
```

- **`current`** — `./pithead setup` and `./pithead upgrade` update it (`ln -sfn`) whenever the
  install directory is named `pithead-vX.Y.Z`; the dashboard's one-click upgrade runs the same
  `upgrade` and moves it too. Only a *successful* upgrade moves the pointer, so `current` always
  names the version that last came up. It is informational — the containers mount the absolute
  paths in `.env` — but it makes the live install discoverable without `docker inspect`. Any
  other directory name (a source checkout, a plain `pithead/` extract) leaves the symlink alone.
- **Version dirs** — keep `current`'s target plus one older dir for rollback; delete anything
  older. Each release lands in a fresh dir: extract the bundle, copy `config.json` and `.env`
  from the previous dir, run `./pithead upgrade`. Rollback is the same two steps from the older
  dir. The single-directory overlay under [Updating the stack](#updating-the-stack) also works;
  the per-version layout is what a long-lived box converges to. The dashboard's one-click
  upgrade follows the same discipline on this layout: it extracts the new release into a fresh
  `pithead-v<new>/` beside the running one, seeds `config.json`, `.env`, and the control spool,
  and leaves the previous dir intact for rollback. Only when a data directory resolves *inside*
  the install dir (the pre-shared-root default) does it extract in place instead — a dir swap
  would strand that data — and says so in the journal.
- **Shared data root** — point `monero.data_dir`, `tari.data_dir`, `p2pool.data_dir`, and
  `tor.data_dir` at absolute paths under one parent (here `~/mining/data`). When all four share
  a parent, the dashboard database defaults there as well (`<root>/dashboard`) instead of inside
  the version dir — no data moves with the code. Installs that pre-date this carry the dashboard
  data at the old in-install default (`./data/dashboard`); the first `upgrade` (or `apply`)
  moves it to the shared root automatically, stops the dashboard for the move, and verifies the
  database arrived. An explicit `dashboard.data_dir` is never touched — a warning names the
  leftover instead — and data at *both* locations stops the run rather than guessing which
  database is live.
- **Config archives** — `./pithead backup` writes under `backups/` inside the dir that ran it.
  Before deleting an old version dir, keep any `backups/` archives you still want.

---

## Backups

State lives in the data directories (by default under `./data/`, or wherever each `*.data_dir`
points; see [Configuration › Data directories](configuration.md#data-directories)):

- **`config.json`**: settings. `chmod 600`; keep a copy off-host.
- **`config.json.bak-upgrade-*` / `.env.bak-upgrade-*`**: pre-upgrade copies the dashboard's
  one-click upgrade keeps before an in-place extraction
  ([#637](https://github.com/p2pool-starter-stack/pithead/issues/637)). The newest three pairs
  are kept; older ones are pruned automatically. The `.env` copies carry secrets — handle them
  like `.env` itself.
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

This prompts for a passphrase, then writes a timestamped, encrypted `tar.gz.enc` under `backups/`
holding the irreplaceable state: `config.json`, `.env` (secrets), the `Caddyfile` (if present), the
Tor onion keys, and the dashboard database (hashrate history and settings). Blockchains are
excluded (they re-sync), so the archive is small. The archive is `chmod 600`, and `pithead` prints
its path when done. Before writing, `backup` checks free space and prompts if it looks tight. On a
source checkout, `backups/` is git-ignored — the archive carries `.env` and the onion private keys,
and secret scanners can't see inside a tarball.

Encryption is `openssl enc -aes-256-cbc -pbkdf2` with 600,000 PBKDF2 iterations (`openssl` is
already a stack dependency; AEAD modes like GCM are not available through `openssl enc`, so CBC is
the portable choice). The tar stream pipes straight into `openssl` — no plaintext archive ever
touches the disk — and the passphrase passes over a file descriptor, never the command line.
`chmod 600` protects the archive on this disk only; the encryption is what protects it once it is
copied off-box. The archive is unreadable without the passphrase, onion keys included, so store the
passphrase somewhere other than this host.

Losing the passphrase loses the backup — there is no recovery!

For unattended runs (cron), set `PITHEAD_BACKUP_PASSPHRASE` in the environment. An unattended run
(`--yes`) with no passphrase set **refuses** rather than downgrading — a job whose passphrase line
is typo'd away must fail loudly, not archive your onion keys in plaintext while reporting success.
To write a plaintext archive on purpose, pass `--no-encrypt` (an empty passphrase at the interactive
prompt does the same, with a warning).

If the stack is running, `backup` stops it for a consistent copy and restarts it when done. A
failed backup (disk full mid-archive, for example) removes the partial archive and still restarts
the stack before reporting the error. Pass `-y` / `--yes` to skip both prompts (low-space warning,
stop-the-stack question).

Include the blockchains (larger, slower) with:

```bash
./pithead backup --with-chains   # also include the blockchain data
```

To recover (on a new machine, or after a wipe) copy the archive back and run:

```bash
./pithead down                       # stop the stack first so files restore cleanly
./pithead restore backups/pithead-backup-YYYYmmdd-HHMMSS.tar.gz.enc
./pithead up
```

`restore` detects the format from the archive itself — encrypted backups ask for the passphrase
(or read `PITHEAD_BACKUP_PASSPHRASE`), and plaintext archives from earlier releases restore
unchanged, no flag needed. A wrong passphrase, or a corrupt or truncated archive of either format,
fails before anything on disk is touched. `restore`
prompts before overwriting anything (pass `-y` / `--yes` to skip). It puts the files back, fixes
Tor key ownership so the onion address returns unchanged, and restores hashrate history and
dashboard settings.

> NOTE: The archive stores the source box's absolute paths, and `restore` puts every file back
> exactly where it came from. On a machine laid out differently (another user, another install
> directory), the files land in the old box's directory tree — not the install you ran `restore`
> from. Recreate the original path (or move the install there) before restoring.

> NOTE: After a restore, Caddy regenerates the dashboard's HTTPS certificate, so the browser shows
> its "not trusted" warning once. Accept it as on first setup.

---

## Rotating the internal secrets

`.env` and `config.json` carry three credentials that are generated once and otherwise live
forever. If either file may have leaked — a backup left the box, a `.env` was pasted into a bug
report, an operator with access left — rotate them:

```bash
./pithead rotate-secrets
```

The command previews exactly what your config rotates, asks for confirmation (`-y` / `--yes`
skips it), regenerates the secrets, re-renders `.env`, and recreates the containers that consume
them (a brief restart; chain data and dashboard history are untouched):

- **Monero node RPC password** (`monero.node_password`) — rotated in local mode only; internal to
  the stack, no follow-up needed. With `monero.mode: "remote"` the credential belongs to the
  remote node and is skipped.
- **Stratum access-password** (`PROXY_STRATUM_PASSWORD`) — rotated only when
  `p2pool.stratum_password` is `"auto"`. The new value is printed at the end. Every rig is
  rejected until its stratum `pass` is updated to it — see
  [Workers › Authentication](workers.md#authentication). A literal password lives in
  `config.json`: change it there and run `./pithead apply`. When stratum auth is off there is
  nothing to rotate.
- **xmrig-proxy control-API token** (`PROXY_AUTH_TOKEN`) — always rotated; internal to the stack,
  no follow-up needed.

Before changing anything, `rotate-secrets` saves owner-only copies of `config.json` and `.env` as
`config.json.bak-<timestamp>` and `.env.bak-<timestamp>`. They hold the OLD secrets: delete them
once the stack is confirmed healthy. If the container recreate fails, the new values are already
committed — fix the cause and run `./pithead apply` to retry the recreate, or restore the two
copies and run `./pithead apply` to roll back.

The dashboard's `.onion` address and client-auth key have their own command,
`./pithead rotate-dashboard-onion` — see
[Configuration › Remote access over Tor](configuration.md#remote-access-over-tor-onion-service).

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
This covers the bundled node only: with `tari.mode: remote` no Tari container runs here, the limit
is never applied, and that node's memory is the business of the host running it.

**Browser warns "your connection is not private."**
Expected with `dashboard.secure: true`: Caddy uses a self-signed certificate. Accept the warning
once. To use plain HTTP, set `dashboard.secure: false` and run `./pithead apply`.

**Workers don't show up in the dashboard.**
Check that each rig points at `YOUR_STACK_IP:3333` and that port `3333` is reachable from the
worker (firewall on the stack host?). See [Connecting Miners](workers.md).

**Hashrate reads zero or the chart is blank.**
Stats take about a minute to populate after a worker connects. Confirm the worker is hashing
(`./pithead logs xmrig-proxy`).

**P2Pool can't connect to a remote Monero node.**
The node must be set up for mining: **ZMQ publishing enabled** (`zmq-pub`) and its RPC reachable
by P2Pool. Public "open node" endpoints don't qualify; use a node you run and control. It also has
to sit in a private range — the Tor-egress firewall drops the dial otherwise. See
[Configuration › Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node).

**Tari isn't merge-mining against a remote node.**
The base node must publish its gRPC where this stack can reach it: a stock Minotari node binds
`18142` to localhost only. If that node is another Pithead stack, the switch is
`tari.grpc_lan_access: true` on it. Check `./pithead logs p2pool` for the merge-mine bridge line —
with Tor on, p2pool bridges the gRPC through loopback `socat` to keep it off the SOCKS proxy, so a
failure shows up there rather than as a Tor error. Same private-range requirement as Monero. See
[Configuration › Remote Tari node](configuration.md#remote-tari-node).

**HugePages shows as disabled / low.**
Persistent HugePages require a GRUB change and a **reboot**. Re-run `./pithead setup` (without
`--skip-optimize`) and reboot when prompted.

**Tor egress broken while mining works.**
Healthchecks reports the host down and Telegram commands go quiet, yet workers keep hashing.
Tor can bootstrap to 100% and then sit on a **failing guard**: new circuits time out, so every
feature that exits Tor to the clearnet — Healthchecks pings, the Telegram bot, XvB stats — breaks
at once, while mining rides established onion circuits and keeps working. `./pithead doctor`
confirms it: the Tor clearnet-egress check WARNs while everything else reads healthy. Fix:

```bash
./pithead restart tor
```

The restart makes Tor reselect guards; all Tor circuits drop and rebuild (p2pool/monerod re-peer
on their own within minutes). Re-run `./pithead doctor` to confirm egress recovered. To have the
stack do this itself, set `tor.auto_heal: true` in `config.json` and run `./pithead apply`: the
dashboard then probes Tor clearnet egress every 5 minutes and restarts tor once egress has been
broken for 15 minutes — at most 3 restarts per outage, 30 minutes apart, each logged and followed
by a Telegram note once the path is back. If the Tor network itself is overloaded, it stops
restarting and keeps warning instead. Off by default: a tor restart drops every circuit, so the
stack does not restart its privacy boundary unbidden. (#424)

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
