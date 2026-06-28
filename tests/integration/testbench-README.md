# Pithead reference build & test server

A dedicated dev + test platform that runs the live Pithead stack (Monero node + P2Pool + Tari
merge-mining + dashboard) against real, synced chains, and serves as the Tier-4 release gate —
changes are validated end-to-end here before release. This guide describes how to provision and
run your own; substitute your own host, user, and paths throughout. The examples below assume the
host is reachable over SSH as `$BENCH_HOST`.

See `docs/test-server-architecture.md` for the full architecture and how to stand a box up from
scratch.

## ⚠️ Golden rules

This is a test bench, not a production miner — downtime and teardown/redeploy are fine. The
constraints that matter:

1. **Never lose the synced chains.** They are the only slow-to-acquire asset (days to re-sync), so
   reuse them. Keep them in a data directory decoupled from the checkout (e.g. a sibling
   `pithead-data/` dir) so you can refresh or redeploy the stack without touching them.
2. **Chains on fast storage, OS on its own disk.** Put the chains on an NVMe SSD — monerod's LMDB
   is random-read heavy, so it opens a multi-hundred-GB database in seconds there and crawls on a
   slow SATA SSD or HDD. Mount the chain volume by UUID with `noatime` and `nofail`. Keep the OS
   and Docker on a separate disk so a chain-volume problem can't take the box down.
3. **Least privilege.** Keep `sudo` password-protected and interactive — don't leave passwordless
   grants lying around. Almost nothing here needs sudo if your user is in the `docker` group.
4. **Secrets stay put.** `.env` (RPC creds) and `config.json` (wallet addresses) are owner-only.
   Never print, copy, or commit them.

## Where things are

A workable layout (adjust to taste):

| Path | What |
|---|---|
| `<checkout>/` (e.g. `/srv/code/pithead`) | the stack checkout: `docker-compose.yml`, the `pithead` CLI, your `config.json`/`.env` |
| `<data-dir>/{monero,tari,p2pool,dashboard,tor}/` (e.g. `/srv/code/pithead-data`) | the chains — the asset, on the NVMe, decoupled from the checkout |
| `<tools-dir>/` | build-server docs and chain-ops tools (the `*.sh` helpers are also versioned in the repo under `tests/integration/`) |
| `<tools-dir>/bin/monero-blockchain-prune` | the verified offline Monero tool, version-matched to monerod |

## The chains

- **Monero is pruned** (`MONERO_PRUNE=1`) and compacted to its true size (~95 GiB). If it ever
  reads back up near ~250 GiB, that is LMDB free-page bloat from an in-place prune, not a full
  chain — compact it (below). The generic `mdb_copy` cannot read Monero's patched LMDB
  (`MDB_VERSION_MISMATCH`); only `monero-blockchain-prune` works.
- **Tari is archival/full** (~132 GiB, no pruning configured). That size is genuine data, not
  bloat, so there is nothing to compact. Shrinking it would mean pruning Tari (a config change plus
  re-sync), which is a product decision, not housekeeping.

**Compacting the Monero chain** (reclaim bloat; takes hours, but no downtime until the swap):

```bash
tests/integration/compact-chain.sh <data-dir>/monero   # builds lmdb-pruned/ (monerod stays up)
# when DONE, swap it in (brief downtime):
docker stop monerod
cd <data-dir>/monero && mv lmdb lmdb.bloated && mv lmdb-pruned lmdb
docker start monerod        # re-syncs the few blocks added during the copy
# confirm `pithead status` healthy, then: rm -rf lmdb.bloated
```

## Running the stack

```bash
cd <checkout>
./pithead status         # health summary
./pithead doctor         # deeper diagnostics
./pithead up | down | apply | backup
```

## Running the test harness (the point of this box)

Tiers 1–3 run anywhere with no real chains; Tier 4 (the live matrix) runs here.

```bash
# Drive the test bench over SSH from a dev checkout (start non-destructive):
tests/integration/run.sh --host "$BENCH_HOST" --dir <checkout> --check       # assert current live state
tests/integration/run.sh --host "$BENCH_HOST" --dir <checkout> --readiness   # is the box fit to gate a release?
# Full destructive config matrix, with a pithead backup + auto-rollback on failure:
tests/integration/run.sh --host "$BENCH_HOST" --dir <checkout> --safety-backup
# On the box itself:
cd <checkout> && tests/integration/run.sh --local --dir "$PWD" --lifecycle
```

Always start with `--check`/`--readiness`. Use `--safety-backup` for the destructive matrix so a
failure rolls the box back (down → restore → up). See `docs/integration-testing.md`.

## End-to-end coverage: validated live vs. gaps

**Validated live (Tier 4):** the config matrix (remote/local node, dashboard secure/insecure, Tari
required/optional, RPC LAN access, XvB on/off) applied and asserted on real synced chains;
lifecycle (restart, secret-preserving `apply`, backup→restore round-trip); node-down failover and
recovery; release readiness; pruned monerod (the common production config).

**Covered without a real chain:** client↔daemon contract tests, the fake-daemon mini-stack
(including full-prune behavior), compose hardening, config rendering, dashboard unit/frontend tests.

| # | Gap (not tested live) | Worth filling before release? |
|---|---|---|
| 1 | Full (unpruned) Monero mode live — a pruned bench can't cover it | Low. Stack code paths don't differ by prune mode (it's monerod-internal); fakes/config cover it. A multi-day full sync isn't justified. |
| 2 | Privacy / Tor egress — clearnet-leak assertions in the live harness (issue #160) | High. Privacy is a core promise. Assert no clearnet to XvB stats, p2pool, or Tari DNS. |
| 3 | Automated PR gate — a self-hosted runner is manual/opt-in | Medium-high, high-leverage. Wire the live harness as a required check on `workflow_dispatch`/push-to-`main` only (never fork PRs). |
| 4 | Upgrade / migration across image versions with chain continuity | Medium. Real users upgrade. Add a scenario: pull new images → `apply` → assert chain continuity, no re-sync, secrets intact. |
| 5 | XvB live routing end-to-end (the raffle optimization) | Medium. Core value-prop, but unit/sim-tested today. A periodic live XvB smoke test would help; hard to assert deterministically. |
| 6 | Multi-worker scale — the harness assumes ~2 workers | Medium. For perf confidence add a load-gen worker and assert proxy routing/hashrate. Not a blocker. |
| 7 | Real Tari merge-mined block acceptance | Low. Finding a block is probabilistic; rely on template/connectivity checks. |
| 8 | Fault injection over SSH (currently local-mode only) | Low-Medium. Extend the SIGSTOP/remove fault cases to the `--host` path. |

**Recommended before release:** #2 (privacy egress) and #3 (automated PR gate); then #4 (upgrade)
and #5 (XvB smoke). The rest are nice-to-have.

## Notes for AI agents

- SSH from a sandboxed agent needs the LAN allowance (e.g. `dangerouslyDisableSandbox`) when the
  test bench is on the LAN.
- Avoid literal `( )` in remote command strings — they break the non-interactive remote shell.
- `pkill -f <pattern>` self-matches your own command line — kill by PID, or use the `[x]`-bracket trick.
- Don't stop monerod without reason; check `docker ps` health first and narrate any downtime.
- Long jobs: launch detached (`nohup … &`) and poll a status file; SSH sessions drop.
