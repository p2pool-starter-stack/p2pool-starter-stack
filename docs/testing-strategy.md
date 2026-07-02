# Testing Strategy

Maps every runtime situation the stack can be in to the tier that proves it. This is the map
behind the [integration suite](integration-testing.md); read that for how to run the live matrix,
and this for what is tested where.

The stack's runtime behaviour is a state machine: syncing → held → released; healthy → down →
rejected → recovered → readmitted; XvB tiers; container health. A healthy, already-synced box only
shows one corner of it, so the rest is simulated at the cheapest tier that can prove each
situation honestly.

## The four tiers

| Tier | What it is | Simulates | Where it runs |
|---|---|---|---|
| **1 — Unit** | `build/dashboard/tests/` (pytest, mocked clients) and `tests/stack/` (shell, `docker`/`sudo` stubbed) | Decision logic & field mapping: sync-gate, failover, node-health debounce, XvB engine, `/api/state` shapes, `pithead` config/status logic | Every PR (`make test`) |
| **2 — Contract** | `tests/integration/fakes/test_contract.py` | The real Monero/Tari **clients** parsing the real daemons' wire format — points the actual clients at controllable fakes | Every PR (docker-free) |
| **3 — Mini-stack** | `tests/integration/mini-stack/` (real dashboard + docker-control vs fake daemons) | The control plane **end-to-end with real containers**: hold/release and reject/readmit actually stopping/starting `p2pool`/`xmrig-proxy`, driven deterministically | CI with Docker (`make test-mini-stack`) |
| **4 — Live matrix** | `tests/integration/run.sh` against a real, synced box | What only reality proves: real merge-mining, prune/full DB size, Caddy TLS, Tor onions, HugePages, plus fault injection for real container health verdicts | Manual / release gate (`make test-integration`) |

Stubs do most of the work. The dashboard unit tests drive the hard runtime states with mocked
clients; more mocks for the same logic would duplicate them. What stubs can't prove is wiring:
that the real clients parse real daemon output (tier 2), that the dashboard's stop/start moves
real containers (tier 3), and that real daemons sync/merge-mine and real containers go unhealthy
(tier 4). So: stubs for logic, controllable fake daemons for the control-plane wiring, the real
box for the irreducibly-real. Each situation is tested once, at the lowest tier that is honest.

The fakes are the enabler. The whole control plane is env-configurable (`MONERO_RPC_URL`,
`TARI_GRPC_ADDRESS`, `DOCKER_CONTROL_URL`, `NODE_DOWN_AFTER_SEC`, `UPDATE_INTERVAL`, …), so the
real code points at small controllable servers and drives the entire state machine in seconds, in
CI, with no chain and no test box.

## Scenario catalog

Every situation, its trigger, and the tier(s) that cover it. ✅ = covered today; ▶ = exercised by
the live matrix / mini-stack when run.

### A. Configuration permutations

The deploy-time axes — each changes a real runtime path. Full table and assertions in
[Integration Testing › The config matrix](integration-testing.md#the-config-matrix).

| Situation | Trigger | Tier |
|---|---|---|
| `monero.mode` local vs remote (monerod present/absent, profile gating) | config | 4 ▶ |
| `monero.prune` pruned vs full (DB size, #32 display) | config | 1 ✅ (display) · 4 ▶ (real DB) |
| `monero.rpc_lan_access`, `dashboard.secure`, `xvb.enabled`, `dashboard.tari_required` | config → `.env`/Caddyfile | 4 ▶ |
| `p2pool.pool` main / mini / nano (sidechain, flags) | config | 4 ▶ |

### B. Sync lifecycle (#35)

| Situation | Trigger | Tier |
|---|---|---|
| Cold start, chains syncing → **hold** `p2pool`+`xmrig-proxy` | both `is_syncing` | 1 ✅ · 3 ▶ |
| Monero synced, Tari **required** but still syncing → keep holding | `monero_synced ∧ ¬tari_synced ∧ TARI_REQUIRED` | 1 ✅ (added) · 3 ▶ |
| Monero synced, Tari **non-blocking** → release, passive Tari badge (#51) | `¬TARI_REQUIRED` | 1 ✅ · 4 ▶ |
| Both synced → **release** (one-way latch) | gate satisfied | 1 ✅ · 3 ▶ |
| Network-height UI override doesn't deadlock the gate | p2pool held → height 0 | 1 ✅ |
| Restart mid-sync / post-release (latch persisted) | snapshot reload | 1 ✅ |

### C. Node health & failover (#31)

| Situation | Trigger | Tier |
|---|---|---|
| monerod down → **reject workers** (stop `xmrig-proxy`) | unreachable ≥ `NODE_DOWN_AFTER_SEC` | 1 ✅ · 3 ▶ · 4 ▶ |
| Tari down + required → reject; Tari down + non-blocking → **ignore** | `tari_down ∧ TARI_REQUIRED?` | 1 ✅ |
| Recovery hysteresis — readmit only after stable `NODE_RECOVERY_AFTER_SEC` | reachable again | 1 ✅ |
| Transient blip / never-reachable → **no** false reject | debounce / `ever_up` | 1 ✅ |
| Double outage; readmit only when **both** healthy | both down → both up | 1 ✅ (added) |
| #35 latch × #31 failover coexist after release | down post-release | 1 ✅ (added) · 3 ▶ |
| Stop/start fails → retry next cycle (idempotent) | docker error | 1 ✅ |

### D. Container health verdicts (`pithead status`)

| Situation | Trigger | Tier |
|---|---|---|
| All healthy → exit 0 | steady state | 1 ✅ · 4 ▶ |
| Required node **down** / **missing** → exit 1 | stop / `rm` monerod | 1 ✅ (node-down) · 4 ▶ (`--fault-injection`) |
| Running but **unhealthy** → exit 1 | healthcheck fails (SIGSTOP) | 4 ▶ (`--fault-injection`) |
| Miner stopped under sync-hold / failover → exit **0** (intentional) | held / rejected | 1 ✅ · 4 ▶ |
| Remote mode ignores monerod | profile off | 1 ✅ · 4 ▶ |

### E. XvB switching engine

| Situation | Trigger | Tier |
|---|---|---|
| Disabled / zero shares / `fail_count ≥ 3` / no sustainable tier → P2POOL | guards | 1 ✅ |
| Closed-loop ramp/back-off, cold-start seed, VIP-reserve anti-overshoot (#70) | controller | 1 ✅ |
| P2POOL / XVB / SPLIT modes, tiers, smart-sleep early exit | decision | 1 ✅ |
| Real XvB endpoint reachable / failing | network | 4 (real endpoint) |

### F. Dashboard `/api/state` field states

| Situation | Trigger | Tier |
|---|---|---|
| sync state loading/syncing/done; pruned/full/unknown; db_size | metrics | 1 ✅ |
| badges (node-down, workers-rejected, miner-held, passive-Tari, pruned/full, low-HR) | metrics | 1 ✅ |
| system levels (cpu/mem/disk/hugepages), worker pool/online, chart outage breaks | metrics | 1 ✅ |
| Dashboard reads correct live state on a real stack | real daemons | 4 ▶ |

### G. CLI lifecycle (`pithead`)

| Situation | Trigger | Tier |
|---|---|---|
| Config validation, secret preservation, `apply` no-op/destructive guards | sourced fns | 1 ✅ |
| `setup`→`up`→`status`→`apply`→`restart`→`down`; idempotency; secret preservation | real box | 4 ▶ (`--lifecycle`) |
| `upgrade` (image pull/rebuild) | real box | release staging smoke (docs) |
| `backup`/`restore`, `reset-dashboard`, `doctor` | real box | 1 ✅ (partial) · 4 (future) |

### H. Host / infrastructure (real-only)

| Situation | Trigger | Tier |
|---|---|---|
| Real merge-mining share lands; real hashrate on dashboard | live mining | 4 ▶ |
| Caddy TLS scheme; Tor onion provisioning; HugePages/AVX2; real disk pressure; prune DB size | real host | 4 ▶ |

## Running each tier

```bash
make test                 # tiers 1 + 2 (+ harness self-test) — every-PR, no docker/server
make test-fakes           # tier 2 contract test on its own
make test-mini-stack      # tier 3 — needs docker
make test-integration ARGS="--host user@box --dir pithead --lifecycle --fault-injection"  # tier 4
```

## Production-readiness posture

What gates a merge vs. a release, the standards every test holds to, and the known gaps. The full
enumerated coverage is in the generated [Test Inventory](test-inventory.md), kept current by a CI
drift check.

### What runs where

| Check | Tier | When | Blocking? |
|---|---|---|---|
| Dashboard pytest + **≥80% coverage gate** | 1 | every PR | ✅ required |
| Frontend logic (`node --test`) | 1 | every PR | ✅ required |
| Dashboard image test stage (in-container) | 1 | every PR | ✅ required |
| `pithead` shell suite + shellcheck | 1 | every PR | ✅ required |
| Compose interpolation + **security/hardening** invariants | 1 | every PR | ✅ required |
| Fake-daemon **contract test** | 2 | every PR | ✅ required |
| Integration harness **self-test** | 4 | every PR | ✅ required |
| **Test-inventory drift** check | — | every PR | ✅ required |
| Fake-daemon **docker mini-stack** | 3 | PRs touching the harness/dashboard | ✅ (own workflow) |
| **Live config matrix** on real nodes | 4 | manual / pre-release | ✅ **release gate** ([#44](https://github.com/p2pool-starter-stack/pithead/issues/44)) |

The first three tiers run on every PR with no special infrastructure. Tier 4 is the blocking
pre-release gate (see [Releasing](releasing.md)) because it needs the real synced nodes.

### Engineering standards

Every scenario, at every tier, holds to the same rules.

- Deterministic, no sleep-and-hope. Wait on real readiness signals — container health,
  `pithead status`, dashboard sync %, miner-released — with timeouts. The only fixed sleeps are
  poll intervals and the deliberate "stays in state" windows that prove the gate does not act
  prematurely.
- Isolated and idempotent. Each scenario starts from a known baseline and restores it. The live
  matrix snapshots `config.json` and reuses (never mutates) the canonical chain dirs; the
  mini-stack tears down with `down -v`.
- Actionable failures. Per-scenario pass/fail, continue-on-error to collect the whole matrix, and
  artifact capture (redacted logs, `compose ps`, `.env`-minus-secrets, dashboard responses) on
  failure.
- Secrets hygiene. Tokens, RPC creds, and onions are never printed; preservation is checked by
  hashing on the box; all artifacts pass a redactor.
- Reproducible. The live run records a manifest (stack `VERSION`, git rev, image digests).
- Test code is real code. The same lint (shellcheck), coverage gate, and inventory drift check
  apply to the tests themselves.

### Flake policy

Integration scenarios quarantine, never blind-retry. A scenario that fails intermittently is
marked and investigated, not wrapped in a retry loop that hides a real race. The waiters have wide
timeouts so a slow-but-correct stack passes while a broken one fails fast with artifacts.

### Known gaps

Not yet covered. The road to full production confidence.

- First green run on real hardware. ✅ Two of the three real-environment tiers are green: the live
  harness `--check` (tier 4 read path, 22/22 against a synced, mining box) and the fake-daemon
  mini-stack (tier 3, 11/11 on a real Docker host). Between them they surfaced and fixed four bugs:
  the dashboard pruned/full label (#32); the harness's three over-strict assertions (monero-synced,
  conns, prune display); the fake Tari binding gRPC to loopback; and the mini-stack's
  container-name/port isolation. Still pending: the full destructive config matrix run on the box
  (its read path is already proven via `--check`).
- Destructive-matrix safety. ✅ `run.sh --safety-backup` takes a real `pithead backup` before the
  destructive scenarios and automatically rolls the box back (down → restore → up) if anything
  fails; the archive is removed on success. So the matrix can run on a precious box with a
  one-command rollback net.
- CLI breadth in automation. ✅ `backup`/`restore` are now exercised end-to-end: by
  `--safety-backup` and by a `--lifecycle` backup→restore round-trip (assert the pool reverts and
  secrets survive). `reset-dashboard` and `upgrade` are still only unit-covered (upgrade belongs to
  the release staging smoke test, since it rebuilds/pulls the bundle under test).
- Soak / longevity. No multi-hour run asserting no leaks, no log/DB growth runaway, and that the
  XvB controller converges over a realistic window.
- Load / capacity. No test drives many workers or high share rates to find limits.
- Security review. The compose hardening invariants are regression-guarded (the #90 section of
  `tests/stack/test_compose.sh`: RPC creds never in a healthcheck command,
  `no-new-privileges` / `cap_drop` on the leaf containers, the Docker socket proxies stay
  least-privilege), so a past fix can't be silently undone. A full security audit is still a
  separate exercise (`SECURITY.md`). These tests pin the decisions we've already made; they don't
  find new ones.

### Coverage-audit follow-ups (2026-06)

A source-vs-tests audit added Tier-1 coverage for a real bug (snapshot serialization failure left
the #131 persistence badge green), the firewall install-failure rollback (#270), the wallet
hard-fail guards (#250), remote-host/subnet validation (#180), `ensure_owner`'s whole-tree scan
(#255), and several dashboard render branches (per-worker api/reject badges, XvB/Unknown pool
badges, the #278/#313 Tari-✔ invariant, `Gauge` done vs syncing). The gaps it surfaced that are
**not yet covered at an automatable tier** — all needing Docker or the real box, so they land at
tier 3/4:

- **Firewall rollback, real kernel.** ✅ Now a tier-4 `--fault-injection` case: it shadows `iptables`
  with a wrapper that fails every `-I` insert, re-runs `apply_tor_egress_firewall`, and asserts the
  box ends fail-closed (no `pithead-tor-egress` rule left half-installed), then reinstates the real
  firewall. The tier-1 stubbed test proves the control flow; this proves the real-kernel strip.
  Runs at the release gate only (destructive-then-restored, local box).
- **`ensure_owner` real mixed-ownership tree.** ✅ Now a tier-4 `--lifecycle` step: it plants a
  root-owned file under the dashboard data dir and asserts the pool-flip `apply` (which runs
  `ensure_directories` → `ensure_owner`) chowns it to uid 1000 — the #255 "scan contents, not just
  the dir" regression. Runs at the release gate only (needs root to create a foreign-uid inode).
- **Real-container monerod failover in PR CI.** The primary-node reject/readmit cycle only runs on
  the manual tier-4 box (`--fault-injection`); the mini-stack (tier 3) breaks Tari, not monerod.
- **Non-blocking-Tari "ignore" path with real containers.** Unit-tested only; the mini-stack proves
  Tari-down-while-required (reject) but never Tari-down-while-optional (keep mining). This is the
  path that silently kills yield if it regresses to a reject.
- **monerod busy / mid-reorg failover.** The contract test proves the client reads a busy node as
  unreachable; no mini-stack or fault-injection scenario asserts the dashboard actually rejects
  workers on a busy-but-alive node (a real reorg state, distinct from a clean stop).
- **Double outage, both-must-recover.** Unit-tested (monerod ∧ Tari down → readmit only when both
  healthy); never driven with real containers, so the recovery ordering is unproven end-to-end.
- **Partial-start / stop-failure idempotency.** The control loop's "container fails to start/stop →
  retry next cycle" is unit-only; no tier-3/4 scenario injects a docker start/stop error.
- **`pithead doctor` on a real box.** Only its exit code is unit-tested; its NTP/clock-drift check
  (mining is time-sensitive) is never fault-injected or asserted at tier 4.
- **Disk-full / ENOSPC verdict.** Only a disk-headroom *warning* is checked; a real
  container-unhealthy-on-ENOSPC verdict is never forced, though the disk badge + db-write-error
  paths are unit-tested.
- **Tor-container-down partial start.** No Caddy/Tor services exist in the mini-stack compose, so
  "what happens when the Tor container is down" (SOCKS unreachable) is exercised at no tier below
  the manual real box; every all-Tor egress assertion is read-path only.
- **Insecure + main matrix row.** `dashboard.secure=false` only ever pairs with `p2pool.pool=nano`,
  so the Caddy-scheme / bind assertions for insecure mode are entangled with the nano path; an
  insecure+main regression has no row.

## Adding a scenario

- Logic (a new decision/branch) → a unit test (tier 1). Cheapest, fastest.
- A new daemon state the clients must parse → extend the fakes plus the contract test (tier 2), and
  it becomes drivable in the mini-stack (tier 3).
- A config axis → one row in `tests/integration/scenarios.sh` (tier 4). The self-test enforces
  every axis value is covered.
- A failure mode needing real containers → a fault in `run.sh`'s fault-injection phase (tier 4)
  and/or a mini-stack scenario (tier 3).

Keep each situation at the lowest honest tier; don't re-prove logic with a heavier harness.
