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
| **4 — Live matrix** | `tests/integration/run.sh` against a real, synced box — and, for the appliance channel, `tests/os/run.sh`, the KVM battery for the flashed image | What only reality proves: real merge-mining, prune/full DB size, Caddy TLS, Tor onions, HugePages, fault injection for real container health verdicts — and, for the image, EFI boot, A/B commit/rollback, install-to-disk | Manual / release gate (`make test-integration`; the battery on the KVM bench) |

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
| `network.subnet` moved off the default /24 (#180/#201): docker bridge, Tor render-at-start IP, monerod proxy IP, SSRF CIDR, onion vhost gateway | config → live (a subnet move needs a down/up) | 1 ✅ (rendered compose) · 4 ▶ (`run.sh --subnet`) |

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
| monerod busy / mid-reorg (HTTP 200, `status≠OK`) → **reject workers** | RPC answers but distrusted | 1 ✅ · 3 ▶ |
| Tari down (required or not) → **never rejects**; p2pool keeps mining Monero (#897) | `tari_down` | 1 ✅ · 3 ▶ |
| Recovery hysteresis — readmit only after monerod stable `NODE_RECOVERY_AFTER_SEC` | reachable again | 1 ✅ |
| Transient blip / never-reachable → **no** false reject | debounce / `ever_up` | 1 ✅ |
| Double outage; readmit follows monerod alone — Tari's state doesn't gate it either way | both down → monerod up | 1 ✅ (added) · 3 ▶ |
| #35 latch × #31 failover coexist after release | down post-release | 1 ✅ (added) · 3 ▶ |
| Stop/start fails → retry next cycle (idempotent) | docker error | 1 ✅ |
| `dashboard.fail_closed` (#490): default off never holds on an unrecoverable failure (alert-only); `true` holds (reusing #35's stop/start), releases once it clears (not a one-way latch), no-op before the sync gate releases | `is_db_unrecoverable() ∨ containers.is_confirmed_bad("dashboard")` | 1 ✅ · 3 ▶ |

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
| Actuated run-loop duty: split remainder dwell honored, steady state at tier + cushion (#423) | wall-clock sim | 1 ✅ |
| P2POOL / XVB / SPLIT modes, tiers, smart-sleep early exit | decision | 1 ✅ |
| Real XvB endpoint reachable / failing | network | 4 (real endpoint) |
| Credited 1h/24h averages converge to tier on live XvB (soak) | live donation | 4 (real endpoint) |

### F. Dashboard `/api/state` field states

| Situation | Trigger | Tier |
|---|---|---|
| sync state loading/syncing/done; pruned/full/unknown; db_size | metrics | 1 ✅ |
| badges (node-down, workers-rejected, miner-held, passive-Tari, pruned/full, low-HR) | metrics | 1 ✅ |
| system levels (cpu/mem/disk/hugepages), worker pool/online, chart outage breaks | metrics | 1 ✅ |
| dashboard DB writes failing → `db_healthy:false` (#131) | data dir read-only | 1 ✅ (flag logic) · 4 ▶ (`--fault-injection`, #202) |
| `/metrics` Prometheus exposition (#379), through Caddy + basic_auth | scrape | 1 ✅ (format) · 4 ▶ (`--check`) |
| `share_stats` series populated on a mining box (#116) | polls land | 1 ✅ (shape) · 4 ▶ (`--check`) |
| Confirmed running earnings (#787): yesterday as a **calendar** day vs the trailing 24h/7d/30d spans, the DST-length day boundary, partial marking when a window outruns the recorded payout history, and one roll-up feeding both the dashboard card and `/earnings` | stored payouts | 1 ✅ (`test_earnings.py`, `test_telegram_commands.py`, `components.test.mjs`) |
| Expected-vs-actual earnings summary (#808/#817): one shared 30d window, the combined Monero+XvB row (estimate folded on the expected side because win payouts are inseparable on the actual side), per-stream gates and honest degradation, Tari block counts, XvB win windowing, and the card's render branches in both views | metrics + stored payouts | 1 ✅ (`test_views.py` `TestEarningsVsActual`, `test_metrics.py`, `components.test.mjs`) |
| Dashboard reads correct live state on a real stack | real daemons | 4 ▶ |

### G. CLI lifecycle (`pithead`)

| Situation | Trigger | Tier |
|---|---|---|
| Config validation, secret preservation, `apply` no-op/destructive guards | sourced fns | 1 ✅ |
| `setup`→`up`→`status`→`apply`→`restart`→`down`; idempotency; secret preservation | real box | 4 ▶ (`--lifecycle`) |
| `upgrade` (image pull/rebuild) | real box | release staging smoke (docs) |
| `backup`/`restore`, `reset-dashboard` | real box | 1 ✅ (partial) · 4 ▶ (`--lifecycle`/`--safety-backup`) |
| `doctor` runtime verdicts (#383): egress firewall, stratum listening, dashboard answers | real box | 1 ✅ (stubbed toolchain) · 4 ▶ (`--check`) |
| Control channel (#33): `apply --dry-run` preview, runner claim/validate/commit, fail-closed flag, rw/ro spool mounts | spool files / sourced fns | 1 ✅ (shell + pytest + compose) · 4 (systemd path unit on a real box — not yet a matrix row) |
| Audit + access logs (#349): key-names-not-values audit entries, bounded log growth, Caddyfile log block, hostile log content served inert | spool/log fixtures | 1 ✅ (shell + pytest + node) · 4 (real Caddy writes over Tor — covered by the same onion matrix row) |
| Out-of-band audit detection + persistence (#530): a `config.json` change with no matching commit (`host-edit`) or a rig reporting a change_id the dashboard never spooled (`rig-edit`) both append to the durable `audit_events` table (mirrored `control.log` rows + these two kinds); Security panel hour/day/month grouping | poll-loop diff / real StateManager | 1 ✅ (`test_data_service.py::TestWatchHostConfig`/`TestRigEditDetection`/`TestMirrorControlAudit`, `test_storage_service.py::TestAuditEvents`, `securityview.test.mjs` grouping) · 4 (deferred — the underlying rig-side-edit-visible-in-the-enriched-feed mechanism is already proven live by the #516 row below; a real box producing a `host-edit`/`rig-edit` audit row end-to-end is not yet its own matrix leg) |

### H. Host / infrastructure (real-only)

| Situation | Trigger | Tier |
|---|---|---|
| Real merge-mining share lands; real hashrate on dashboard | live mining | 4 ▶ |
| Caddy TLS scheme; Tor onion provisioning; HugePages/AVX2; real disk pressure; prune DB size | real host | 4 ▶ |

### I. RigForge worker ↔ Pithead contract (#209)

The two repos share three seams: mining on the proxy's `:3333`, the enriched worker API on the
rig's `:8081`, and the stratum-auth handshake. Each behaviour sits at the lowest tier that proves
it — the worker-API **auth model is the #315 none/name/token matrix**, not the old single
`Bearer <rig name>`.

| Situation | Trigger | Tier |
|---|---|---|
| Worker-API auth header per mode (none/name/token), per-worker token override, SSRF guard rejects a miner-IP/name host | `XMRigWorkerClient` logic | 1 ✅ (`test_xmrig_client`) |
| Real client authenticates + parses the enriched `/1/summary` over a real socket — none/name/token matrix, wrong-token 401, miner-down body (rigforge#99 shape) | real client vs fake worker API | 2 ✅ (`fakes/fake_worker_api.py` + `test_contract.py`) |
| Dashboard parses proxy `/workers` rows → worker list + hashrate aggregation; offline drop-off window | metrics / `worker_presence` | 1 ✅ |
| `p2pool.stratum_password` renders `--access-password` (set) / omits it (default-off) | `pithead` render | 1 ✅ (`tests/stack`) · 4 ▶ (default-off live check) |
| Proxy restart / node-down → reject → readmit (real containers) | control plane | 3 ▶ (mini-stack) |
| Real worker mines through the real proxy: appears via its stratum name, hashrate aggregates, backup-pool failover | live rig + proxy | 4 ▶ (`run.sh --workers`) |
| Enriched read survives a populated masked-token descriptor — `api_ok` + rigforge feed resolve with `workers.list[].token` (#506; `dashboard.workers[]` legacy fallback) seen only as the `{"__secret__":true}` sentinel (the v1.5.2 regression + #508) | live rig + `workers.list[]` populated | 4 ▶ (`run.sh --rigforge-control`, #514) |
| Worker Inspect edit lands on the rig: `editable` true, a `max_temp_c` nudge via `/api/control/worker-apply` hits the rig's `/status` + records history, reverted | live rig control API on | 4 ▶ (`run.sh --rigforge-control`, #513) |
| Rig-side edit reflects: a direct rig control-API change shows in the enriched feed; a `config.json` hand-edit shows in the masked prefill | live rig + direct dial | 4 ▶ (`run.sh --rigforge-control`, #516) |
| Control-apply auto-rollback (rigforge#236): a hashrate-tanking change is recorded `rolled_back` in the worker-apply result + per-worker history | live rig + fault-injection | 4 ▶ (`run.sh --rigforge-control`, #517; operator supplies `IT_RIG_ROLLBACK_CHANGES`) |
| Per-worker RigForge new-release badge (#596): one fleet-wide latest-release fetch (hourly throttle, disabled = never dials) compared against each rig's reported `version`, bare-vs-`v`-prefixed SemVer | `dashboard.check_for_updates` + rig-reported version | 1 ✅ (`test_update_checker` comparison/throttle/no-dial; `test_views` + node tests for the per-worker plumbing) · 4 (deferred — live badge on a real rig, owed to the #597 gouda loaner session) |
| One-click rig upgrade (#597): the #596 badge proposes a version, the host re-derives the target from the RigForge release API over Tor and dials the rig's `/upgrade`; refusals (non-latest, GitHub unreachable/no tag, old rig < v1.11.2 non-202), the anti-beacon throttle, and the poll-cap timeout→accepted fallback | `/api/control/worker-upgrade` + host runner + badge render | 1 ✅ (`test_server.py` + `test_control_service.py`, `tests/stack` #597 cases, `workerview.test.mjs`) · 4 (deferred — gouda loaner: badge → click → applied → badge clears, repeat-click throttle, old-rig refusal) |
| Stratum auth accept/reject: matching `pass` mines, wrong/missing `pass` rejected, rotation | live proxy `--access-password` | 4 (deferred — a headless xmrig login probe, real proxy binary) |
| Dev-fee independence (#173): proxy `--donate-level` and rig `DONATION` both honored | live proxy + rig | 4 (deferred) |

The deferred tier-4 legs need a real RigForge rig against a real proxy — provisioned via
`rigforge.sh setup` on a bench box and driven by the live matrix (`run.sh --workers`), gated on the
`/var/lock/rig-e2e.lock` bench reservation (see [docs/dev/release-server.md](release-server.md)). They
are **not** re-provable at a lower tier: the auth-header logic (tier 1) and the wire handshake
(tier 2) already are, so the only thing left for the real rig is real mining and the real proxy's
accept/reject — which only a real xmrig-proxy binary can prove.

### J. Appliance image (`pithead-os`, #77)

The flashed image is the second distribution channel, and it follows the same rule as
everything else: logic at tier 1, reality at tier 4 — there is no separate model for it.
Tier 4 has one meaning (what only reality proves) and two harnesses, one per channel: the
live matrix for a DIY install, the KVM battery (`tests/os/run.sh`, see
[`tests/os/README.md`](../../tests/os/README.md)) for the flashed image. The battery needs
KVM + libvirt + root — the bench, not CI — and is the release gate for the image
([`appliance-release.md`](appliance-release.md)). `tests/os/verify-image.sh` sits below it:
static assertions against the built rootfs (variant stamp, baked units, watchdog config),
no VM needed, run on every image build.

| Situation | Trigger | Tier |
|---|---|---|
| Wizard Q&A → `config.json`, spool round-trips, token gate, error re-display | `test_wizard.py` (pytest) + `wizard.test.mjs` (node) | 1 ✅ |
| Image invariants: variant stamp, enabled units, watchdog/governor config, dev-keyring refusal | `tests/os/verify-image.sh` (static, no KVM) | build-time ✅ |
| EFI boot; first-boot wizard window; token gate answers | battery `--phase boot` | 4 ✅ |
| A/B contract: uncommitted auto-rollback, committed update persists, rollback off a committed slot, containers refreshed, `/data` grew | battery `--phase update` | 4 ✅ |
| Install-to-disk copies a COMPLETE system; reinstall keep/fresh paths | battery `--phase install` | 4 ✅ |
| Wizard's real HTTP flow provisions the STACK (images verified, Tor-only egress enforced, miner up); unaided reboot return; commit-gate honesty both ways; the migration hold starts the chain only post-commit | battery `--phase provision` | 4 ✅ |
| Rig role: no containers, mines from the baked binary, takes an A/B update like a coordinator | battery `--phase rig` | 4 ✅ |
| Power cuts mid-write and mid-commit; corrupt bundle — a brick is disqualifying | battery `--phase fault` (opt-in) | 4 ✅ |

## Running each tier

```bash
make test                 # tiers 1 + 2 (+ harness self-test) — every-PR, no docker/server
make test-fakes           # tier 2 contract test on its own
make test-mini-stack      # tier 3 — needs docker
make test-integration ARGS="--host user@box --dir pithead --lifecycle --fault-injection"  # tier 4
# tier 4, appliance channel (KVM bench):
os/build-image.sh --ssh && os/rauc/mkimage.sh --dev
sudo tests/os/run.sh --image os/rauc/build/system.img
```

## Production-readiness posture

What gates a merge vs. a release, the standards every test holds to, and the known gaps. For the
full enumerated coverage, `make test-inventory` generates the list on demand (git-ignored — read it
locally).

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
| **KVM appliance battery** (`tests/os/run.sh`) | 4 | manual / pre-release | ✅ **release gate for the image** ([appliance-release.md](appliance-release.md)) |

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
- **Real-container monerod failover in PR CI.** ✅ Now tier-3 scenarios 6/7 in the mini-stack: the
  compose env had a fake `monerod` container wired at the network level (`MONERO_RPC_URL`) but the
  dashboard's `LOCAL_MONERO_HOST` default didn't match it, so `MONERO_NODE_HOST != LOCAL_MONERO_HOST`
  put the dashboard on the "remote" code path, which never probes reachability — a monerod outage
  was a silent no-op end-to-end. Setting `LOCAL_MONERO_HOST` to the fake's hostname fixed the wiring;
  scenarios 6/7 down/readmit the real `itest-xmrig-proxy` container against it. The tier-4
  `--fault-injection` box run still covers the real binary/real kernel leg.
- **Required Tari outage keeps mining, with real containers.** ✅ Mini-stack scenario 4: with the
  default `dashboard.tari_required=true`, asserts `itest-xmrig-proxy` stays running through a Tari
  outage — the path that silently killed 22 measured minutes of revenue before it was fixed.
- **Non-blocking-Tari sync-gate path with real containers.** ✅ Mini-stack scenario 11: recreates
  the stack with `dashboard.tari_required=false` (baked in at container boot, so it needs its own
  compose cycle) and asserts the sync gate releases on monerod alone.
- **monerod busy / mid-reorg failover.** ✅ Mini-stack scenario 8: the fake's `busy` mode (HTTP 200,
  `status≠OK`) drives the same reject/readmit cycle as a clean outage.
- **Double outage, readmission follows monerod alone.** ✅ Mini-stack scenario 9: monerod and Tari
  both down → rejected; recovering monerod readmits immediately even with Tari still down — proven
  end-to-end, not just at the unit level.
- **Partial-start / stop-failure idempotency.** The control loop's "container fails to start/stop →
  retry next cycle" is unit-only; no tier-3/4 scenario injects a docker start/stop error.
- **`pithead doctor` on a real box.** ✅ The `--check` phase now runs `doctor` and asserts exit 0
  plus the three #383 runtime OK verdicts (egress firewall installed, stratum listening, dashboard
  answers). ✅ Its NTP/clock-drift check is now fault-injected too (`--fault-injection`): a
  PATH-shadowed `timedatectl` (no real clock skew — mining is time-sensitive) proves doctor
  classifies a real unsynced report correctly, then the shadow is dropped and recovery is asserted.
- **Disk-full / ENOSPC verdict.** ✅ Now a tier-4 `--fault-injection` case: a 1MiB tmpfs bind-mounted
  over the dashboard data dir and filled solid forces a real kernel ENOSPC (distinct from
  `fault_db_readonly`'s EACCES), and asserts `db_healthy:false`, then unmounts and asserts recovery.
- **Tor-container-down partial start.** ✅ Now a tier-4 `--fault-injection` case (#563, TOP PRIVACY
  PRIORITY): `docker compose stop tor` and assert BOTH no clearnet egress leak appears (reuses
  `bench-verify-egress.sh`'s `/proc/net/tcp` proof, the same one the steady-state battery runs) and
  that `doctor` flags the outage loudly rather than passing silently, then restart tor and re-assert
  both the egress proof and `pithead status`. The doctor-loud-failure leg is the harness *proving*
  the gap: `check_egress_firewall_installed` and `check_tor_clearnet_egress` both currently SKIP
  (not FAIL) when the tor container isn't running, so this assertion is expected to fail against
  today's `doctor` until it gains an explicit tor-down verdict — filed as a follow-up, not silently
  softened here.
- **Insecure + main matrix row.** `dashboard.secure=false` only ever pairs with `p2pool.pool=nano`,
  so the Caddy-scheme / bind assertions for insecure mode are entangled with the nano path; an
  insecure+main regression has no row.
- **`verify_release_images()` against a real signed bundle.** ✅ Now exercised directly (not
  reimplemented) by `scripts/release-smoke.sh`: the real function runs in the extracted, published
  bundle dir against the real pinned digests + committed `cosign.pub` (positive, needs a signed
  release) and against a digest tampered in a copy of the bundle (negative, fail-closed, runs
  regardless of signing) — the security-critical proof that the exact function `up`/`upgrade` run on
  every install refuses a mismatched digest, not just that a hand-rolled cosign call does (#376/#459).
- **Per-service runtime uid.** ✅ Now asserted every matrix run and at `--check`: `docker exec <svc>
  id -u` for all 9 services against their audited expected uid (tor 100; monerod/p2pool/
  xmrig-proxy/dashboard/tari 1000; caddy/docker-proxy/docker-control root, mitigated by
  `cap_drop: ALL` + isolation rather than uid) — compose only pinned tari's `user:` at config time
  (#255/#91); nothing checked what actually runs.

## Adding a scenario

- Logic (a new decision/branch) → a unit test (tier 1). Cheapest, fastest.
- A new daemon state the clients must parse → extend the fakes plus the contract test (tier 2), and
  it becomes drivable in the mini-stack (tier 3).
- A config axis → one row in `tests/integration/scenarios.sh` (tier 4). The self-test enforces
  every axis value is covered.
- A failure mode needing real containers → a fault in `run.sh`'s fault-injection phase (tier 4)
  and/or a mini-stack scenario (tier 3).

Keep each situation at the lowest honest tier; don't re-prove logic with a heavier harness.
