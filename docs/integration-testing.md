# Integration Testing

This suite validates Pithead end-to-end against a real Ubuntu server running full Monero and
full Tari nodes. It is the runtime/integration half of testing and the blocking pre-release
gate described in [Releasing](releasing.md) (issue
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

The other suites are client-side and never touch a daemon: the `pithead` shell tests stub out
`docker`/`sudo`, the compose test only checks `docker compose config` interpolation, and the
dashboard pytest mocks its clients. They prove the code is correct. They can't prove that a
real `apply → sync-gate → mine → status` flow works on a real host. This suite proves that.

> This live matrix is tier 4 of a four-tier plan. The runtime situations a healthy box can't
> show (cold sync, node-down, unhealthy containers, XvB tiers) are simulated more cheaply at
> lower tiers: unit tests, a client contract test against controllable fakes
> ([`tests/integration/fakes/`](../tests/integration/fakes/)), and a fake-daemon docker
> mini-stack ([`tests/integration/mini-stack/`](../tests/integration/mini-stack/)). See
> [Testing Strategy](testing-strategy.md) for the full picture and scenario catalog.

The suite lives under [`tests/integration/`](../tests/integration/):

| File | Role |
|---|---|
| `run.sh` | Entry point. Connects to the box (SSH or `--local`), iterates the config matrix, asserts, captures artifacts, restores. |
| `scenarios.sh` | The declarative config matrix. Adding a case is a one-line data edit. |
| `lib.sh` | Shared helpers: target I/O (SSH/local), assertions, readiness waiters, config rendering, secret redaction. |
| `selftest.sh` | Pure-logic self-test (no server). Runs in CI on every PR. |

---

## How it works

The suite assumes the box is already deployed and synced with miners connected. A dedicated test
server syncs the full Monero and Tari nodes once and reuses them, so each scenario runs in minutes
instead of waiting days for a chain sync.

Given that, the harness moves between matrix scenarios with non-interactive `pithead apply -y`,
which:

- recreates only the containers whose resolved config changed,
- reuses the synced chain data dirs (it never re-syncs, never re-provisions Tor), and
- preserves secrets (`PROXY_AUTH_TOKEN`, onion addresses).

For each scenario it writes a `config.json`, applies it, then waits on real readiness signals
(container health, `pithead status`, dashboard sync %, miner-released) with timeouts. Never a
fixed `sleep`. It then runs the assertion battery below. All reads happen on the box
(`pithead status`/`doctor` and `curl http://127.0.0.1:8000/api/state`), so SSH and `--local`
behave identically and never depend on resolving the box's dashboard hostname.

Before the first scenario it snapshots the box's original `config.json` and a fingerprint of
its secrets. After the run it restores the original config and re-applies (unless `--keep`).

### Safety model

The test box holds real synced nodes and real keys. Treat it as production-sensitive.

- Never mutates the canonical chains. The harness only ever writes `config.json` and lets
  `apply` recreate containers. It does not `rm -rf` data dirs. The destructive `monero.prune`
  axis (a pruned vs. full DB are different on disk) is only exercised against a separate
  synced data dir you pass with `--pruned-data-dir` / `--full-data-dir`. Without it the case
  is reported `SKIPPED`, never run against the canonical DB.
- No silent coverage drops. Any scenario whose prerequisite is missing (an alt data dir, a
  remote endpoint) is logged as `SKIPPED` with the reason. It never quietly disappears.
- Secrets hygiene. RPC creds, the proxy token, and onion addresses are never printed.
  Secret-preservation is checked by hashing them on the box (`sha256sum`) and comparing the
  hash, so the plaintext never crosses the wire. All captured artifacts pass through a
  redactor.
- Continue-on-error. A failing assertion doesn't abort the run. The whole matrix is collected
  and summarized, with per-scenario artifacts for the failures.

---

## Provisioning the test box

A one-time setup. Target the Ubuntu LTS releases the stack supports (22.04 / 24.04).

1. Install and deploy Pithead normally (see [Getting Started](getting-started.md)) and let it
   fully sync. You want the box in steady state: all containers healthy, Monero + Tari synced,
   and at least one miner (ideally two) connected and submitting shares.
2. Reusable synced data. The synced `monero.data_dir` and `tari.data_dir` are reused across
   every scenario. The same synced full monerod is also what the `remote` scenario points at as
   an external node (see `--remote-monero-host`).
3. Tools on the box: `jq`, `curl`, `docker` (with compose v2), and `sha256sum`. The first three
   are already Pithead prerequisites; `sha256sum` ships with coreutils.
4. Access. Key-based SSH from wherever you run the suite, or run it on the box with `--local`.
   If Docker needs root there, use `--pithead "sudo ./pithead"`.
5. Optional: a second synced data dir for the opposite prune mode if you want to cover both
   pruned and full in one run. See the prune axis above.

> NOTE: Keep the box least-privilege and network-isolated; it holds real keys. This is a
> self-hosted/manual gate, not something to run on public CI.

---

## Running it

```bash
# Non-destructive health check first (recommended): no config changes, no apply
tests/integration/run.sh --host miner@10.0.0.5 --dir pithead --check

# Whole matrix over SSH
make test-integration ARGS="--host miner@10.0.0.5 --dir pithead"

# …or directly
tests/integration/run.sh --host miner@10.0.0.5 --dir pithead

# On the box itself, plus the lifecycle + node-down failover phase
tests/integration/run.sh --local --dir /home/miner/pithead --lifecycle

# A single scenario (see --list for names)
tests/integration/run.sh --host miner@10.0.0.5 --scenario remote-main-secure-tari \
    --remote-monero-host 10.0.0.5:18081

# Cover the OPPOSITE prune mode. The box mines one mode against its live chain; the other is
# skipped unless you supply a chain for it (it's otherwise covered by the fake mini-stack). A
# pruned box supplies a full chain; a full box supplies a pruned one (build one with
# tests/integration/build-pruned-chain.sh). See docs/release-server.md → prune-axis recipe.
tests/integration/run.sh --host miner@10.0.0.5 --full-data-dir /srv/monero-full
```

Useful flags (full list in `run.sh --help`):

| Flag | Purpose |
|---|---|
| `--host <user@host>` / `--local` | Drive the box over SSH, or a stack on this machine. |
| `--dir <path>` | The Pithead stack directory on the box, relative to the SSH login dir or absolute (default `pithead`). Avoid a literal `~`; your local shell expands it before the box sees it. |
| `--pithead <cmd>` | How to invoke pithead there (e.g. `"sudo ./pithead"`). |
| `--check` | Non-destructive: assert the box's current live state only. No config change, no apply, no restore. The safe first run / ongoing health check. Also runs `pithead doctor` (exit 0 + the [#383](https://github.com/p2pool-starter-stack/pithead/issues/383) runtime verdicts), fetches `/metrics` through Caddy ([#379](https://github.com/p2pool-starter-stack/pithead/issues/379); if a dashboard login is set, export `IT_DASHBOARD_PASSWORD` or the fetch skips), and asserts the share-health series is populated ([#116](https://github.com/p2pool-starter-stack/pithead/issues/116)). |
| `--readiness` | Non-destructive: assess whether the box is fit to be a release/validation server (synced chains reusable, snapshot-capable FS, disk headroom, secrets owner-only, dashboard localhost-only). See [Release Server](release-server.md). |
| `--scenario <name>` | Run just one scenario. |
| `--workers <n>` | Miners expected online while mining (default `2`). |
| `--remote-monero-host <h>` | External node endpoint for the `remote` scenario. |
| `--pruned-data-dir` / `--full-data-dir` | Synced alt DB to enable the opposite prune mode. |
| `--lifecycle` | Also run the lifecycle phase (restart, apply secret-preservation). |
| `--fault-injection` | Also break monerod (stop / SIGSTOP / remove) and assert `status`' down/unhealthy/missing verdicts and the failover→recovery cycle, plus a dashboard DB-write fault (data dir made read-only → `/api/state` reports `db_healthy:false` → write access restored, [#202](https://github.com/p2pool-starter-stack/pithead/issues/202)). Destructive-then-restored; local mode only; slow. |
| `--auth-fail-closed` | Also empty `PROXY_AUTH_TOKEN` in `.env` and assert `pithead up` refuses to start (the live counterpart to the tier-1 compose-config check, [#153](https://github.com/p2pool-starter-stack/pithead/issues/153)/[#203](https://github.com/p2pool-starter-stack/pithead/issues/203)), then restore the exact token and recover. Destructive-then-restored; ssh or local mode. |
| `--rigforge-control` | Also drive the RigForge WRITE paths against a real rig with `dashboard.control` on and the rig pinned in `workers.list[]` (#506; a baseline that still carries the deprecated `dashboard.workers[]` fallback is left as-is, so that shape stays exercised too): the enriched read survives a populated masked-token descriptor ([#514](https://github.com/p2pool-starter-stack/pithead/issues/514)), the rig is editable and a reversible Worker Inspect edit lands on it ([#508](https://github.com/p2pool-starter-stack/pithead/issues/508)/[#513](https://github.com/p2pool-starter-stack/pithead/issues/513)), a rig-side edit reflects back in the feed + masked prefill ([#516](https://github.com/p2pool-starter-stack/pithead/issues/516)), and an auto-rollback is recorded end-to-end ([#517](https://github.com/p2pool-starter-stack/pithead/issues/517)). Destructive-then-restored; local mode only; each leg self-skips without its prerequisites (see below). |
| `--rig-host <h>` / `--rig-control-port <p>` | The borrowed rig's LAN host and writable control API port (default `8082`), used to inject a `workers.list[]` descriptor when the box's baseline lacks one ([#185](https://github.com/p2pool-starter-stack/pithead/issues/185)/#506). Pair with `IT_RIG_TOKEN` (env; never a flag). |
| `--subnet` | Also bring the stack down then up on a non-default `network.subnet` (`10.84.0.0/24`) and assert the moved prefix reached `.env`, the docker bridge, Tor's render-at-start IP, monerod's proxy IP, the dashboard SSRF CIDR, and the [#344](https://github.com/p2pool-starter-stack/pithead/issues/344) onion vhost, then run the standard battery ([#201](https://github.com/p2pool-starter-stack/pithead/issues/201)/[#180](https://github.com/p2pool-starter-stack/pithead/issues/180)). Destructive-then-restored; local mode only. |
| `--safety-backup` | Take a `pithead backup` before the destructive scenarios and auto-roll-back (down → restore → up) if anything fails; the archive is removed on success. Recommended for the destructive matrix on a precious box; also exercises backup/restore end-to-end. |
| `--keep` | Don't restore the original config (leave the box on the last scenario). |
| `--out <dir>` | Where to write the manifest and failure artifacts. |
| `--list` | Print the matrix and axis coverage and exit. |

The runner exits non-zero if any assertion failed.

---

## One-command branch e2e (`e2e.sh`)

`run.sh` assumes a stack is already deployed on the box. [`tests/integration/e2e.sh`](../tests/integration/e2e.sh)
is the wrapper that does the whole thing for a branch against the live test bench in one command:
deploy, borrow a real miner, run the matrix, and put everything back.

```bash
tests/integration/e2e.sh <branch> [--mode targeted|check|matrix] [--workers N] [--miner HOST]
tests/integration/e2e.sh claude/my-feature                 # default: LEAN — dashboard + sync logic
tests/integration/e2e.sh claude/my-feature --mode check    # non-destructive smoke (pure reads)
tests/integration/e2e.sh claude/my-feature --mode matrix   # full config sweep (opt-in, pre-release)
```

What it does, then reverses on exit (even on failure / Ctrl-C, via an `EXIT` trap):

1. Dedicated checkout. Provisions `/srv/code/pithead-e2e` (clone-once, then `git fetch`) and checks
   out `<branch>` there. The checkout is disposable, so provisioning forces a pristine tree
   (`checkout -f` + `reset --hard` + `clean -fdx`) — a leftover untracked file from an earlier run
   can't abort the checkout. `clean` keeps the harness's `results/` and the seeded `config.json`/
   `.env`/`data/`/`backups/` (all gitignored). The canonical `/srv/code/pithead` is the baseline and
   is never git-touched. Because the Compose project name is pinned to `pithead`, the two checkouts
   drive the same containers and the same shared chains. They're two code copies of one stack, run one
   at a time, so borrow→test→restore is a fast code/image swap, never a re-sync.
2. Seeds the e2e checkout with the canonical `config.json`/`.env` (same wallet, secrets, onion keys,
   and shared `monero/tari/p2pool` data dirs), so only the branch's code differs.
3. Safety backup (`pithead backup`) as the rollback anchor.
4. Borrows a miner (default the configured miner): backs up its xmrig config and repoints it at the
   bench so the matrix has a real worker mining through this stack (1 worker → run with `--workers 1`).
5. Deploys the branch (`pithead apply` builds the branch's images) and runs `run.sh` detached on the
   box (survives an SSH drop on a long matrix), streaming a heartbeat and the full log at the end.
6. Restores the miner's original pool config and the baseline stack. Restore targets the directory
   the live stack actually ran from — read at preflight off the running container's
   `com.docker.compose.project.working_dir` label — which on a release box is the per-version bundle
   dir, not `CANONICAL_DIR`. That keeps the restore from handing the `pithead` project locally-built
   `:dev` images. If the label can't be read (stack down), it falls back to `CANONICAL_DIR`; override
   with `CANONICAL_DIR=<dir>`. The synced chains are never touched (asserted post-restore).

`--mode`: `targeted` (default, lean) validates the dashboard and the sync logic against the
already-synced node: `check` + `--lifecycle` (one controlled restart exercises the sync gate /
node-down failover) + `--auth-fail-closed`. No full config sweep, and never a re-sync. Container
restarts reload the existing chain and re-confirm the tip in seconds. `check` is pure reads only.
`matrix` is the opt-in full destructive config sweep (lifecycle + fault-injection + auth-fail-closed +
hardening + `--subnet`, plus `--rigforge-control` when a rig is borrowed, all under `--safety-backup`
auto-rollback) for a pre-release tier-4 gate. `--keep` leaves it deployed for
inspection (skips the restore). Requires SSH access to the test bench and the miner; see the
[testbench README](../tests/integration/testbench-README.md).

---

## The config matrix

Every axis below changes a real runtime path. The matrix covers the realistic combinations and
guarantees every value of every axis is exercised at least once (the `selftest` enforces this,
and `--list` prints it).

| Axis | Values | What it exercises |
|---|---|---|
| `monero.mode` | `local` / `remote` | profile gating, RPC wiring, `status` ignoring monerod in remote mode |
| `monero.prune` | `true` (pruned) / `false` (full) | pruned vs. full display ([#32](https://github.com/p2pool-starter-stack/pithead/issues/32)), DB size |
| `monero.rpc_lan_access` | `false` (127.0.0.1) / `true` (LAN) | RPC bind address, security posture |
| `p2pool.pool` | `main` / `mini` / `nano` | `P2POOL_FLAGS`, sidechain selection |
| `xvb.enabled` | `true` / `false` | XvB tunnel/donor wiring |
| `dashboard.secure` | `true` (Caddy TLS) / `false` | Caddy config / scheme |
| `dashboard.tari_required` | `true` (blocking) / `false` | sync-gate behavior ([#35](https://github.com/p2pool-starter-stack/pithead/issues/35)/[#51](https://github.com/p2pool-starter-stack/pithead/issues/51)) |
| `network.subnet` | default `172.28.0.0/24` / a moved `/24` | the docker bridge prefix every static IP, Tor's rendered torrc, monerod's proxy IP, and the SSRF CIDR key off ([#180](https://github.com/p2pool-starter-stack/pithead/issues/180)/[#201](https://github.com/p2pool-starter-stack/pithead/issues/201)) — runs via `--subnet` (a move needs a full down/up, not a hot apply) |

### What each scenario asserts

- Expected containers up, unexpected absent. Every service for that config is running and
  healthy; in `remote` mode there is no `monerod`.
- `pithead status` exit code: `0` for a healthy config.
- Dashboard reads live state. `/api/state` is reachable; Monero is synced (`done`); pruned/full
  display matches `monero.prune` ([#32](https://github.com/p2pool-starter-stack/pithead/issues/32)); the sidechain `pool.type` matches `p2pool.pool`.
- End-to-end mining. Workers are online (`proxy_workers >= --workers`), stratum has connections,
  and total hashes are accumulating ([#28](https://github.com/p2pool-starter-stack/pithead/issues/28)).
- Posture propagated. `MONERO_RPC_BIND`, `DASHBOARD_SECURE`, `XVB_ENABLED`, and `TARI_REQUIRED`
  in `.env` match the config; the Caddyfile uses the right scheme.
- Idempotency. A second `apply -y` with no change is a clean no-op.
- Secrets preserved. The proxy token and onion addresses are unchanged across every apply.

### Lifecycle + failover (`--lifecycle`)

For one representative config:

- `restart` brings the stack back healthy (`status` → `0`).
- An `apply` that changes the sidechain recreates only the affected containers and preserves
  secrets; the dashboard reflects the new pool; then it's reverted.
- Node-down failover ([#31](https://github.com/p2pool-starter-stack/pithead/issues/31)):
  stop `monerod` → `status` returns non-zero (node down) and the dashboard rejects workers
  (stops `xmrig-proxy`) → start `monerod` → workers readmitted → `status` → `0`.

> NOTE: `upgrade` (which rebuilds/pulls images) is intentionally not run unattended. It's slow
> and changes the bundle under test. Validate it as part of the [release](releasing.md)
> staging smoke test instead.

### RigForge control (`--rigforge-control`)

The dashboard↔RigForge WRITE surfaces that only a real rig with its `:8082` control API opted in
can prove — the tier-2 fake covers the `:8081` read only. It enables `dashboard.control`, pins the
borrowed rig in `workers.list[]` (#506; its token seen inside the container only as the
`{"__secret__": true}` sentinel, [#440](https://github.com/p2pool-starter-stack/pithead/issues/440)
— a baseline that still carries the deprecated `dashboard.workers[]` fallback is left as-is rather
than force-migrated, so that shape stays exercised too), and drives four legs, each self-skipping
loudly without its prerequisite:

- Read with a populated masked descriptor ([#514](https://github.com/p2pool-starter-stack/pithead/issues/514)):
  `api_ok` and the enriched feed still resolve — the guard for the v1.5.2 regression, where the
  masked sentinel was stringified into the `Bearer` header and every `:8081` probe returned 401.
- Editable + reversible edit ([#508](https://github.com/p2pool-starter-stack/pithead/issues/508)/[#513](https://github.com/p2pool-starter-stack/pithead/issues/513)):
  Worker Inspect reports the rig `editable`, and a `max_temp_c` nudge applied via
  `/api/control/worker-apply` lands on the rig's `/status` and is recorded in the per-worker
  history, then reverted.
- Rig-side edit reflects ([#516](https://github.com/p2pool-starter-stack/pithead/issues/516)):
  a change made straight on the rig's control API shows up in the dashboard's enriched feed, and a
  `config.json` hand-edit shows up in the masked prefill (with the token still masked).
- Auto-rollback ([#517](https://github.com/p2pool-starter-stack/pithead/issues/517), rigforge#236):
  a change the rig rolls back is recorded as `rolled_back` in the worker-apply result and history.

Prerequisites: a real RigForge rig connected (self-skips otherwise); `--rig-host` + `IT_RIG_TOKEN`
to inject a descriptor when the baseline lacks one, and to dial the rig directly for the #516 feed
leg; `IT_RIG_ROLLBACK_CHANGES` (a writable-key `changes` object the rig's fault-injection reverts)
for the #517 leg.

### Moved subnet (`--subnet`)

A `network.subnet` move can't be hot-applied — Compose won't recreate the bridge's IPAM subnet while
containers are attached — so this phase does a full down → up on `10.84.0.0/24` (the chains are
bind-mounted by path, never on the docker network, so they are untouched), asserts the moved prefix
reached the live `.env`, the docker bridge, Tor's rendered torrc, monerod's envsubst'd proxy IP, the
dashboard's SSRF CIDR + Tor SOCKS, `P2POOL_URL`, and the [#344](https://github.com/p2pool-starter-stack/pithead/issues/344)
onion vhost gateway, runs the standard running-state battery, then brings the box back to its
baseline subnet. The matrix carries a `local-pruned-main-subnet` row for axis bookkeeping; the
hot-apply loop skips it (a subnet move isn't a hot apply) and this phase runs it for real.

---

## Artifacts & triage

Each run writes a manifest (`results/manifest.txt`) recording exactly what was under test: the
stack `VERSION`, git revision, and `docker compose images`. A run is reproducible.

On a scenario failure, the harness captures (redacted) to `results/<scenario>/`:
`compose-ps.txt`, `status.txt`, `doctor.txt`, `config.json`, `env.redacted.txt`,
`api-state.json`, and `logs.txt` (last 200 lines per service). The end-of-run summary lists
each failed assertion and points at these.

---

## The self-test (CI)

`tests/integration/selftest.sh` exercises the harness's pure logic with no server: config
rendering and value typing, expectation derivation (profile gating), secret redaction, the
SSH/local exec wrapper, JSON parsing, and matrix axis coverage. It runs in CI on every PR (the
`shell` job) and via `make test-integration-selftest`, so the harness itself is held to the
same lint/test standard as the rest of the stack.

---

## Release gate (#44)

The live matrix is the required, blocking pre-release gate: a release is not promoted or
published unless it's green against the real Monero + Tari nodes. It's surfaced as `make
test-integration` and wired into the `make release` pipeline's test gate. See
[Releasing › Pre-release gate](releasing.md#pre-release-gate-54). The version tagged/published
is the exact bundle this run validated.
