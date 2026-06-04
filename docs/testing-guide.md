# Testing Guide (for developers)

Practical "how do I test the change I just made?" companion to the
[Testing Strategy](testing-strategy.md) (which explains *why* the tiers exist) and the
generated [Test Inventory](test-inventory.md) (which lists *what* exists today).

## Philosophy

- **Test the intent, not the line.** A test should pin down a *behavior or contract* —
  "a pruned node displays Pruned", "the gate holds until both chains sync", "an old DB
  migrates without losing history" — and read clearly enough that its name + one-line comment
  explain *why it exists*. Don't add a test purely to move the coverage number.
- **The 80% coverage gate is a floor, not a target.** Uncovered defensive error-handling is
  fine; uncovered *behavior* (a migration path, a retention rule, a decision branch) is a gap.
- **Tests are real code.** They're linted (`shellcheck`), version-controlled with the change
  they protect, and listed in the inventory (a CI drift check fails if you add/remove a test
  without regenerating it).

## Commands

```bash
make test                 # everything that needs no server/docker (run before every PR)
make test-dashboard       # dashboard pytest + 80% coverage gate
make test-stack           # pithead shell suite
make test-fakes           # tier-2 contract test (real clients vs fakes)
make test-integration-selftest   # the integration harness's own logic
make test-inventory       # regenerate docs/test-inventory.md (do this when adding/removing tests)
make test-mini-stack      # tier-3 docker mini-stack (needs docker)
make test-integration ARGS="--host user@box --dir pithead --check"   # tier-4 live, non-destructive
```

## Where tests live

| You changed… | Write the test here | Tier |
|---|---|---|
| Dashboard logic (a decision, metric, `/api/state` field) | `build/dashboard/tests/**/test_*.py` (pytest) | 1 |
| Frontend logic (worker sort, formatting) | `build/dashboard/tests/frontend/*.test.mjs` (`node --test`) | 1 |
| A client that parses a daemon (monerod RPC, Tari gRPC) | `tests/integration/fakes/test_contract.py` (+ extend the fakes) | 2 |
| The control plane (sync-gate #35, failover #31) | `tests/service/test_data_service.py` (+ a `mini-stack` scenario) | 1 + 3 |
| `pithead` CLI behavior | `tests/stack/run.sh` | 1 |
| A new `config.json` axis | one row in `tests/integration/scenarios.sh` | 4 |
| A failure mode needing real containers | `run.sh` `--fault-injection` and/or a `mini-stack` scenario | 4 / 3 |
| The integration harness's own logic | `tests/integration/selftest.sh` | — |

## Recipes

### Dashboard behavior (tier 1)
Add a `test_*` to the matching file under `build/dashboard/tests/`. Name it for the behavior,
add a one-line docstring stating the intent, mock at the client boundary (the conftest gives
you an in-memory `state_manager`). Run `make test-dashboard` — coverage must stay ≥ 80%.

```python
def test_pruned_node_is_labelled_pruned(...):
    # Intent: a local pruned node shows "Pruned" so a config/DB mismatch is visible (#32).
    ...
```

### A client parsing a new daemon state (tier 2)
1. Teach the fake to produce the state: edit `tests/integration/fakes/fake_monerod.py` or
   `fake_tari.py` (add a `mode`, or a field the daemon returns).
2. Assert the *real* client parses it: add a test to `fakes/test_contract.py` that points the
   real `MoneroClient`/`TariClient` at the fake and checks the parsed result.
3. `make test-fakes`. This is the seam that catches "the daemon changed its wire format".

### A config axis (tier 4)
Add a `NAME<TAB>overrides` row to `scenario_matrix()` in `scenarios.sh`, and the value to
`axis_coverage()`. The self-test **enforces** that every axis value appears in some scenario,
so a half-added axis fails `make test-integration-selftest`. No code changes needed.

### A control-plane scenario (tier 3)
Add a scenario to `tests/integration/mini-stack/run-mini-stack.sh`: drive the fakes via their
`/control` endpoints (`set_monerod`/`set_tari`) and assert real container state with
`assert_state` / `assert_stays`. `make test-mini-stack` (needs docker).

## Conventions

- **Determinism, no sleep-and-hope.** Wait on a real signal with a timeout (`wait_for`,
  `assert_state`, `wait_status_ok`). For time-based logic, **backdate timestamps white-box**
  rather than patching the global clock — e.g. push an old point into the deque, then act
  (see `test_history_older_than_retention_pruned_from_memory`).
- **Shell:** pure logic goes in `lib.sh`/`scenarios.sh` and is tested by `selftest.sh`; I/O
  (ssh, docker, RPC) is thin wrappers that aren't unit-tested. Everything stays
  `shellcheck --severity=warning` clean.
- **Regenerate the inventory** (`make test-inventory`) when you add/remove a test — CI's
  drift check (`make test-inventory-check`) fails otherwise.
- **Secrets:** never print tokens/creds/onions; the harness redacts artifacts and hashes
  secrets on the box. If you add a secret-bearing field, confirm `redact()` covers it (there's
  a self-test for the patterns).

## Gotchas learned on real hardware

The live harness was first run against a real synced, mining box — these are the
calibration lessons baked into the tests now. Keep them in mind:

- **A synced *local* monerod shows `state: "loading"` in `/api/state`**, not `"done"` — it has
  no target height once caught up. Assert "synced" via monerod's own `get_info.synchronized`
  (the harness's `monero_caught_up`), not the dashboard UI field.
- **`stratum.conns` can read 0 on a healthy, mining box.** Use `proxy_workers` /
  `total_hashes` for mining-liveness; `conns` is informational.
- **The mini-stack must be isolated.** Containers are named `itest-*` and control ports are
  28081/28152 so it can't collide with — or control — a real deployment on the same host.
  A fake server inside a container must bind `0.0.0.0` (binding `127.0.0.1` makes it
  unreachable from peer containers — this once broke release in the mini-stack).
- **monerod-down failover isn't simulated in the mini-stack** (the dashboard's monerod
  down-path log-scrapes a real `monerod` container the fake stack lacks); it's covered on real
  hardware by `run.sh --fault-injection`. Tari-down is simulated there cleanly.
- **Run `--check` first.** Against any real box, `run.sh --check` asserts the current live
  state non-destructively (no config change) — the safe way to validate before the
  config-churning matrix.
