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
> ([`tests/integration/fakes/`](../../tests/integration/fakes/)), and a fake-daemon docker
> mini-stack ([`tests/integration/mini-stack/`](../../tests/integration/mini-stack/)). See
> [Testing Strategy](testing-strategy.md) for the full picture and scenario catalog.

The suite lives under [`tests/integration/`](../../tests/integration/):

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
- Secrets hygiene. Secret-preservation is checked by hashing on the box (`sha256sum`) and
  comparing the hash, so the plaintext never crosses the wire, and every captured artifact passes
  through a redactor. **What that redactor covers is narrower than "artifacts are redacted"
  suggests**, and the gap is worth knowing before you trust a bundle. It reaches: a `KEY=value`
  line and a JSON `"key": "value"` whose key ends in one of a SINGLE shared list of secret words —
  `password`, `token`, `key`, `username`, `wallet`, `ping_url` and the rest — the JSON side matched
  without regard to case, so `apiKey` and `PASSWORD` are reached alongside `api_key`, the
  `KEY=value` side uppercase-only because `.env` is generated uppercase throughout; a credential
  given as a flag value; a v3 onion; any opaque run of 90 or more characters (and a sha512 with
  them); the token after `--wallet` and the one after `--merge-mine`'s URI, by POSITION; and a
  globally-routable IP address, by SCOPE. The IP rule protects the reserved ranges by mangling one
  dot to a `\x01` sentinel and restoring it at the end, and it neutralises any sentinel already in
  the input before doing so ([#1613](https://github.com/p2pool-starter-stack/pithead/issues/1613)):
  without that step the closing restore ran after every rule, so a `\x01` sitting inside what would
  otherwise be a public quad came out as a dotted, routable address that no rule had inspected. What it keeps is exactly the set
  `is_public_ip` calls private — loopback, RFC1918, link-local and CGNAT — because an artifact whose
  port map and container addresses have been stripped cannot be triaged, and because holding the two
  lists identical is what makes the coverage argument checkable rather than anecdotal.
  [#1582](https://github.com/p2pool-starter-stack/pithead/issues/1582) closed the flag-value and
  address-shape gaps; [#1587](https://github.com/p2pool-starter-stack/pithead/issues/1587) added
  the JSON one; [#1596](https://github.com/p2pool-starter-stack/pithead/issues/1596) added the
  positional one; [#1609](https://github.com/p2pool-starter-stack/pithead/issues/1609) added the
  IP one, after an audit found `pithead doctor` writing the host's own public address into
  `doctor.txt`; and [#1611](https://github.com/p2pool-starter-stack/pithead/issues/1611) put the
  `KEY=value` rule onto the JSON rule's vocabulary. Those two had DRIFTED, which is a sharper
  failure than a missing spelling: the same field carrying the same value was classified two ways
  depending only on the syntax it arrived in, so a wallet address below the length bar was
  redacted in `config.json` and survived verbatim in `env.redacted.txt`. Keying one rule on the
  other's list leaves one list to extend rather than two to drift apart, and the self-test asserts
  mechanically that they still agree. **The length rule never covered wallet addresses as widely as it read**: a
  positional argument has no name to key on, so that rule was the ONLY one reaching the Tari
  address, and of the three Tari forms this repo accepts it reached only the base58 one — by a
  single character.
  Lowering the bound is not available: it starts matching ordinary log tokens well before it
  reaches the 48-character form, and no bound reaches the emoji form at all.
  **The JSON rule is keyed on the field NAME, not the value, and that is forced**:
  a view key and a container digest are both 64 hex characters, so nothing in the value separates
  them. **The name list is open, and three fields are out of the FILTER's reach** — `notifications.ntfy.url`
  is a capability URL whose key is the bare word `url`, which only its nesting separates from the
  public `xvb.url`, and a line-wise filter cannot see nesting. `notifications.webhooks[]` is the
  same kind of URL one shape over: the rule needs the key's colon to be followed by the value's own
  quote, and a JSON list puts a bracket in between. The list shape alone is enough to defeat it —
  `webhook_urls` sits in the redactor's vocabulary, and a value written as `["…"]` under that very
  key still comes through raw. `xvb.standby.source` is the third, and it is a plain name gap: the
  masked-config pass treats it as a secret, and no suffix in either vocabulary carries the bare
  word `source`. That is a limit of the filter, not
  of the bundle: since [#1630](https://github.com/p2pool-starter-stack/pithead/issues/1630) the
  `config.json` artifact is masked BY PATH before it reaches the filter (*Artifacts & triage*
  below), so the topic does not survive a capture. The self-test states the filter's gap rather
  than hiding it, and deliberately does not assert a redaction the filter cannot deliver. **Two further JSON shapes are stated rather than closed**
  ([#1590](https://github.com/p2pool-starter-stack/pithead/issues/1590)): a JSON payload logged as
  an escaped string inside another field (`"msg":"{\"password\":\"…\"}"`), and a secret whose
  value is not a string (`"api_token":12345678`). Both were measured absent from every artifact
  the harness captures — the container logs contribute JSON from one service only, Caddy, and not
  one of its keys is secret-named in any case — and the one-character fix for the second replaces
  the value's trailing delimiter along with the value, so it corrupts the JSON it is meant to
  protect. The self-test pins both at today's behaviour, so a row fails if either shape arrives.
- Continue-on-error. A failing assertion doesn't abort the run. The whole matrix is collected
  and summarized, with per-scenario artifacts for the failures.

---

## Provisioning the test box

A one-time setup. Target the Ubuntu LTS releases the stack supports (22.04 / 24.04).

1. Install and deploy Pithead normally (see [Getting Started](../getting-started.md)) and let it
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
# tests/integration/build-pruned-chain.sh). See docs/dev/release-server.md → prune-axis recipe.
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
| `--no-mining-asserts` | Skip the two mining assertions — workers online ≥ `--workers` and stratum total hashes > 0 — with a logged notice, for a box that has no miner connected. Every other assertion stays binding. `e2e.sh --no-miner` passes this automatically ([#905](https://github.com/p2pool-starter-stack/pithead/issues/905)). |
| `--remote-monero-host <h>` | External node endpoint for the `remote` scenario. |
| `--remote-tari-host <h>` | External Tari node endpoint for the `tari.mode=remote` scenario ([#103](https://github.com/p2pool-starter-stack/pithead/issues/103)) — an already-synced Tari node, same shape as `--remote-monero-host`. |
| `--pruned-data-dir` / `--full-data-dir` | Synced alt DB to enable the opposite prune mode. |
| `--lifecycle` | Also run the lifecycle phase (restart, apply secret-preservation). |
| `--fault-injection` | Also break monerod (stop / SIGSTOP / remove) and assert `status`' down/unhealthy/missing verdicts and the failover→recovery cycle, plus a dashboard DB-write fault (data dir made read-only → `/api/state` reports `db_healthy:false` → write access restored, [#202](https://github.com/p2pool-starter-stack/pithead/issues/202)). Destructive-then-restored; local mode only; slow. |
| `--auth-fail-closed` | Also empty `PROXY_AUTH_TOKEN` in `.env` and assert `pithead up` refuses to start (the live counterpart to the tier-1 compose-config check, [#153](https://github.com/p2pool-starter-stack/pithead/issues/153)/[#203](https://github.com/p2pool-starter-stack/pithead/issues/203)), then restore the exact token and recover. Destructive-then-restored; ssh or local mode. |
| `--rigforge-control` | Also drive the RigForge WRITE paths against a real rig with `dashboard.control` on and the rig pinned in `workers.list[]` (#506; a baseline that still carries the deprecated `dashboard.workers[]` fallback is left as-is, so that shape stays exercised too): the enriched read survives a populated masked-token descriptor ([#514](https://github.com/p2pool-starter-stack/pithead/issues/514)), the rig is editable and a reversible Worker Inspect edit lands on it on four of the six writable keys — `max_temp_c` ([#508](https://github.com/p2pool-starter-stack/pithead/issues/508)/[#513](https://github.com/p2pool-starter-stack/pithead/issues/513)), `DONATION` and `watchdog_interval_min` ([#1236](https://github.com/p2pool-starter-stack/pithead/issues/1236)), and `pools` (needs `IT_RIG_POOLS_PROBE`); `autotune` and `watchdog` are refused on purpose — a rig-side edit reflects back in the feed + masked prefill ([#516](https://github.com/p2pool-starter-stack/pithead/issues/516)), and an auto-rollback is recorded end-to-end ([#517](https://github.com/p2pool-starter-stack/pithead/issues/517)). Destructive-then-restored; local mode only; each leg self-skips without its prerequisites (see below). |
| `--rig-host <h>` / `--rig-control-port <p>` | The borrowed rig's LAN host and writable control API port (default `8082`), used to inject a `workers.list[]` descriptor when the box's baseline lacks one ([#185](https://github.com/p2pool-starter-stack/pithead/issues/185)/#506). Pair with `IT_RIG_TOKEN` (env; never a flag). |
| `--subnet` | Also bring the stack down then up on a non-default `network.subnet` (`10.84.0.0/24`) and assert the moved prefix reached `.env`, the docker bridge, Tor's render-at-start IP, monerod's proxy IP, the dashboard SSRF CIDR, and the [#344](https://github.com/p2pool-starter-stack/pithead/issues/344) onion vhost, then run the standard battery ([#201](https://github.com/p2pool-starter-stack/pithead/issues/201)/[#180](https://github.com/p2pool-starter-stack/pithead/issues/180)). Destructive-then-restored; local mode only. |
| `--safety-backup` | Take a `pithead backup` before the destructive scenarios and auto-roll-back (down → restore → up) if anything fails; the archive is removed on success. Recommended for the destructive matrix on a precious box; also exercises backup/restore end-to-end. |
| `--keep` | Don't restore the original config (leave the box on the last scenario). |
| `--out <dir>` | Where to write the manifest and failure artifacts. |
| `--list` | Print the matrix and axis coverage and exit. |

The runner exits non-zero if any assertion failed.

---

## One-command branch e2e (`e2e.sh`)

`run.sh` assumes a stack is already deployed on the box. [`tests/integration/e2e.sh`](../../tests/integration/e2e.sh)
is the wrapper that does the whole thing for a branch against the live test bench in one command:
deploy, borrow a real miner, run the matrix, and put everything back.

```bash
tests/integration/e2e.sh <branch> [--mode targeted|check|matrix] [--workers N] [--miner HOST]
tests/integration/e2e.sh claude/my-feature                 # default: LEAN — dashboard + sync logic
tests/integration/e2e.sh claude/my-feature --mode check    # non-destructive smoke (pure reads)
tests/integration/e2e.sh claude/my-feature --mode matrix   # full config sweep (opt-in, pre-release)
```

Pre-flight, before anything is locked or borrowed: both chains must read `done` on the bench
dashboard's sync panels. Otherwise it prints each chain's current/target height and aborts — a
bench that starts hours behind tip fails the required-sync assertions as environment noise, not
a regression, and burns the borrowed-rig hour finding out
([#914](https://github.com/p2pool-starter-stack/pithead/issues/914)). `--skip-preflight`
overrides.

What it does, then reverses on exit (even on failure / Ctrl-C, via an `EXIT` trap):

1. Dedicated checkout. Provisions `/srv/code/pithead-e2e` (clone-once, then `git fetch`) and checks
   out `<branch>` there. The checkout is disposable, so provisioning forces a pristine tree
   (`checkout -f` + `reset --hard` + `clean -fdx`) — a leftover untracked file from an earlier run
   can't abort the checkout. `clean` keeps the harness's `results/` and the seeded `config.json`/
   `.env`/`data/`/`backups/` (all gitignored). The canonical `/srv/code/pithead` is the baseline and
   is never git-touched. Because the Compose project name is pinned to `pithead`, the two checkouts
   drive the same containers and the same shared chains. They're two code copies of one stack, run one
   at a time, so borrow→test→restore is a fast code/image swap, never a re-sync.
2. Seeds the e2e checkout's `config.json`/`.env` from the live release bundle when one exists —
   the `current ->` symlink next to `CANONICAL_DIR` (e.g. `/srv/code/current`), resolved with
   `readlink -f` — falling back to the canonical checkout's copies otherwise
   ([#880](https://github.com/p2pool-starter-stack/pithead/issues/880); a release bumps the
   bundle's config, not canonical's, so canonical can lag for months). When both configs exist it
   always prints a key-level diff summary (full dotted paths via `jq`, nested keys included), so
   drift is loud instead of a stale config being deployed silently. Either way the seed carries
   the same wallet, secrets, onion keys, and shared `monero/tari/p2pool` data dirs — only the
   branch's code differs.
3. Safety backup (`pithead backup`) as the rollback anchor.
4. Borrows a miner (default the configured miner): backs up its xmrig config and repoints it at the
   bench so the matrix has a real worker mining through this stack (1 worker → run with `--workers 1`).
   With `--no-miner` nothing is borrowed, and the harness runs with `--no-mining-asserts`: the
   workers-online and stratum-hashes assertions skip with a logged notice while every other
   assertion stays binding ([#905](https://github.com/p2pool-starter-stack/pithead/issues/905)).

   Before it takes that backup, the borrow undoes a previous run that died without restoring —
   SIGKILL, an OOM kill, `--keep`, a failed teardown. Such a run leaves the rig pointed at the bench
   and leaves its `.e2e-orig.*` backup on disk, because the restore prunes that backup only once it
   has compared the bytes back into place. So a surviving backup means an un-restored borrow, and the
   oldest one holds the true pre-borrow config. Restoring from it first is what stops this run's
   backup from recording the borrowed state as "the original" and every later restore returning to it
   ([#1178](https://github.com/p2pool-starter-stack/pithead/issues/1178)).

   A rig that keeps a permanent bench pool of its own is the case that makes this necessary. There the
   repoint finds the bench already named, so it only reorders the pool list and tags nothing — the
   contamination leaves no marker, and a tag-based check cannot see it. Two other outcomes are worth
   knowing: when the rig does not look borrowed, leftover backups are cleared as stale, because
   RigForge regenerates the xmrig config from its own source on every apply (`rigforge.sh:3979` at the
   baked pin — though a fast-path control-apply of `watchdog_interval_min` or `max_temp_c` deliberately
   skips that path, `rigforge.sh:4203` and `:4228`); and when the config cannot be read at all, nothing
   is cleared and nothing is restored, since a config half-written by a run that died mid-restore looks
   exactly like that and must not cost the only copy of the original.

   One outcome cannot be resolved from the rig alone. When it looks borrowed and no backup survives,
   the pre-borrow state is gone: a surviving untagged bench pool is then either the rig's own permanent
   one or an un-undoable reorder, and nothing on the rig separates them. The run says so and asks for a
   hand repair, rather than reporting the reassuring reading of the two.
5. Deploys the branch (`pithead upgrade` — re-renders the generated configs and rebuilds the
   first-party images from `build/`, so a Dockerfile or entrypoint change is actually under test;
   `apply` never builds and would reuse whatever images were last built on the box,
   [#272](https://github.com/p2pool-starter-stack/pithead/issues/272)) and runs
   `run.sh` detached on the box (survives an SSH drop on a long matrix), streaming a heartbeat and
   the full log at the end.
6. Restores the miner's original pool config and the baseline stack. Restore targets the directory
   the live stack actually ran from — read at preflight off the running container's
   `com.docker.compose.project.working_dir` label — which on a release box is the per-version bundle
   dir, not `CANONICAL_DIR`. That keeps the restore from handing the `pithead` project locally-built
   `:dev` images. If the label can't be read (stack down), it falls back to `CANONICAL_DIR`; override
   with `CANONICAL_DIR=<dir>`. The synced chains are never touched (asserted post-restore).
   How the baseline comes back depends on what it is. A release bundle gets `pithead apply` then
   `pithead up`: its images are versioned tags the branch never touched, so rebuilding them would be
   waste. A **source checkout** gets `pithead upgrade` instead, and the difference is not an
   optimisation. `pithead` exports `STACK_VERSION=dev` for any source checkout, so a source-checkout
   baseline and the branch under test resolve to the same `:dev` tag — which deploying the branch has
   already overwritten, with a pull policy of `never` to correct it. `apply` + `up` would bring the
   branch back up under the baseline's name. The rebuild falls back to `apply` + `up` if it fails, so
   a baseline that cannot rebuild is no worse off than before.
7. Proves the restored stack matches the on-disk config
   ([#971](https://github.com/p2pool-starter-stack/pithead/issues/971)): the credential marker
   baked into the running dashboard container (`docker inspect`) must equal the on-disk `.env`
   line — compared as verdict words, values never printed — and monerod must answer a host-side
   `get_info` authed with the on-disk creds. An e2e run once left the containers on
   harness-rendered creds while the on-disk `.env` kept the real ones: internally consistent, so
   the stack mined and looked healthy for a day while every host-side RPC probe 401ed. A failed
   proof exits non-zero and names the recovery (`docker compose up -d` from the install dir
   re-bakes everything from disk). The same proof asks the restored install's own `doctor` whether
   the box-global control-runner units still name it
   ([#1085](https://github.com/p2pool-starter-stack/pithead/issues/1085)): deploying the branch
   repoints those units at the e2e checkout, and the hardening phase's teardown removes them when it
   owns them, so a run can end with the live dashboard's config edits and one-click upgrades queueing
   into a spool nothing watches — enabled, active and silent. The verdict is read from the install's
   own `pithead`, run from its own directory, because `pithead` works from the directory of the
   binary you invoke: the branch's copy would compare the units against the e2e checkout and report
   all-clear on exactly the stranded box. That needs the live install on v1.19.2 or newer, the
   release whose `doctor` gained the check; an older one is reported as unproven rather than as a
   pass.
   Last, the proof asks what code is actually running. The three checks above are all green on a
   stack running the branch's images under the baseline's name: the credentials are read from the
   on-disk `.env` at runtime, monerod answers with them, and the control units name the install
   either way. So the run records each service's image **ID** before it touches anything and again
   after the restore, and grades them per service — kept, rebuilt, still-the-branch's, or gone. Image
   IDs, not tags: a tag that moved is the defect, so the tag cannot be the instrument. Per service,
   not as one list: a branch that changes two Dockerfiles rebuilds two images, and the rest carry an
   ID that legitimately matches both sides. A service still on the image the run built for the branch
   fails the proof and names itself. A rebuilt image is reported as "not the branch's" and no more:
   settling "built from the install directory" would need the image's own build provenance, and the
   dashboard's `org.opencontainers.image.revision` ships empty
   ([#1449](https://github.com/p2pool-starter-stack/pithead/issues/1449)) while the other four
   images carry it.

`--mode`: `targeted` (default, lean) validates the dashboard and the sync logic against the
already-synced node: `check` + `--lifecycle` (one controlled restart exercises the sync gate /
node-down failover) + `--auth-fail-closed`, plus `--rigforge` and `--rigforge-control` when a rig is
borrowed. No full config sweep, and never a re-sync. Container restarts reload the existing chain and
re-confirm the tip in seconds. `check` is pure reads only. `matrix` is the opt-in full destructive
config sweep (lifecycle + fault-injection + auth-fail-closed + hardening + `--subnet`, plus the same
two rig phases, all under `--safety-backup` auto-rollback) for a pre-release tier-4 gate.
The rig phases are gated on a borrowed miner rather than on the mode: the release runbook mandates
`targeted`, so keeping the write paths matrix-only left them out of the gate that decides whether a
release ships ([#1364](https://github.com/p2pool-starter-stack/pithead/issues/1364)). `--keep` leaves it deployed for
inspection (skips the restore). Requires SSH access to the test bench and the miner; see the
[testbench README](../../tests/integration/testbench-README.md).

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
| `tari.mode` | `local` / `remote` | profile gating, onion gating, the sync gate against a remote target — the [#103](https://github.com/p2pool-starter-stack/pithead/issues/103) GO verdict's operating mode, needs `--remote-tari-host` |
| `p2pool.stratum_tls` | `false` / `true` | a live TLS handshake on the published stratum port, and that the served certificate matches the fingerprint rigs are told to pin ([#261](https://github.com/p2pool-starter-stack/pithead/issues/261)) |
| `network.tor_egress_firewall` | `true` (default) / `false` | the opt-out actually opens a direct clearnet dial from a `mining_net` container, not just that no rule got installed ([#270](https://github.com/p2pool-starter-stack/pithead/issues/270)) |
| `monero.view_key` / `tari.view_key` | unset (default) / a real key | payout-confirmation wallet-rpc / tari-wallet wiring ([#381](https://github.com/p2pool-starter-stack/pithead/issues/381)/[#462](https://github.com/p2pool-starter-stack/pithead/issues/462)) — needs `IT_MONERO_VIEW_KEY` (env; the box's own real Monero view key), optionally paired with `IT_TARI_VIEW_KEY` + `IT_TARI_SPEND_PUBLIC_KEY` |

### What each scenario asserts

- Expected containers up, unexpected absent. Every service for that config is running and
  healthy; in `remote` mode there is no `monerod` (and, independently, no `tari` when
  `tari.mode=remote`); `wallet-rpc`/`tari-wallet` appear only when their view key is set.
  Presence is decided by `service_present`, which matches a compose service name as a whole
  line and never as a substring ([#1478](https://github.com/p2pool-starter-stack/pithead/issues/1478)).
  That distinction is load-bearing: `tari` is a prefix of `tari-wallet`, so a substring match
  would report a stopped `tari` as running whenever the payout-confirm container is up.
- `pithead status` exit code: `0` for a healthy config.
- p2pool actually reached the Tari node over gRPC ([#1397](https://github.com/p2pool-starter-stack/pithead/issues/1397)). p2pool's merge-mining
  client emits three lines at startup and only one of them says anything about Tari:
  `MergeMiningClientTari tari://<host:port> uses chain_id <id>`, because p2pool cannot know the
  chain id without a successful call to the node. The other two, `event loop started` and
  `worker thread ready`, are local — they prove the object was constructed and its threads spun.
  On the live stack they landed about 175 milliseconds before the chain-id read, so a row keyed on
  either would pass with Tari unreachable. That case is its own verdict, `local-only`, and it
  fails rather than passing quietly: it means the client is up and Tari is not answering. Nothing
  else at any tier watches this leg — `fakes/test_contract.py` looks like it does and does not,
  since it drives the dashboard's Tari client while merge-mining is a third-party binary's own
  gRPC. Two properties of the signal shape the read. It is startup-only: the three lines landed
  within about 17.5 seconds of the container starting, at positions 68, 69 and 71 of a log that
  had reached 83,070 lines after 30 hours (one sample), so a `--tail` read cannot contain them.
  The window is therefore a head read, bounded by the container's own start time so that an
  earlier startup's line cannot satisfy the assertion after a restart. And the log is
  ANSI-coloured with the escapes mid-line, between the client name and the endpoint, so a pattern
  written against the rendered text matches nothing at all, silently — a probe that always reports
  an absence looks exactly like a working one until the day it matters. The escapes are stripped
  before matching, and the self-test carries that control fired in both directions: zero matches on
  the captured bytes, one after stripping. The capture is read before the caught-up predicate, and
  that order is itself an assertion ([#1597](https://github.com/p2pool-starter-stack/pithead/issues/1597)). `monero_caught_up` answered, at the time, with one bit that could
  not separate a node that is behind from an RPC that could not be answered at all: its `curl`
  discards stderr, so an unreachable host, a refused connection and a 401 alike leave the empty
  body that `jq` reads as not caught up.
  ([#1605](https://github.com/p2pool-starter-stack/pithead/issues/1605) has since given the
  predicate three answers — `0` caught up, `1` answered and behind, any other rc could-not-ask,
  the open top end so that `rx`'s own ssh failure at `255` cannot be reported as a node that is
  behind. The merge-mining leg still treats both nonzero doors alike, deliberately, and the
  ordering below is what makes that honest rather than the predicate's precision.)
  Asked first, that bit decided the whole leg, and a stack
  whose merge-mining client was up and reading chain_ids would have been booked as an accepted
  hole for as long as a credential stayed broken — a state this repo has recorded lasting a day.
  Any `MergeMiningClientTari` line is itself proof that monerod caught up, since p2pool builds no
  client until the header download succeeds, so the log settles what the RPC could not. The leg
  skips only when the window was read and held no such line: p2pool then built no client, the
  download did not complete, and no input to this harness would create the signal, which is what
  earns the counted `by-design` class rather than the predicate's bit. Every case the order moves,
  it moves out of the skip ledger into a pass or a fail, never the other way. Only the matching
  lines cross the wire, which keeps the container's argv line — carrying both wallet addresses,
  the RPC credential and the onion — out of the capture.
- Dashboard reads live state. `/api/state` is reachable; Monero is synced (`done`); pruned/full
  display matches `monero.prune` ([#32](https://github.com/p2pool-starter-stack/pithead/issues/32)); the sidechain `pool.type` matches `p2pool.pool`.
- The Monero node's ZMQ endpoint is a live ZMTP publisher. A ZMTP handshake against the node's ZMQ
  port succeeds and the peer advertises a publisher socket type ([#1497](https://github.com/p2pool-starter-stack/pithead/issues/1497)). The row is
  named for what the handshake proves, which is narrower than "publishes block notifications": a
  node whose publisher is bound but permanently silent answers it exactly as a live one does. A
  second row closes that case: it subscribes and waits for the peer to actually send something,
  which a silent publisher never does. Measured on one host against both targets, the live node
  passed in about 2 seconds and a permanently silent publisher red at its budget. The budget is
  90 seconds, and the sample behind that figure is part of it — time-to-first-message against the
  live node over eight samples ran 0.3, 1.5, 1.8, 3.3, 4.5, 5.6, 16.0 and 26.5 seconds, and the
  first three would have justified a 30-second budget that the tail turns into a flaky red. It is
  a ceiling rather than a cost: the read returns on the first byte. What remains unproven is
  narrower than it was — that the frame carried a block notification rather than a transaction or
  a miner update — and every run counts it as a missing leg, `monero ZMQ published frame is a
  BLOCK notification`, because a skip announces itself and a false green does not. Closing that
  needs a new block, a wait of minutes where any published frame arrives in seconds. This is a
  separate
  assertion from "Monero is synced" because the sync check cannot fail for a node that can never
  publish: an `--offline` monerod reports `status: OK` with `target_height: 0`, which satisfies
  both halves of the caught-up predicate. Nothing downstream covered the gap either — p2pool's
  healthcheck is a TCP connect to its own stratum port — so a ZMQ-dead node brought the stack up
  green and starved p2pool with nothing able to notice. A bare TCP dial does not close it: a
  docker-published port with nothing behind it accepts the connection in `docker-proxy` itself and
  answers a dial with rc 0. Measured on one host, four targets: the live node and the
  published-but-dead port were indistinguishable to a dial (both rc 0) and separated by the
  handshake; the live node and a permanently silent publisher were indistinguishable to the
  handshake as well, both answering `ok … XPUB`, which is the pair the subscribe row separates.
  Real nodes advertise `XPUB` rather than `PUB`; both are accepted.
  The probe bounds its own connect ([#1500](https://github.com/p2pool-starter-stack/pithead/issues/1500)). `timeout` cannot wrap a shell
  redirection, so the opening `exec` inherited only the kernel's SYN-retry deadline. A closed port
  answers with RST in about 2 ms, which is why this stayed hidden; a filtered or black-holed host
  produced no verdict at all until the kernel gave up, far past the probe's budget. Measured
  against a black-holed address on a 3-second budget: 15 s and empty output before, 3 s and a
  named verdict after. A filtered host is reported as `connect-timeout`, kept apart from
  `connect-refused` on purpose — a refusal is an answer and points at the port, a timeout is the
  absence of one and points at a firewall, a partition or the wrong address.
- End-to-end mining. Workers are online (`proxy_workers >= --workers`), stratum has connections,
  and total hashes are accumulating ([#28](https://github.com/p2pool-starter-stack/pithead/issues/28)).
- Posture propagated. `MONERO_RPC_BIND`, `DASHBOARD_SECURE`, `XVB_ENABLED`, and `TARI_REQUIRED`
  in `.env` match the config; the Caddyfile uses the right scheme.
- Node onions follow the node. The Monero and Tari hidden services are each published only when
  their own mode is `local` ([#103](https://github.com/p2pool-starter-stack/pithead/issues/103)).
- Stratum TLS is live (`p2pool.stratum_tls=true` row only). A TLS handshake against the published
  stratum port succeeds, and the served certificate's fingerprint matches the one
  `announce_stratum_tls` tells rigs to pin ([#261](https://github.com/p2pool-starter-stack/pithead/issues/261)).
- Firewall opt-out actually opens the path (`network.tor_egress_firewall=false` row only). No
  `pithead-tor-egress`-tagged rule is installed, and a direct clearnet dial from a `mining_net`
  container succeeds — the mirror of the fail-closed default `assert_egress_posture` proves
  elsewhere ([#270](https://github.com/p2pool-starter-stack/pithead/issues/270)).
- Payout confirmation is live (the view-key row only). `PAYOUT_CONFIRM_ENABLED`/
  `TARI_PAYOUT_CONFIRM_ENABLED` in `.env` match the config, and the dashboard's own
  `earnings.confirmed.enabled`/`earnings.tari_confirmed.enabled` flags read `true`
  ([#381](https://github.com/p2pool-starter-stack/pithead/issues/381)/[#462](https://github.com/p2pool-starter-stack/pithead/issues/462)). A real
  confirmed payout needs days of chain time no e2e run has, so that total staying `0` is expected
  and not asserted otherwise — only that the feature is genuinely ON, not just configured.
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
than force-migrated, so that shape stays exercised too), and drives five legs, each self-skipping
loudly without its prerequisite:

- Read with a populated masked descriptor ([#514](https://github.com/p2pool-starter-stack/pithead/issues/514)):
  `api_ok` and the enriched feed still resolve — the guard for the v1.5.2 regression, where the
  masked sentinel was stringified into the `Bearer` header and every `:8081` probe returned 401.
- Editable + reversible edit ([#508](https://github.com/p2pool-starter-stack/pithead/issues/508)/[#513](https://github.com/p2pool-starter-stack/pithead/issues/513)):
  Worker Inspect reports the rig `editable`, and a `max_temp_c` nudge applied via
  `/api/control/worker-apply` lands on the rig's `/status` and is recorded in the per-worker
  history, then reverted.
- Two more writable keys, `DONATION` and `watchdog_interval_min`
  ([#1236](https://github.com/p2pool-starter-stack/pithead/issues/1236)): RigForge v1.10.0 serves
  the rig's own effective writable config on the enriched feed, and the dashboard re-exposes it at
  `GET /api/worker`'s `.rig_config` — the same values the Worker Inspect editor prefills from. So
  each leg reads the original off the rig itself, derives a probe from it, asserts the **rig**
  reports the new value, and restores. No new environment variable, no direct rig dial. `DONATION`
  only ever moves toward zero (a rig already at 0 is nudged to RigForge's default 1), and
  `watchdog_interval_min` steps one minute away from wherever it sits, inside RigForge's 1–1440
  range. The restore runs whatever the assertions said, so a mid-leg failure cannot strand a
  borrowed rig on a probe value.
- **Three writable keys are deliberately never driven, and this is a decision rather than a gap.**
  `autotune` would start a real tuning run — it moves hashrate and thermals and may not settle
  inside the leg. `watchdog` would remove thermal protection from a rig mining at its temperature
  ceiling. `pools` cannot be round-tripped from the rig's own reading at all: RigForge strips `pass`
  and `tls-fingerprint` before serving the config, and the dashboard strips them again, so the value
  that comes back is lossy — and `pass` is the stack's stratum password
  ([#113](https://github.com/p2pool-starter-stack/pithead/issues/113)), which the proxy rejects a
  login without. Worse, the harness cannot tell "this rig has no password" from "this rig's password
  was stripped on the way to me": both arrive as `{"url": …}`. Writing that back would silently
  strand a borrowed miner.
- `pools`, the operator-supplied route (the repoint-your-hashrate key): because the rig's own
  reading cannot be written back, the restore target is the dashboard's record of what *it* last
  pushed (`GET /api/worker`'s `.last_applied.pools`), which is un-stripped, and the probe is
  operator-supplied (`IT_RIG_POOLS_PROBE` — pithead treats `pools` as opaque passthrough, so a
  guessed value risks a real `rejected` instead of proving the round trip). Self-skips if the
  dashboard has never applied a `pools` value to this rig before (nothing to safely restore).
- Rig-side edit reflects ([#516](https://github.com/p2pool-starter-stack/pithead/issues/516)):
  a change made straight on the rig's control API shows up in the dashboard's enriched feed, and a
  `config.json` hand-edit shows up in the masked prefill (with the token still masked).
- Auto-rollback ([#517](https://github.com/p2pool-starter-stack/pithead/issues/517), rigforge#236):
  a change the rig rolls back is recorded as `rolled_back` in the worker-apply result and history.

### Settling an apply that comes back `accepted`

RigForge answers a worker-apply immediately and applies asynchronously (rigforge#344), so the dial
result is often `accepted` rather than a terminal `applied`. The harness settles that itself: it
polls the rig's own reported value until the requested change shows up, then treats the change as
applied, and leaves a genuine `rejected` / `failed` / timeout exactly as it found it. The `#513`
`max_temp_c` leg and both `#1236` legs share one settle for this
([#1309](https://github.com/p2pool-starter-stack/pithead/issues/1309)).

That settle hands its result back on stdout, which makes its output discipline load-bearing rather
than cosmetic. The wait's progress line goes to stderr for that reason; on stdout it would be read
back as the result itself, and every assertion downstream would fail whatever the rig had done. The
first hardware run to exercise the wait hit precisely that
([#1454](https://github.com/p2pool-starter-stack/pithead/issues/1454)): the rig recorded both
`DONATION` changes applied, eighteen seconds apart, while the gate reported four failures. The
self-test that covers the settle now runs the real wait rather than a silent stub, because a stub
that prints nothing cannot see this class at all.

The same leg then asserts that the change reached the dashboard's `#185` per-worker history, and
that readback needed a settle of its own
([#1471](https://github.com/p2pool-starter-stack/pithead/issues/1471)). The two surfaces converge
at different moments, and the harness used to argue that they did not. The argument's first half
holds: the reconcile step does run before the enriched-feed merge, on the same poll. Its second
half does not, because both of those read a rig file that RigForge writes at the *start* of a
control-apply, before it has decided the outcome at all. The terminal status goes to a second file
at the end, after the apply, an xmrig restart and a bounded wait for the miner to come back, and
the reconciler cannot move the row off `accepted` until it has read that one. Settling on the
config therefore ends at the start of that window rather than after it, and reading the row there
raced it by up to ninety seconds. The claim survived because two of the three keys that reach that
assertion, `max_temp_c` and `watchdog_interval_min`, are on RigForge's restart-free fast path, where
the window is too small to see. The third, `DONATION`, is off that list and takes the full path —
which is where the ninety-second bound comes from, and where a hardware run would have hit this.

The row is now waited to a terminal status before it is read, on the same ninety-second bound the
window itself has. Terminal rather than `applied`, which is what keeps the assertion honest in both
directions: a rig that genuinely rejected a change publishes its terminal row at once, so the leg
reds on the real status instead of spending the whole bound on a verdict already known, and a row
that never settles stays `accepted` and reds as well. The one answer the wait must never invent is
`applied` for a row nobody has confirmed. Terminal is written as the complement of `accepted` and
"no row yet", not as a list of the six outcomes the rig can report today, so a status added
upstream reads as terminal and gets named by the assertion rather than timing out and being
reported as a row that never settled.

### The abort-safe unwind

Every leg above restores what it changed when it finishes. That covers a leg that *fails*; it does
not cover a run that never reaches its own restore. Ctrl-C, a `set -u` abort, an SSH drop or a
cancelled CI job used to leave a borrowed production miner on a probe value, while `e2e.sh`'s
`restore_all` reported a clean restore of the *pool* config and said nothing about the writable keys
([#1379](https://github.com/p2pool-starter-stack/pithead/issues/1379)).

`rig-key-ledger.sh` closes that window. A key goes on a ledger when its write is sent — before, not
after, so the apply itself is covered — and comes off only when its revert is **confirmed applied**.
An `EXIT` trap restores whatever is still on the ledger, by the same route that changed it: the
dashboard's `/api/control/worker-apply` for the #513, #1236 and #1002b legs, a direct dial at the
rig's control API for #516's rig-side edit. Each restore names its key, value and rig on stderr.

Three properties are worth knowing rather than rediscovering:

- **It is a no-op by construction, not by a guard.** A run that writes no writable key never marks
  anything, so no trap is ever installed. `--mode targeted` runs that borrow no rig are unaffected.
- **The trap is composed, not stacked.** `trap … EXIT` replaces rather than stacks, and `rig_lock`
  already installs one to clear the shared-bench holder breadcrumb. The ledger's handler folds that
  removal into its own body — which is what `lib.sh` prescribed for whatever trap came second — so
  arming it cannot silently strand the breadcrumb or silently skip the restore.
- **`#517` is deliberately outside the ledger.** Its leg induces a change the *rig* rolls back on
  its own. Unwinding it from here would race that rollback and could re-apply a value the rig had
  already reverted, so the rig stays the authority for it.

What it cannot do: the restore dials the dashboard or the rig while the run is already dying, so it
is best-effort, and it cannot run at all if the shell never exits — `kill -9`, an OOM kill, or the
box losing power. After an end like that, read the rig's values in Worker Inspect and put a stray
one back by hand.

Prerequisites: a real RigForge rig connected (self-skips otherwise); `--rig-host` + `IT_RIG_TOKEN`
to inject a descriptor when the baseline lacks one, and to dial the rig directly for the #516 feed
leg; `IT_RIG_POOLS_PROBE` (a JSON `pools` value safe to apply to the borrowed rig) for the pools
leg; `IT_RIG_ROLLBACK_CHANGES` (a writable-key `changes` object the rig's fault-injection reverts)
for the #517 leg.

Under `e2e.sh` the first two are supplied for you
([#1378](https://github.com/p2pool-starter-stack/pithead/issues/1378)): `RIG_HOST` defaults to the
borrowed `MINER_HOST`, and the token is read off the rig's own `/opt/rigforge/config.json` over the
SSH the borrow already holds. Neither needs the operator to handle a secret, which matters because a
supply step done by hand is one the mandated pre-cut run would skip. `e2e.sh` then dials the rig's
control API **from the bench** before reporting the phase as supplied, and says which case it took —
an unreachable rig is named rather than left to surface later as a leg that quietly skips. Override
either with `RIG_HOST` or `IT_RIG_TOKEN` in the environment; `RIG_CONTROL_PORT` (default `8082`) is
passed through to `run.sh` so the two can never dial different ports.

### RigForge upgrade (part of `--rigforge-control`)

Drives the one-click RigForge upgrade the Worker Inspect button submits, and which branch it takes
is decided by the dashboard's own `rigforge_update` verdict for that rig — the same `{available,
latest, url}` the button renders, so the leg selects the way a click would.

**When the dashboard offers the rig a newer release**, the leg POSTs that release to
`/api/control/worker-upgrade` and asserts a real upgrade, in four steps that are four separate
claims rather than one restated:

1. The answer is a `202` carrying a pollable `id`. Because the rig is behind the proposed version,
   `handle_worker_upgrade`'s already-on-this-version shortcut cannot fire, so a pending answer is
   itself the evidence that the intent left the dashboard process for the host runner.
2. The polled result reaches an `applied` terminal. A rig-side `throttled` (its own 6h anti-beacon
   window) is a classified skip rather than a failure — it is rig state, and no input to the
   harness changes it. An `accepted` is the host's 90s poll cap expiring with the upgrade still
   running, so the leg settles it against the rig's own report instead of reading the cap as red.
3. The rig comes back reporting the new version, read from its summary poll — what the rig now
   *is*, not what the host said it did.
4. Only then, on a precondition this run established rather than assumed, the repeat-click `noop`
   is asserted: a synchronous `noop` carrying **no** `id`, which is what says the dashboard's
   shortcut answered it without dialing the rig and spending its throttle.

**Otherwise the leg skips, loudly and classified.** `compute_update` returns `None` for "already on
latest", "ahead of latest" and "no release cached over Tor" alike, and nothing else in `/api/state`
tells those apart — `rigforge_release` is consumed by `build_workers` and never re-exposed. The
skip reason names both branches rather than picking one.

#### Why this replaced the old leg, and what it cannot cover

The previous leg POSTed the rig's **own** reported version and asserted `noop`. It could not fail.
`/api/state` serves `app["latest_data"]` with the rig's version copied through verbatim, and
`handle_worker_upgrade` reads `running` from that same dict — the poll loop mutates it in place and
never rebinds it — then short-circuits when the two match. The harness set the proposed version
*from* the reported one, so the comparison was true by construction and the request returned `noop`
without reaching the host runner or the rig. Its documentation here claimed a stale-cache path that
also dialed the rig for real; that path was unreachable by the leg's own construction. Combined
with an opt-in flag no caller set, the gate's only upgrade coverage was a check that never ran and
could not have gone red if it had.

The leg still cannot exercise the rig's **rebuild** path, and that is a limit rather than a gap to
close here: `XMRIG_VERSION` and `XMRIG_COMMIT` are identical at every published RigForge tag, so
`rigforge.sh upgrade` takes its early return on any published release pair and the one-click path
checks out the new tree without recompiling, regenerating config or reinstalling units
(rigforge#413). No choice of tags would cover it.

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

`config.json` is the one artifact that is not streamed straight through the redactor. A config is a
document with an enumerable shape, and the stack already classifies it by PATH:
`render_masked_config` walks `CONTROL_SECRET_PATHS` plus the three variable-length array cases a
fixed-path walk cannot reach (`workers.list[].token`, the deprecated `dashboard.workers[].token`,
and `notifications.webhooks[]`, where the whole URL is the bearer secret). The capture SOURCES the
box's own `./pithead` and calls that function rather than restating the list or the jq program
here: sourcing is the shipped contract, since the prelude sets `_STACK_SOURCED` and skips the `cd`,
the traps and `main`. One classification, one place to change it. The masked document then passes
through the redactor as before, so the shape, position and IP rules keep their reach over
everything the path list does not name — the pass is additive and cannot narrow coverage. It
renders from the LIVE config at capture time rather than copying the box's pre-rendered
`$CONTROL_DIR/masked/config.json`, which is refreshed only on setup/apply/upgrade and is documented
as degrading to a stale copy on a render hiccup: an artifact presenting stale state as the state
under test is the failure this harness exists to catch. If the program cannot be sourced the
capture writes no config rather than falling back to the raw file, and says so in the artifact.

### Reading the verdict — what did not run

The summary counts three kinds of skip separately and names every one:

```
passed:  312
skipped: 2 scenarios, 1 phases, 4 legs
  of which: 5 missing (an input would have run it), 1 by-design (this run's mode excludes it), 1 covered elsewhere
did NOT run:
    - [missing]   scenario prune-remote — no pruned chain supplied
    - [by-design] PHASE    hardening — remote mode: no local containers/systemd to exercise
    - [covered]   leg      Worker Inspect read/write (#185) — dashboard.control off (covered by the hardening phase + tier-2 contract)
    - [missing]   leg      pools write (#1002b) — no IT_RIG_POOLS_PROBE
```

A scenario skip drops one matrix row; a phase skip drops every leg under it with one line; a leg
skip drops one assertion group. They stay in separate buckets because they are not the same size
of hole, and a phase drop announces itself more loudly in the live output.

Until [#1365](https://github.com/p2pool-starter-stack/pithead/issues/1365) only the scenario
skips were counted. A run that dropped the whole rigforge-control phase and a run that exercised
it produced summaries differing by nothing but the pass count, and the pass count moves for a
dozen unrelated reasons. The output had no way to say a surface had not run, which leaves the
reader unable to tell "checked and clean" from "never ran" — the distinction the gate exists to
make.

Every skip leaves through `it_skip_scenario`, `it_skip_phase` or `it_skip_leg`
(`tests/integration/skip-accounting.sh`). Plain `it_warn` stays for warnings that are not a
dropped check.

### Only one of the three classes is a gap

Counting and naming the drops still left the reader unable to answer the question they actually
have: is this hole one we accepted, or one we could have filled today? That is
[#1083](https://github.com/p2pool-starter-stack/pithead/issues/1083) — five scenario skips read as
"known and fine" for months precisely because the number never moved. So every skip carries a
class, and the classes are not decoration:

| class | means | is it a gap? |
|---|---|---|
| `missing` | An input would have run it — an env var, a flag, a data dir. | **Yes. This is the number worth reading.** |
| `by-design` | Structurally inapplicable to this run's configuration. Remote mode has no local monerod to stop; no flag changes that. | No. Covering it means running a different scenario. |
| `covered` | Exercised elsewhere, and the reason says where. | No. It is an absence of duplicate evidence. |

The test applied at each call site: could a different invocation of this same harness against this
same box have covered it? Yes means `missing`; no means `by-design`.

The class is the optional third argument and it defaults to `missing`. The default is the
pessimistic one on purpose — an unclassified skip is an unexplained absence, so it lands in the
bucket that counts. Defaulting the other way would let a real hole disappear by omission,
which is #1083's own failure mode one level up. An unrecognised class is reported loudly and
still counted as `missing`, so the class totals always reconcile with the bucket totals; a
summary whose own arithmetic does not add up misleads more than a wrong label does.

`selftest-skip-accounting.sh` holds both halves: the helpers behave, and a static census refuses
any call site that invents a class. The census is static because most of these legs fire only on a
bench with a rig attached — a typo on a leg that skips once a quarter would otherwise sit in the
tree unnoticed.

---

## The self-test (CI)

`tests/integration/selftest.sh` exercises the harness's pure logic with no server: config
rendering and value typing, expectation derivation (profile gating), secret redaction, the
SSH/local exec wrapper, JSON parsing, and matrix axis coverage. It runs in CI on every PR (the
`shell` job) and via `make test-integration-selftest`, so the harness itself is held to the
same lint/test standard as the rest of the stack.

Several self-tests sit beside it as standalone files, picked up by the same globbed target.
`selftest-skip-accounting.sh` is the one that keeps the skip accounting honest: besides checking
the counters and the real `summary()`, it censuses every harness file and fails if a skip leaves
through a bare `it_warn` — by wording, and by shape for the drops that never say "skipping".
`selftest-redact.sh` covers the shapes the redactor used to miss — a credential passed as a flag
value, an address given by POSITION in an argv line, secrets in JSON under a key of any case, and
the host's own public IP address — and asserts in each case that the *raw* value is gone rather
than that a `<redacted>` marker appeared, since a marker can come from some other field on the
same line. Its JSON population is derived from `config.reference.json` rather than
listed in the file, under a screen deliberately wider than the redactor's own list, so a sensitive
field added to the schema fails the test by name until someone classifies it as redacted or as a
stated survivor. Arrays are classified on their own account rather than by name
([#1723](https://github.com/p2pool-starter-stack/pithead/issues/1723)): an empty list yields no
element for the screen to read, and a list element's path ends in `[]`, which no suffix rule can
match, so all four of the schema's arrays sat outside that guarantee — three of them carrying
secrets the masked-config pass covers by path. Checking that pass's own path list against this
file's classification is what turned up `xvb.standby.source`, which the screen now reaches; the
check itself is not yet mechanical here. Two of those arrays hold objects, and the row for them
asserts nothing, because an empty reference gives no element to probe — so that emptiness is now
read from the schema rather than stated
([#1748](https://github.com/p2pool-starter-stack/pithead/issues/1748)). Populate one and the row
fails and asks for a reclassification; before, it went on reporting that the reference carried no
element, and an element under a name the screen does not carry reddened nothing at all. It also
guards the other direction: a sha256 digest, a non-secret flag value, the
reserved IP ranges and a HAProxy timestamp must survive, because an artifact with its image pins or
its port map stripped is useless for the triage it exists for. That timestamp is not a hypothetical
near-miss: HAProxy's `DD/Mon/YYYY:HH:MM:SS` reads as an IPv6 address, because a four-digit year
opening with a 2 supplies the first hextet and the clock supplies the colon groups. It accounted
for 278 of the 280 lines the first draft of the IP rule changed across two captured bundles, and
`lint-topology` makes the same reading of it. That file also holds the vocabulary invariant: both
of redact()'s suffix lists are read out of `lib.sh` and checked to agree with each other and to sit
inside the screen, so the drift #1611 found cannot reopen quietly. `selftest-redact-ip.sh` carries the IP shape,
including the sentinel cases: a `\x01` in the input must not reconstitute a quad, must not become a
dot, and must not disturb the protect/restore round trip that keeps the reserved ranges readable.
`selftest-redact-env.sh` carries
the `KEY=value` shape separately, including the three Tari address forms as `.env` renders them and
the survivors that make a bundle worth keeping — a public endpoint, an auth mode string, a routing
id. Its widening was measured before it shipped: across two archived bundles and the deployed
`.env` it newly reaches ten keys, the same ten in all three populations, and changes nothing at all
in the other six captured artifacts.
`selftest-redact-vocab.sh` asks the question one level out: not whether a given shape is covered,
but whether the vocabulary reaches every key that needs it. A suffix list is a denylist over a key
set that keeps growing, so it fails quietly and in the unsafe direction. The population is read out
of the single heredoc `render_env` writes, which is 129 keys, under a screen again wider than the
redactor's own list, and a credential-shaped key in neither the redacted nor the survivor list
fails by name. Measured before it shipped: four keys carried a credential and were reached by
nothing — the base64 caddy password hash, the sha256 password fingerprint, the webhook URLs, and
`DASHBOARD_AUTH_USER`, which was missed only because the list carries `USERNAME` while that key
ends in `USER`. Two more that look like the same gap are not: `XMRIG_API_AUTH` renders an enum of
`none`, `name` or `token`, and `DASHBOARD_ONION_CLIENT_AUTH` renders a boolean, so both are pinned
as survivors. A bare `AUTH` suffix would redact the pair and protect nothing, and a bare `URL`
would take every public endpoint while still missing the webhook key, which ends in `URLS`. Four
onion addresses are listed apart again, because a shape rule rather than the name rule covers them
and a name-shaped fixture would report them as leaking.
`selftest-redact-paths.sh` holds the other classification against this one. The stack masks
`config.json` by PATH, in `CONTROL_SECRET_PATHS` plus three jq stanzas for the variable-length
arrays, while `selftest-redact.sh` classifies the same document by a name screen. Two hand-kept
classifications of one document, and until [#1730](https://github.com/p2pool-starter-stack/pithead/issues/1730) nothing held them against each
other, so they drifted: `xvb.standby.source` is masked by the product and was in none of the
self-test's lists, because no suffix in either vocabulary carries the bare word `source`. It was
found by someone happening to look, which is the thing this file replaces. The check is one-way
by design — every path the product masks must be classified, never the reverse, because the
self-test classifies more than the product masks and should: the public endpoints and routing
ids are what a bundle exists to carry. The population is measured rather than parsed, since a
read of the `CONTROL_SECRET_PATHS` literal sees twelve fixed paths and misses all three array
stanzas; the file runs the real masker over a populated fixture and reads back the fifteen paths
that became `{"__secret__": true}`. A path inside an array is satisfied by its enclosing `[]`
path being classified, which is what `workers.list[].token` needs. The arming control is the
load-bearing part: `render_masked_config` warns and returns 0 when its jq fails, so a test
reading its return code greens over a document that was never written and every containment row
then passes over an empty population. The file asserts the artifact exists and holds exactly
the set of paths the fixture populated, named entry for entry, before it reads a single
verdict. One more thing a populated fixture cannot tell you on its own: a jq assignment
creates an absent path, so the presence of each populated leaf is checked against the shipped
schema first — without that row, deleting `xvb.standby` from the reference leaves every other
row green over a path the product no longer carries.
`selftest-zmq-probe.sh` drives the ZMTP verdicts from captured and hand-built wire fixtures,
so every failure class — a silent peer, a non-ZMQ listener, a ZMTP peer that is not a publisher, a
READY frame carrying a decoy `Socket-Type` value — is reachable with no socket and no stack. It
also covers the truncated and hostile frames that used to end the parser rather than be named by
it ([#1500](https://github.com/p2pool-starter-stack/pithead/issues/1500)): every length field is
read with `16#`, which is fatal on an empty string, so a peer that stalled part-way through a
header left an interpreter error on stderr and an empty verdict. Those cases assert the empty
stderr alongside the reason, because the return code was already 1 while the bug was live and a
case checking only the code would have passed against it.
`selftest-stack-sandbox.sh` reaches the other way, into the tier-1 suite's own plumbing.
`tests/stack/lib.sh` built its throwaway sandbox as `SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"`, and
`mktemp -d` prints nothing on stdout when it fails, so the inner substitution collapsed to `cd ""`
— which returns 0 without moving — and the sandbox became the directory the suite was invoked
from, which `tests/stack/run.sh` documents as the repo root. The next line then armed `rm -rf` on
the working tree, through an EXIT trap that fires at the end of a run that otherwise looked normal
([#1661](https://github.com/p2pool-starter-stack/pithead/issues/1661)). Asserting that the sourcing
failed is green against that defect, because the defective form succeeds and hands back a real
path, so the cases assert the value instead: `SANDBOX` is never the caller's directory, and a
sentinel file in that directory is still on disk once the subshell's EXIT trap has run. A case with
a working `mktemp` holds the other side, so deleting the sandbox logic outright cannot pass. The
last case drives the pre-fix expression against the same fixture and requires it to destroy the
sentinel, so a row that is green because the fixture never armed fails rather than reads as proof.

---

## Release gate (#44)

The live matrix is the required, blocking pre-release gate: a release is not promoted or
published unless it's green against the real Monero + Tari nodes. It's surfaced as `make
test-integration` and wired into the `make release` pipeline's test gate. See
[Releasing › Pre-release gate](releasing.md#pre-release-gate-54). The version tagged/published
is the exact bundle this run validated.
