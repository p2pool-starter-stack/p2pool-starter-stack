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
| **1 — Unit** | `dashboard/tests/` (pytest, mocked clients) and `tests/stack/` (shell, `docker`/`sudo` stubbed) | Decision logic & field mapping: sync-gate, failover, node-health debounce, XvB engine, `/api/state` shapes, `pithead` config/status logic | Every PR (`make test`) |
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

Each tier-1 shell row below names the `tests/stack/test-*.sh` domain file that actually holds its
assertions; `tests/stack/run.sh` itself is the tier-1 shell **suite** — it sources every domain
file rather than holding assertions of its own (see the test-inventory note under
[Production-readiness posture](#production-readiness-posture) for how that sourcing is checked).

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
| `tari.mode` local vs remote (#103): tari container/onion present/absent, sync gate against a remote target | config | 4 ▶ |
| `p2pool.stratum_tls` (#261): a live TLS handshake on the published stratum port, served cert matches the pinned fingerprint | config → live dial | 1 ✅ (render) · 4 ▶ (server-side handshake; a real xmrig client with `pools[].tls:true` stays deferred, see Known gaps) |
| `network.tor_egress_firewall=false` (#270): the opt-out actually opens a direct clearnet dial, not just that no rule installed | config → live kernel | 1 ✅ (stubbed iptables installs no rule) · 4 ▶ (real dial succeeds) |
| `monero.view_key` / `tari.view_key` (#381/#462): payout-confirmation wallet-rpc/tari-wallet wiring live | config → live | 4 ▶ (needs `IT_MONERO_VIEW_KEY`/`IT_TARI_VIEW_KEY`+`IT_TARI_SPEND_PUBLIC_KEY`; a confirmed payout landing is real-money real-time, not e2e-reachable) |

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
| Monero node reachable but **out of sync** — the post-tor-restart 0-peer strand (#972): raw `synchronized` passthrough, debounced stale flag, alert via the `node_down` toggle, monerod restarted alongside tor (compose `depends_on: restart` + the #424 auto-heal), `restart monerod` leg, doctor WARN | `synchronized: false` ≥ `NODE_STALE_AFTER_SEC` after being in sync once | 1 ✅ (client/data_service/alert/tor_heal pytest, `tests/stack` doctor + restart + compose invariants) · 2 ✅ (flag over the wire) · 4 (real strand + re-peer needs the bench) |
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
| Client entry point (#903): the 30s poll with its pre-tick abort so a hung Tor circuit can't latch the in-flight guard (#382), disconnected-banner state and recovery with the last snapshot kept, preference seeding from URL/localStorage through the normalizers, zoom/range/avg query building, and the handler wiring the App receives | injected fetch/storage/timer fakes | 1 ✅ (`dashboard.test.mjs`) |
| Dashboard reads correct live state on a real stack | real daemons | 4 ▶ |

### G. CLI lifecycle (`pithead`)

| Situation | Trigger | Tier |
|---|---|---|
| Config validation, secret preservation, `apply` no-op/destructive guards | sourced fns | 1 ✅ |
| `setup`→`up`→`status`→`apply`→`restart`→`down`; idempotency; secret preservation | real box | 4 ▶ (`--lifecycle`) |
| `upgrade` (image pull/rebuild) | real box | release staging smoke (docs) |
| `backup`/`restore`, `reset-dashboard` | real box | 1 ✅ (partial) · 4 ▶ (`--lifecycle`/`--safety-backup`) |
| `doctor` runtime verdicts (#383): egress firewall, stratum listening, dashboard answers | real box | 1 ✅ (stubbed toolchain) · 4 ▶ (`--check`) |
| Appliance certificate (#1132/#1141): one shared name-list builder feeds both Caddy's site list and the certificate's SAN list, the mint re-mints only on a real list change (not a `hostname -I` re-order) and reuses otherwise, `doctor` FAILs on a name the certificate doesn't cover or a certificate within 30 days of expiry, WARNs (never FAILs) on an unreadable certificate file. `render` (which mints the certificate) always runs BEFORE `up` creates either compose bridge (`mining_net`, `proxy_net`) this boot, while `doctor`'s re-check runs from the boot health gate's retry loop, always AFTER `up` — an address that only exists post-`up` reads as "served but uncovered" unless something accounts for it (#1051/#reboot-leg-fix: this is what stranded both the reboot leg's commit gate and, independently, the OS-update 'updated' verdict behind a boot gate that never passed). `mining_net`'s gateway is excludable by a config-known literal and stays inside the shared, engine-free builder; `proxy_net`'s subnet is Docker/podman auto-assigned (#345) with no literal to exclude it by, so ONLY `doctor`'s certificate check asks the engine, live, for it — and if the engine can't answer (daemon restart, socket permission slip, anything at all), that check WARNs and skips the coverage FAIL for every auto-expanded address this run rather than risk FAILing a healthy box on a tooling hiccup (bridge interfaces outlive an engine blip, so the ambiguity is real); an uncovered PINNED/base name still FAILs regardless, since deriving it needs no engine at all | sourced fns / fixture certs (real `openssl`) / stubbed `docker` `network inspect` (per-network calls, both the resolved and the unreachable-engine shapes) | 1 ✅ (`tests/stack`) · 4 (deferred — a real Caddy TLS handshake surviving a moved DHCP lease needs the KVM battery / bench) |
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
| The same socket carries the three blocks that drive Worker Inspect: the rig's effective writable `config` (#1235), its `config_meta` provenance (#1345), and the mirrored `control` outcome (#579) — including the fresh-rig `control: null` shape and a non-terminal status, both of which must reconcile nothing | real client vs fake worker API | 2 ✅ (`fakes/test_contract.py`) |
| Our fake cannot drift from what a real worker emits (#1412): its `rigforge` key set is compared both ways against a vendored copy of RigForge's own `tests/contract/v1/feed.json`, that copy is pinned to the baked `RIGFORGE_REF` so a pin bump without a re-vendor reds here — until someone edits `PROVENANCE`, because the guard reads that ref line and never the fixture bytes (#1426) — and every status word in `control-status.json` must be classified terminal or known-non-terminal, on a vocabulary asserted non-empty so an emptied fixture cannot pass having checked nothing | vendored producer fixtures | 2 ✅ (`fakes/contract/v1/` + `test_contract.py`) |
| Dashboard parses proxy `/workers` rows → worker list + hashrate aggregation; offline drop-off window | metrics / `worker_presence` | 1 ✅ |
| `p2pool.stratum_password` renders `--access-password` (set) / omits it (default-off) | `pithead` render | 1 ✅ (`tests/stack`) · 4 ▶ (default-off live check) |
| Proxy restart / node-down → reject → readmit (real containers) | control plane | 3 ▶ (mini-stack) |
| Real worker mines through the real proxy: appears via its stratum name, hashrate aggregates, backup-pool failover | live rig + proxy | 4 ▶ (`run.sh --workers`) |
| Enriched read survives a populated masked-token descriptor — `api_ok` + rigforge feed resolve with `workers.list[].token` (#506; `dashboard.workers[]` legacy fallback) seen only as the `{"__secret__":true}` sentinel (the v1.5.2 regression + #508) | live rig + `workers.list[]` populated | 4 ▶ (`run.sh --rigforge-control`, #514) |
| Worker Inspect edit lands on the rig: `editable` true, a `max_temp_c` nudge via `/api/control/worker-apply` hits the rig's `/status` + records history, reverted | live rig control API on | 4 ▶ (`run.sh --rigforge-control`, #513) |
| Worker Inspect edit on `DONATION` + `watchdog_interval_min` (#1236): the original is read off the rig's own reported writable config (`.rig_config`, #1235/rigforge#253), a derived probe is applied, the **rig** is asserted to report it, then it is restored — and the restore runs even when the assertions red | live rig control API on | 1 ✅ (`selftest-rigforge-writable-keys.sh` — probe derivation, the settle, the refusals, and a mutation kill for each) · 4 ▶ (`run.sh --rigforge-control`, #1236) |
| Worker Inspect edit on `pools` (#1002b): the rig's own reading is credential-stripped and must not be written back (#113), so the restore target is the dashboard's own `last_applied.pools` record and the probe is operator-supplied | live rig control API on | 1 ✅ (`selftest-rigforge-writable-keys.sh` — gate, restore source, malformed probe) · 4 ▶ (`run.sh --rigforge-control`, #1002b; operator supplies `IT_RIG_POOLS_PROBE`) |
| `autotune` and `watchdog` writable-key edits | live rig control API on | **Permanently not covered, on purpose** — `autotune` starts a real tuning run; `watchdog` removes thermal protection from a rig at its temperature ceiling. Both are refused on borrowed hardware; the refusal itself is asserted at tier 1 (`selftest-rigforge-writable-keys.sh`) so it cannot be undone silently. |
| Rig-side edit reflects: a direct rig control-API change shows in the enriched feed; a `config.json` hand-edit shows in the masked prefill | live rig + direct dial | 4 ▶ (`run.sh --rigforge-control`, #516) |
| Control-apply auto-rollback (rigforge#236): a hashrate-tanking change is recorded `rolled_back` in the worker-apply result + per-worker history | live rig + fault-injection | 4 ▶ (`run.sh --rigforge-control`, #517; operator supplies `IT_RIG_ROLLBACK_CHANGES`) |
| Per-worker RigForge new-release badge (#596): one fleet-wide latest-release fetch (hourly throttle, disabled = never dials) compared against each rig's reported `version`, bare-vs-`v`-prefixed SemVer | `dashboard.check_for_updates` + rig-reported version | 1 ✅ (`test_update_checker` comparison/throttle/no-dial; `test_views` + node tests for the per-worker plumbing) · 4 (deferred — live badge on a real rig, owed to the #597 bench-loaner session) |
| One-click rig upgrade (#597): the #596 badge proposes a version, the host re-derives the target from the RigForge release API over Tor and dials the rig's `/upgrade`; refusals (non-latest, GitHub unreachable/no tag, old rig < v1.11.2 non-202), the anti-beacon throttle, and the poll-cap timeout→accepted fallback | `/api/control/worker-upgrade` + host runner + badge render | 1 ✅ (`test_server.py` + `test_control_service.py`, `tests/stack` #597 cases, `workerview.test.mjs`) · 4 ▶ (`run.sh --rigforge-control` drives the applied path and the repeat click — see the #1237 row below; still deferred on a bench loaner: badge clears, old-rig refusal) |
| The release gate both ASKS for the write phase and SUPPLIES it: `--mode targeted` — the run the release runbook mandates — requests `--rigforge-control` (#1364), and `e2e.sh` hands it the rig host and token its legs need, dialling the rig from the bench before reporting it as supplied (#1378). The token read survives a rig that has already been written to: a control-apply leaves `/opt/rigforge/config.json` root-owned, so the read falls back to `sudo -n` and a read that FAILED reports differently from a file with no token in it (#1466) | `e2e.sh` phase composition + `rig_supply` | 1 ✅ (`selftest-e2e-phases.sh` — the exact phase set per mode, the supply defaults, the token reaching the detached runner as an environment entry and never as argv, the fallback firing only on a failed read and only after the unprivileged one, and a mutation kill for each) |
| Remote-upgrade chain, selected by the dashboard's own release verdict (#1237): where a newer release is offered, the leg drives a real upgrade — `202` with a pollable `id`, which is what says the already-on-this-version shortcut cannot have answered — settles on an `applied` terminal, and reads the new version back off the rig's own summary; the repeat click then converges on a synchronous `noop` carrying no `id`, on a precondition that run established. A rig already on latest reports a classified skip, not a pass | `/api/control/worker-upgrade` + host runner + a real rig | 1 ✅ (`selftest-rigforge-upgrade.sh` — both branches, each skip reason, a mutation kill for each) · 4 ▶ (`run.sh --rigforge-control`; no live gate run has reached it yet) |
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
| Restore-at-setup (#909): archive+passphrase spool contract (accept, bad passphrase, oversize, malformed → fallback) — `test_wizard.py`/`wizard.test.mjs` for the server+client contract, `tests/stack/test-appliance-setup.sh` for `firstboot_consume_restore` against a genuine backup archive | `test_wizard.py` + `wizard.test.mjs` + `tests/stack/test-appliance-setup.sh` | 1 ✅ |
| Image invariants: variant stamp, enabled units, watchdog/governor config, dev-keyring refusal | `tests/os/verify-image.sh` (static, no KVM) | build-time ✅ |
| Dashboard exposure boundary (#1021/#1049): the rendered Caddyfile publishes the LAN v4 and the ULA but never the globally-routable v6; the bind line excludes it; a pinned `dashboard.host` does not reopen it AND still binds the box's own LAN address (#1089: pinned to a NAME, the documented appliance case — a pinned IP literal put the box's own address into the site list too, so a bind derived from `$site_hosts` and one derived from `hostname -I` rendered identically and the mutation stayed green); a box with only a public address still binds loopback; EVERY site block carries a bind (the count invariant that caught the unbound HTTPS onion vhost); the onion vhosts bind the container-bridge gateway and not a wildcard | `tests/stack/test-dashboard.sh` (sourced `generate_caddyfile`, stubbed `hostname`) | 1 ✅ |
| Unmatched-Host catch-alls own :80 (#1123) and :443 (#1132's third bullet) instead of leaving Caddy's own defaults — a reflecting redirect on :80, a silent empty 200 on :443 — to answer a forged Host or SNI: both redirect to the box's own canonical address (never one built from the request), both carry the same bind list as the named vhosts, and the :443 one carries no `tls` line of its own (proven against real Caddy with `caddy adapt`: a hostless catch-all falls through to the file's default connection policy, i.e. the certificate the named vhost already loads) | `tests/stack/test-dashboard.sh` (sourced `generate_caddyfile`) + `caddy adapt` against the rendered file (manual, ahead of #1037) | 1 ✅ |
| Boot identity units (#980): `pithead-ssh-host-keys` generates once into `/data`, never touches an existing key, recovers from an interrupted run; `pithead-mount-generator` derives the `/data` + ESP units from the booted disk (sda/nvme/vda naming, a container root generates nothing); `loop-wait.sh` demands block devices and polls its full budget | `tests/stack/test-appliance-identity-boot.sh` (sandboxed key dir, staged mountinfo) + `tests/stack/test-rauc-loop-wait.sh` (`loop-wait.sh`) | 1 ✅ |
| EFI boot; first-boot wizard window; token gate answers | battery `--phase boot` | 4 ✅ |
| A/B contract: uncommitted auto-rollback, committed update persists, rollback off a committed slot, containers refreshed, `/data` grew, host identity (machine-id + SSH host-key fingerprint) survives the swap | battery `--phase update` | 4 ✅ |
| Dashboard OS-update verbs: appliance-only refusals, host-derived target, resumable download (partial kept, `-C -` resume, headroom refusal), verify refusals (signature, compatible, variant, floor/downgrade, tag mismatch — bundle deleted), install writes the in-flight flag via the shared `os_update` path, an install that arrives while another pithead operation holds the machine comes back `rejected` rather than as a failed install — with the staged bundle kept for the retry and `rauc install` never reached (#1482) — reboot gated on an installed update, one verb per drain | `tests/stack/test-appliance-os-update-verbs.sh` (stubbed rauc/curl/systemctl/df) + `test_server.py`/`test_views.py`/`test_update_checker.py` + `osupdate.test.mjs` (resume chain, verdict banner, render gates) | 1 ✅ |
| `os_bundle_meta`'s `[meta.pithead]` parse (#1093), pinned against a REAL `rauc info` capture, not a hand-written stand-in: `tests/stack/fixtures/rauc-info/` holds genuine `--output-format=shell` and `--output-format=json` output off one bundle built from the production `render_bundle_manifest` (recipe + refresh instructions in `capture.sh`, refresh when the RAUC package pin moves). The fake `rauc` in `tests/stack/test-appliance-os-update.sh` now answers format-honestly instead of returning the same fixture regardless of `--output-format`, so a caller that regressed to `json` — the shape RAUC 1.11 ships, which omits `[meta.*]` entirely — degrades to fail-closed "unstamped" for real in the suite, and `os_raise_data_floor` records the real bundle's own declared floor end to end through `os_update` | `tests/stack/test-appliance-os-update.sh` (real fixtures) | 1 ✅ |
| Dashboard OS-update end-to-end: provision, check against a bench-local release server (root-owned test seam), download RESUMES from an interrupted transfer — proven by an independent witness (#1051: the server's own request log, not just the `resumed_from` field the test staged itself and which would hold even if curl silently restarted from zero), floor and bad-signature refusals with honest errors, install + explicit reboot intent + boot-gated commit lands the new slot, persisted verdict reaches `/api/state` | battery `--phase update` leg 4 (+ the `provision` os_update presence check) | 4 (added — unverified until the next battery run) |
| Post-reboot `rolled_back` verdict (#1051): a dashboard-driven install leaves an in-flight flag naming the target version; booting a DIFFERENT version writes the verdict into the state file and consumes the flag; landing on the target version leaves it alone (the commit gate's success half owns that); no in-flight flag is a no-op. Pulled out of `pithead-boot`'s executed-only body into `os_update_rollback_verdict`, sourceable the same way as `gate_ready`/`gate_url`, because it is pure file logic (an in-flight flag, `VERSION`, one `jq` call) that needs no real A/B updater to prove — before this it ran only on a real boot and no tier could drive it with a fixture | `tests/stack/test-appliance-boot.sh` (sourced `pithead-boot`, fixture `in-flight.json`/`VERSION`) | 1 ✅ |
| Install-to-disk copies a COMPLETE system; reinstall keep/fresh paths | battery `--phase install` | 4 ✅ |
| Restore leg: a real encrypted backup off a live machine, uploaded instead of the form on a fresh install, wallet + Tor identity restored not regenerated. The closing verdict (#1091) requires the stack to actually come back up (`podman ps`) AND a value sourced from the restored config — p2pool's own live stratum stats, `/api/state`'s `.stratum.wallet` — to match: `config.json` landing on disk alone proves only that the archive was unpacked, not that anything is RUNNING it. The verdict (`restore_live_state_verdict`) lives in a sourceable file, the same pattern as `hugepages_boot_verdict` (#1212), so the discrimination is provable with fixtures without a KVM boot | `tests/os/restore-live-state-verdict.sh`, `tests/stack/test-appliance-identity-boot.sh` (fixture `podman ps` / wallet strings) · battery `--phase install` | 1 ✅ · 4 (added — unverified until the next battery run) |
| Reinstall pre-fill (#794/#1038): the previous install's non-secret answers reach the wizard page ONLY when the branch that reads them off the target disk (`prefill_from_previous_install`) actually ran this boot — a wallet-address match on the page's own state alone cannot tell that from some other path producing the same value, the gap that left this leg green for four consecutive batteries with the branch itself unproven. Pairing the outcome with the branch's own console record (its log line, `journal+console` per `pithead-firstboot.service`) makes the two tell apart (`reinstall_prefill_verdict`), the same discrimination #1212 needed for hugepages | `tests/os/reinstall-prefill-verdict.sh`, `tests/stack/test-appliance-identity-boot.sh` (`reinstall_prefill_verdict`, fixture branch/wallet/password strings) + `tests/stack/test-appliance-install.sh` (`prefill_from_previous_install` itself) · battery `--phase install` | 1 ✅ · 4 (changed — unverified until the next battery run) |
| Restore leg: a real encrypted backup off a live machine, uploaded instead of the form on a fresh install, wallet + Tor identity restored not regenerated | battery `--phase install` | 4 (added — unverified until the next battery run) |
| Wizard's real HTTP flow provisions the STACK (images verified, Tor-only egress enforced, miner up); unaided reboot return; commit-gate honesty both ways; the migration hold starts the chain only post-commit | battery `--phase provision` | 4 ✅ |
| Rig role: no containers, mines from the baked binary, takes an A/B update like a coordinator | battery `--phase rig` | 4 ✅ |
| Physical-presence config channel (#786 sub-issue D): identical-config short-circuit, diff building + secret masking, consumed-marker, the abort/apply state machine (media removed, keypress, countdown timeout, absence of input is not abort), the abort path announces the cancellation on the console/journal (#1061), merge semantics (#965: unnamed settings keep their running values, `null` clears, an unmergeable file passes through to validation, a minimal stick preserves the dashboard login / appliance defaults / node credentials end to end) | `tests/stack/test-appliance-media.sh` (sourced, stubbed lsblk/mount) | 1 ✅ |
| Physical-presence config channel: exact diff on the console, countdown applies, the changed setting takes effect, the stick is consumed, pulling the stick mid-countdown cancels and the console confirms the cancellation by the exact expected wording (#1061); a MINIMAL stick (#965) keeps the pre-apply dashboard login working against the served dashboard and preserves appliance defaults + node credentials | battery `--phase media` (opt-in) | 4 (added — not yet run at the release gate) |
| Hugepages sizing (#977): tier thresholds over meminfo shapes, the degraded boot shrinks the pool + leaves the plain-words marker, doctor WARNs (never FAILs) on it | `tests/stack/test-appliance-identity-boot.sh` (sourced, fixture meminfo) | 1 ✅ |
| Hugepages sizing is a no-op on supported RAM: sizing unit ran, full 3072-page pool intact, no degraded marker on the 16 GiB guest — proven on a provisioned boot | battery `--phase provision` | 4 (added — unverified until the next battery run) |
| Hugepages sizing on the FIRST boot: pool intact on the 16 GiB guest AND the sizing unit's own record (`systemctl is-active pithead-hugepages.service`) shows it actually ran. HugePages_Total alone reads identically whether the unit ran and correctly changed nothing or never ran at all — the baked sysctl reserves the same pool either way — so pairing it with the unit's record is what makes "ran, no-op" and "never ran" distinguishable (#1212). The verdict (`hugepages_boot_verdict`) lives in a sourceable file for exactly that reason: the discrimination is provable with fixtures, not just a bench boot | `tests/os/hugepages-boot-verdict.sh`, `tests/stack/test-appliance-identity-boot.sh` (fixture is-active strings) · battery `--phase boot` | 1 ✅ · 4 (added — unverified until the next battery run) |
| Power cuts mid-write and mid-commit; corrupt bundle — a brick is disqualifying | battery `--phase fault` (opt-in) | 4 ✅ |
| Data-reset repair escalation against REAL damage (#1062): a genuine ext4 image, the same two-byte superblock-magic wipe the battery injects, and the system's own `fsck`/`e2fsck`/`mke2fs` — a repairable image is repaired with its payload intact and never reformatted; a destroyed one still reaches the reformat escape. Only `mount` is stubbed, and its verdict is `e2fsck -fn` on the image itself, never a counter. The stubbed decision-tree block in `tests/stack/test-appliance-reset.sh` proves marker precedence and escalation order (#1086); this suite proves the repair | `tests/stack/test_data_reset.sh` | 1 ✅ |
| Factory reset returns a machine with a fresh identity (machine-id, SSH host key, container store) and records the wipe on the ESP; a wedged `/data` — the superblock corrupted on the real partition — is REPAIRED, not erased: the sentinel planted before the corruption survives and the wipe log does not grow (#1062/#1087) | battery `--phase reset` | 4 ✅ |

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
locally). The generator is grep-based, so CI runs it on every PR and fails if any suite it
enumerates counts zero — the drift a moved or reshaped suite would otherwise hide. It also holds
`tests/stack/run.sh` and the per-domain files it sources to each other in both directions: a file
named by a `source` line has to exist, and a file on disk has to be sourced by something. Either
mismatch ends the same way — `run.sh` does not stop on a failed `source`, so the suite reports a
pass having skipped every assertion in that domain. It reads those `source` lines as text, which
catches one that is absent or commented out but not one that is present and never reached; a
handful of suites are invoked as their own CI step instead and are listed as exempt in the script.

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
| **Test-inventory drift** check (every suite still enumerates; every domain file is sourced) | — | every PR | ✅ required |
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
- Test code is real code. The same lint (shellcheck) and coverage gate apply to the tests
  themselves, and the inventory generator fails CI if it stops enumerating a suite.
- An assertion reads its haystack directly, never through a pipe. `grep -q` exits at its first
  match, so under `pipefail` the writer's broken pipe becomes the pipeline's exit status and the
  match is thrown away: a directive that was present read as missing, and — in the direction
  nobody watches — a forbidden pattern that was present read as absent, which is a hardening
  regression wearing a green tick. Use a here-string. And a reader that could not run at all is a
  failure in its own right, never folded into either verdict.

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
  that `doctor` fails loudly — its dedicated `check_tor_running` verdict FAILs with a non-zero exit
  while the tor container is down and the mining stack runs, never a silent all-clear — then
  restart tor and re-assert both the egress proof and `pithead status`.
  (`check_egress_firewall_installed` and `check_tor_clearnet_egress` still info-skip without a
  running tor container, by design: the dedicated verdict already fails the outage.)
- **Insecure + main matrix row.** ✅ Now a dedicated `local-pruned-main-insecure` row: the two axes
  decouple, so a regression specific to insecure+main (vs. the pre-existing insecure+nano row) has
  somewhere to fail.
- **A real xmrig client over stratum TLS.** The `p2pool.stratum_tls=true` row proves the server side
  live (a real TLS handshake on the published port, served cert matches the pinned fingerprint);
  a real rig actually mining with `pools[].tls:true` set is deferred, the same class of gap as the
  stratum-password headless-probe row above (a rig-configuration step outside this harness's
  control, needing a real xmrig binary).
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
