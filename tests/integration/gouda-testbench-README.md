# Pithead reference build & test server (`gouda`)

This box runs the **live Pithead stack** (Monero node + P2Pool + Tari merge-mining + dashboard)
and is the **Tier-4 release gate**: changes are validated end-to-end here against real, synced
chains before release. It is used by **developers and AI agents** — read this first.

`system-info.md` (next to this file) is a live hardware/layout snapshot. Regenerate any time:
`~/pithead-testbench/system-info.sh > ~/pithead-testbench/system-info.md`.

## ⚠️ Golden rules — this is a PRODUCTION miner

1. **Never delete a data dir.** The synced Monero/Tari chains are the irreplaceable asset.
2. **Minimize mining downtime.** monerod stopped = no mining. Prefer no-downtime operations; when
   a stop is unavoidable keep it short and say so.
3. **Chains on NVMe, backups on HDD.** Active chains must stay on the NVMe (root LV). The `/home`
   HDD is a 7200 rpm spinner — fine for backups/cold storage, fatal for an active chain's latency.
4. **Least privilege.** `sudo` is password-protected and interactive-only — don't expect or leave
   passwordless grants. Almost everything here needs **no sudo** (your user is in the `docker` group).
5. **Secrets stay put.** `.env` (RPC creds) and `config.json` (wallet addresses) are owner-only.
   Never print, copy, or commit them.

## Where things are

| Path | What |
|---|---|
| `~/code/p2pool-starter-stack/` | the stack: `docker-compose.yml` + the `pithead` CLI |
| `~/code/p2pool-starter-stack/data/{monero,tari,p2pool,dashboard,tor}/` | chain/data dirs (NVMe) |
| `~/pithead-testbench/` | **this dir** — build-server docs + tools |
| `~/pithead-testbench/bin/monero-blockchain-prune` | verified offline Monero tool (version matches monerod) |
| `~/pithead-testbench/{build-pruned-chain,compact-chain}.sh` | chain ops (also versioned in the repo `tests/integration/`) |
| `/mnt/chains` | btrfs CoW loopback on the HDD — backups / cold storage |

## The chains (this was the confusing part)

- **Monero is PRUNED** (`MONERO_PRUNE=1`) and compacted to its true ~95 GiB. If it ever reads
  ~250 GiB again, that is **LMDB free-page bloat** from an in-place prune — *not* a full chain.
  Compact it (below). Note: the generic `mdb_copy` **cannot** read Monero's patched LMDB
  (`MDB_VERSION_MISMATCH`); only `monero-blockchain-prune` works.
- **Tari is ARCHIVAL/full** (~132 GiB, no pruning configured). That size is genuine data, not
  bloat — there is nothing to compact. Shrinking it would mean *pruning* Tari (a config change +
  re-sync), which is a product decision, not housekeeping.

**Compacting the Monero chain** (reclaim bloat; hours, but no downtime until the swap):
```bash
~/pithead-testbench/compact-chain.sh ~/code/p2pool-starter-stack/data/monero   # builds lmdb-pruned/ (monerod stays up)
# when DONE, swap it in (brief downtime):
docker stop monerod
cd ~/code/p2pool-starter-stack/data/monero && mv lmdb lmdb.bloated && mv lmdb-pruned lmdb
docker start monerod        # re-syncs the few blocks added during the copy
# confirm `pithead status` healthy, then: rm -rf lmdb.bloated
```

## Running the stack
```bash
cd ~/code/p2pool-starter-stack
./pithead status         # health summary
./pithead doctor         # deeper diagnostics
./pithead up | down | apply | backup
```

## Running the test harness (the point of this box)

Tiers 1–3 run anywhere with no real chains; **Tier 4 (the live matrix) runs here.**
```bash
# Drive gouda over SSH from a dev checkout (start non-destructive):
tests/integration/run.sh --host vijit@gouda --dir code/p2pool-starter-stack --check       # assert current live state
tests/integration/run.sh --host vijit@gouda --dir code/p2pool-starter-stack --readiness   # is the box fit to gate a release?
# Full destructive config matrix, with a pithead backup + auto-rollback on failure:
tests/integration/run.sh --host vijit@gouda --dir code/p2pool-starter-stack --safety-backup
# On the box itself:
cd ~/code/p2pool-starter-stack && tests/integration/run.sh --local --dir "$PWD" --lifecycle
```
Always start with `--check`/`--readiness`. Use `--safety-backup` for the destructive matrix so a
failure rolls the box back (down → restore → up). See `docs/integration-testing.md` in the repo.

## End-to-end coverage: validated live vs. gaps

**Validated live on gouda (Tier 4):** the config matrix (remote/local node, dashboard secure/insecure,
Tari required/optional, RPC LAN access, XvB on/off) applied + asserted on real synced chains;
lifecycle (restart, secret-preserving `apply`, backup→restore round-trip); node-down failover →
recovery; release readiness; **pruned** monerod (the real prod config).
**Covered without a real chain:** client↔daemon contract tests, the fake daemon mini-stack
(incl. full-prune behavior), compose hardening, config rendering, dashboard unit/frontend tests.

| # | Gap (not tested live) | Worth filling before release? |
|---|---|---|
| 1 | **Full (unpruned) Monero** mode live — gouda is pruned-only | **Low.** Stack code paths don't differ by prune mode (monerod-internal); fakes/config cover it. A multi-day full sync isn't justified. |
| 2 | **Privacy / Tor egress** — no clearnet-leak assertions in the live harness (issue #160) | **High.** Privacy is a core promise. Add egress checks (no clearnet to XvB stats, p2pool, Tari DNS) to the live harness. |
| 3 | **Automated PR gate** — self-hosted runner exists but is manual/opt-in | **Medium-high, high-leverage.** Wire the live harness as a required check on `workflow_dispatch`/push-to-`main` only (never fork PRs). |
| 4 | **Upgrade / migration** across image versions with chain continuity | **Medium.** Real users upgrade. Add a scenario: pull new images → `apply` → assert chain continuity + no re-sync + secrets intact. |
| 5 | **XvB live routing** end-to-end (the raffle optimization) | **Medium.** Core value-prop, but unit/sim-tested today. A periodic live XvB smoke test would help; hard to assert deterministically. |
| 6 | **Multi-worker scale** — harness assumes ~2 workers | **Medium.** For perf confidence add a load-gen worker + assert proxy routing/hashrate. Not a blocker. |
| 7 | **Real Tari merge-mined block** acceptance | **Low.** Finding a block is probabilistic; rely on template/connectivity checks. |
| 8 | **Fault injection over SSH** (currently local-mode only) | **Low-Medium.** Extend SIGSTOP/remove fault cases to the `--host` path. |

**Recommended before release:** #2 (privacy egress) and #3 (automated PR gate); then #4 (upgrade)
and #5 (XvB smoke). The rest are nice-to-have.

## Notes for AI agents
- SSH from a sandboxed agent needs the LAN allowance (e.g. `dangerouslyDisableSandbox`); gouda is on the LAN.
- **Avoid literal `( )` in remote command strings** — they break the non-interactive remote shell.
- `pkill -f <pattern>` self-matches your own command line — kill by PID, or use the `[x]`-bracket trick.
- Don't stop monerod without reason; check `docker ps` health first and narrate any downtime.
- Long jobs: launch detached (`nohup … &`) and poll a status file; SSH sessions drop.
