# The Release / Validation Server

How a build is validated end-to-end before release, why that needs a dedicated server, what
GitHub Actions runs on every PR, and how to harden the server. Operational companion to
[Releasing](releasing.md) (the version/promote pipeline) and
[Integration Testing](integration-testing.md) (the harness it runs).

## Can GitHub Actions do the full end-to-end? (no)

GitHub-hosted runners can't do the real-chain tier. On a public repo the hosted Ubuntu runners
are free (4 vCPU / 16 GiB RAM), but they are ephemeral: a fresh VM per job, ~14 GiB of free
disk, and a 6-hour job ceiling. A Monero chain is ~95 GiB pruned / ~270 GiB full and takes days
to sync; Tari adds ~50 GiB. There is nowhere to keep that synced state between runs, and no time
to sync it inside a job. So the real-daemon, real merge-mining tier (tier 4) is not possible on
hosted runners. That's the reason a dedicated, already-synced server exists
([#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

GitHub already runs almost everything else, free, on every PR. Tiers 1–3 of the
[testing strategy](testing-strategy.md) need no real chain and run on the hosted runners in
minutes:

- Tier 1, unit/component (dashboard pytest + coverage gate, frontend, the `pithead` shell
  suite, compose interpolation, and the #90 security/hardening invariants).
- Tier 2, contract (the real Monero/Tari clients vs. controllable fakes).
- Tier 3, the fake-daemon mini-stack (the real dashboard + docker-control proxy driven against
  fake daemons, with real Docker on the hosted runner). This proves the control plane
  end-to-end (sync hold/release, reject/readmit) on every PR.

So the split is clean:

| | Runs | Cost | Triggered |
|---|---|---|---|
| **Tiers 1–3** (logic, wiring, control plane, hardening) | GitHub-hosted runners | free (public repo) | every PR, the merge gate |
| **Tier 4** (real synced Monero+Tari, real merge-mining, prune/full DB, TLS/Tor, the config matrix, the staging smoke test) | the dedicated server | your hardware | pre-release / on-demand, the release gate |

The hosted runners catch most regressions before merge. The dedicated server proves what only
real chains can, and it is the blocking pre-release gate.

## Validating PRs on the dedicated server (possible, but security-loaded)

You can register the server as a GitHub Actions self-hosted runner so Actions dispatches the
tier-4 job to it (self-hosted minutes don't count against anything, also free). But there is a
sharp edge, and it's the single most important thing on this page:

> NOTE: GitHub explicitly recommends against self-hosted runners on public repositories. Any
> user can open a pull request, and a malicious PR can run arbitrary code on the runner. The
> server holds real wallet payout addresses, Tor onion private keys, and RPC credentials, so a
> compromised runner is a key-theft / persistent-backdoor event, not a flaky build.

The safe rule: the keyed server only ever runs code you trust. Concretely:

- Do not trigger tier-4 on `pull_request` (and never on a fork PR). "Require approval" only
  gates starting the run; once it starts, the PR's code still executes on the box.
- Trigger tier-4 only on trusted code: `workflow_dispatch` (a maintainer manually runs it on a
  ref they've reviewed) and/or `push` to `main` (post-merge). To E2E a specific fork PR, a
  maintainer reviews it first, then dispatches the workflow on that ref.
- Register the runner as ephemeral / just-in-time (one job, then auto-removed) in its own runner
  group, isolated from any private repos.
- Keep the runner least-privilege: a dedicated unprivileged user, the box runs nothing else
  sensitive, and ideally the runner reaches the stack only through `pithead`/`docker`, not the
  raw key files.

This is how the workflow ships.
[`.github/workflows/release-gate.yml`](../.github/workflows/release-gate.yml) runs only on
`workflow_dispatch` (and `push` to `main`) on a `[self-hosted, pithead-release]` runner, never
automatically on a PR.

## Provisioning the server

Target an LTS Ubuntu (22.04 / 24.04). One-time:

1. Install Pithead and let it fully sync ([Getting Started](getting-started.md)): full Monero +
   full Tari, all containers healthy, a worker (ideally two) mining. The synced
   `monero.data_dir` / `tari.data_dir` are the asset the harness reuses.
2. Keep the active chain on fast storage (SSD/NVMe). monerod is random-I/O heavy, so the chain
   it runs against must not sit on a spinning HDD; that alone makes every scenario crawl. A
   snapshot/reflink-capable filesystem (btrfs/zfs/xfs reflink) is a bonus: it lets the harness
   snapshot/restore a chain cheaply for the prune axis. It's optional. On plain ext4-on-SSD the
   matrix only edits `config.json` and reuses one chain, with `--safety-backup` isolating
   destructive runs. See the recipe below for the prune-axis details.
3. Disk headroom: enough for the chains plus a snapshot / second DB (budget ≥ ~150 GiB free
   beyond the live chains).
4. Tools: `jq`, `curl`, `docker` (compose v2), `sha256sum`, `git`, `tar`.

Check the box is fit at any time, non-destructively:

```bash
tests/integration/run.sh --host you@server --dir pithead --readiness
```

It asserts: chains synced (reusable), the prune axis is exercisable (the live chain FS is
snapshot-capable **or** a pre-built variant chain is supplied), disk headroom, `.env` is
owner-only, the dashboard is bound to localhost, and the backup/rollback net is usable.

### Recipe: prune-axis coverage, and the storage that matters

Put the active chain on fast storage. The biggest factor is the disk, not the filesystem:
monerod does heavy random LMDB I/O, so a chain on a 7200 rpm HDD makes every scenario crawl.
Check what you have before placing chains:

```bash
lsblk -d -o NAME,ROTA,SIZE,MODEL   # ROTA=0 is SSD/NVMe, ROTA=1 is a spinning HDD
```

Keep the chain monerod runs against on an SSD/NVMe. A spare HDD is fine for cold backups and
`pithead backup` archives, but not for an active test chain.

A CoW filesystem (btrfs/zfs/xfs-reflink) is a bonus, not a requirement. On a CoW volume the
harness can snapshot/restore a chain cheaply for per-scenario isolation, but only if it's on
fast storage. A loopback btrfs on a spare HDD gives you CoW semantics at HDD speed, which is the
wrong trade for an active chain. If your root FS is ext4 on an SSD (the common case) you don't
need CoW at all: the matrix only edits `config.json` and reuses one chain, and `--safety-backup`
(a `pithead backup` + auto-rollback) isolates the destructive scenarios.

Covering both prune modes. The box mines one mode (its real config). The harness exercises that
mode against the live chain and skips the other unless you supply a chain for it
(`--full-data-dir` / `--pruned-data-dir`). You usually don't need to: the opposite mode is
covered by the fake mini-stack ([integration-testing](integration-testing.md)) plus the
compose/config tests, which need no real chain. Supply the opposite-mode chain only to exercise
it end-to-end, and build it on fast storage:

- Pruned chain next to a full one? [`build-pruned-chain.sh`](../tests/integration/build-pruned-chain.sh)
  copies the LMDB consistently (brief monerod stop, then immediate restart) and prunes the copy,
  leaving the canonical chain untouched. Fetch `monero-blockchain-prune` at the same version as
  the running monerod and verify it against the hash the image pins (`build/monero/Dockerfile`
  → `MONERO_VERSION` / `MONERO_HASH`).
- Full chain? Pruning is irreversible, so a full chain means a fresh full sync
  (`MONERO_PRUNE=0`, ~1–3 days), rarely worth it just for test coverage.

The reference box is a pruned node on NVMe: it validates pruned mode live with `--safety-backup`,
and full mode comes from the fakes. `--readiness` reports exactly this:

```bash
tests/integration/run.sh --host you@server --dir pithead --readiness
```

> NOTE: a pruned chain's file stays large. An in-place prune does not shrink the LMDB file: it
> stays at the full-chain high-water mark (~250 GiB) with the freed space sitting as internal
> free pages (Monero reuses them as the chain grows). To reclaim it you must rewrite the DB with
> `monero-blockchain-prune --copy-pruned-database` (see
> [`compact-chain.sh`](../tests/integration/compact-chain.sh)). It's slow (it copies every block
> over hours), though it reads through a snapshot so monerod keeps mining; you then swap the
> compact copy in during a ~2 min window. The generic `mdb_copy -c` does not work: Monero ships a
> patched LMDB and stock mdb_copy rejects the format (`MDB_VERSION_MISMATCH`). Often it's simplest
> to leave the free pages.

## Bench allocation and the rig lock

Ten boxes are shared between this repo's tier-4 harness, RigForge's release gates, and
production mining. Two automations cycling the same rig's services corrupt each other's results
(the 2026-07-10 miner-0 incident: an operator "fixed" a service an e2e run had deliberately
stopped), so ownership is static and every run takes a kernel lock.

Static allocation — each box states its owner in `/etc/bench-role`:

| Box | Owner | Use |
|---|---|---|
| miner-0 | RigForge | `e2e-real` / tune gates. Pithead never touches its services. |
| miner-1, miner-2 | Pithead | Tier-4 loaner rigs: `e2e.sh` repoints one at the test bench for a run, then reverts it. Verify `systemctl is-active xmrig` after any remote restart. |
| miner-3 … miner-7 | Production | Mining only. No test traffic. |
| gouda | Pithead | Test bench + release box (the tier-4 target). |
| pithead-prod | Production | Production stack; deploys only. |

The run lock. Both harnesses take a `flock` on `/var/lock/rig-e2e.lock` before the first
service-touching action and hold it on an inherited FD for the whole run, so the kernel releases
it the moment the run dies — `kill -9` included, no stale-lock cleanup. rigforge#183 defines the
mechanism; [#430](https://github.com/p2pool-starter-stack/pithead/issues/430) is this repo's
mirror; the shared path on every box is the protocol. Mutating runs hold it exclusive; read-only
runs (`run.sh --check` / `--readiness`) hold it shared, so concurrent readers coexist but still
exclude mutators. `tests/integration/run.sh` takes it on the target box (over SSH for `--host`);
`e2e.sh` also takes it on the loaner rig it borrows. A busy box makes the run exit 75
(`EX_TEMPFAIL`) naming the holder; set `RIG_LOCK_WAIT=1` to queue instead.
`/run/rig-e2e.holder` is a display-only sidecar naming the holder — the flock is authoritative,
and a stale sidecar is harmless.

Off-box actors (a human or an agent over SSH) touch services on a shared box only after the same
check:

```bash
ssh <box> 'flock -n -x /var/lock/rig-e2e.lock true' || ssh <box> 'cat /run/rig-e2e.holder'
ssh <box> 'cat /etc/bench-role'   # the box's static owner
```

## Hardening checklist (the pitfalls)

Treat the box as production-sensitive. It holds keys and it's the thing that signs off releases.

- Secrets. `.env` (RPC creds), `config.json` (wallet addresses), and the Tor data dir (onion
  private keys) must be owner-only (`chmod 600 .env`; the `--readiness` check verifies this).
  Never print secrets in logs; the harness hashes them on the box and redacts artifacts. If the
  box also publishes releases, the GHCR token lives in the environment / a secret store, never in
  the repo.
- Network. Firewall to least exposure: inbound SSH (key-only, no root login, fail2ban) and the
  stratum port scoped to the LAN ([workers › firewall](workers.md#firewall)); the dashboard
  stays on localhost behind Caddy and the monerod RPC on localhost (both asserted by
  `--readiness`). Nothing else should be reachable from the internet.
- Untrusted code. The runner only runs trusted code (see above). Prefer ephemeral/JIT runners;
  don't share the runner with private repos.
- Least privilege. A dedicated unprivileged user; the stack already runs least-privilege
  containers (`no-new-privileges`, `cap_drop`, read-only roots, scoped Docker socket proxies,
  regression-guarded in `tests/stack/test_compose.sh`).
- Reproducible, clean baseline. The matrix reuses the synced chains and never mutates the
  canonical copies (config-only changes, snapshot/restore for the prune axis), restores the
  original `config.json` at the end, and `--safety-backup` takes a `pithead backup` first and
  rolls the box back (down → restore → up) if anything fails.
- Build isolation and integrity. Build images in containers with pinned upstream versions and
  SHA256-verified binaries (the stack already does this); promote releases by digest so the
  published bundle is bit-for-bit what was validated ([Releasing](releasing.md)).

## How a release is validated end-to-end

1. Every PR → GitHub-hosted runners run tiers 1–3 (the merge gate). Cheap, free, fast.
2. Pre-release (or on-demand for a reviewed PR) → a maintainer dispatches the release-gate
   workflow on the dedicated server: `make test` (tiers 1–2 on the trusted box) plus the tier-4
   live matrix against the real synced nodes (`run.sh --safety-backup`), then per
   [Releasing](releasing.md) the staging smoke test (pull the GHCR images on a clean host, real
   `setup → up → status → mine` check).
3. Nothing is tagged or published until that's green, and promotion is by digest, so the version
   users get is the exact bundle the server validated.

## End-to-end coverage & gaps

What the live tier-4 gate exercises, and what it doesn't, so a release decision is made with eyes
open. (The reference box is a pruned Monero node on NVMe; its own snapshot and this table also
live at `~/pithead-testbench/` on the box, for operators and AI agents.)

Validated live (real synced chains): the config matrix (remote/local node, dashboard
secure/insecure, Tari required/optional, RPC LAN access, XvB on/off) applied + asserted; lifecycle
(restart, secret-preserving `apply`, backup→restore round-trip); node-down failover → recovery;
release readiness; pruned monerod (the real prod config). Covered without a real chain (tiers
1–3): client↔daemon contract tests, the fake-daemon mini-stack (incl. full-prune behavior),
compose hardening, config rendering, dashboard tests.

| Gap (not tested live) | Worth filling before release? |
|---|---|
| Full (unpruned) Monero live, which a pruned box can't exercise | Low. Stack paths don't differ by prune mode; fakes/config cover it. A multi-day full sync isn't justified. |
| Privacy / Tor egress: no clearnet-leak assertions in the live harness (#160) | High. Privacy is a core promise. Add egress checks (no clearnet to XvB stats, p2pool, Tari DNS). |
| Automated PR gate: the self-hosted runner is manual/opt-in | Medium-high, high-value. Wire the live harness as a required check on `workflow_dispatch`/push-to-`main` only (never fork PRs). |
| Upgrade / migration across image versions with chain continuity | Medium. Add a scenario: pull new images → `apply` → assert no re-sync + secrets intact. |
| XvB live routing end-to-end (the raffle optimization) | Medium. Core value-prop but unit/sim-tested today; a periodic live smoke test would help. |
| Multi-worker scale: the harness assumes ~2 workers | Medium. Add a load-gen worker + assert proxy routing/hashrate for perf confidence. |
| Real Tari merge-mined block acceptance | Low. Probabilistic; rely on template/connectivity checks. |
| Fault injection over SSH (currently local-mode only) | Low-Medium. Extend the SIGSTOP/remove cases to the `--host` path. |

Recommended before release: the privacy-egress checks and the automated PR gate; then the
upgrade scenario and an XvB live smoke test. The remainder are nice-to-have.
