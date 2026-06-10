# Pithead reference build & test server (`gouda`)

A dedicated **dev + AI-agent test platform** that runs the **live Pithead stack** (Monero node +
P2Pool + Tari merge-mining + dashboard) against real, synced chains, and serves as the **Tier-4
release gate** — changes are validated end-to-end here before release. Read this first.

See **`docs/test-server-architecture.md`** in the repo for the full architecture + how to recreate
this box on another machine. `system-info.md` (next to this file) is a live hardware snapshot:
regenerate with `~/pithead-testbench/system-info.sh > ~/pithead-testbench/system-info.md`.

## ⚠️ Golden rules

This is a **test bench, not a production miner** — downtime and teardown/redeploy are fine. The
constraints that matter:

1. **Never lose the synced chains.** They are the only slow-to-acquire asset (days to re-sync) —
   reuse them. They live at `/srv/code/pithead-data/`, decoupled from the checkout, so you can
   refresh/redeploy the stack freely without touching them.
2. **Storage: chains on NVMe, OS on SATA.** A **4 TB WD SN850X m.2 PCIe NVMe** (`/dev/nvme0n1`) holds
   the chains at `/srv/code/pithead-data` (`/dev/nvme0n1p1`, ext4, `noatime`, fstab by UUID with
   `nofail`) — monerod opens the ~266 GB LMDB in seconds. The original SATA "SSD" (`sdb`, ~37–98 MB/s,
   HDD-class) now carries only the OS + Docker; the `/home`/`/mnt/chains` HDD stays cold storage. See
   `docs/test-server-architecture.md` for the migration notes + the disk-bus caveat.
3. **Least privilege.** `sudo` is password-protected and interactive-only — don't expect or leave
   passwordless grants. Almost everything here needs **no sudo** (your user is in the `docker` group).
4. **Secrets stay put.** `.env` (RPC creds) and `config.json` (wallet addresses) are owner-only.
   Never print, copy, or commit them.

## Where things are

| Path | What |
|---|---|
| `~/code/pithead/` (`/srv/code/pithead`, SATA SSD) | the stack checkout: `docker-compose.yml`, the `pithead` CLI, your `config.json`/`.env` |
| `/srv/code/pithead-data/{monero,tari,p2pool,dashboard,tor}/` | the chains — **the asset**, on the NVMe, decoupled from the checkout |
| `~/pithead-testbench/` | **this dir** — build-server docs + tools |
| `~/pithead-testbench/bin/monero-blockchain-prune` | verified offline Monero tool (version matches monerod) |
| `~/pithead-testbench/{build-pruned-chain,compact-chain,system-info}.sh` | chain ops + system snapshot (also versioned in the repo `tests/integration/`) |
| `/home`, `/mnt/chains` | HDD — cold backups / archives only |

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
~/pithead-testbench/compact-chain.sh /srv/code/pithead-data/monero   # builds lmdb-pruned/ (monerod stays up)
# when DONE, swap it in (brief downtime):
docker stop monerod
cd /srv/code/pithead-data/monero && mv lmdb lmdb.bloated && mv lmdb-pruned lmdb
docker start monerod        # re-syncs the few blocks added during the copy
# confirm `pithead status` healthy, then: rm -rf lmdb.bloated
```

## Running the stack
```bash
cd ~/code/pithead
./pithead status         # health summary
./pithead doctor         # deeper diagnostics
./pithead up | down | apply | backup
```

## Running the test harness (the point of this box)

Tiers 1–3 run anywhere with no real chains; **Tier 4 (the live matrix) runs here.**
```bash
# Drive gouda over SSH from a dev checkout (start non-destructive):
tests/integration/run.sh --host vijit@gouda --dir code/pithead --check       # assert current live state
tests/integration/run.sh --host vijit@gouda --dir code/pithead --readiness   # is the box fit to gate a release?
# Full destructive config matrix, with a pithead backup + auto-rollback on failure:
tests/integration/run.sh --host vijit@gouda --dir code/pithead --safety-backup
# On the box itself:
cd ~/code/pithead && tests/integration/run.sh --local --dir "$PWD" --lifecycle
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
