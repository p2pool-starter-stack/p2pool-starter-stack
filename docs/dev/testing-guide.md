# Testing Guide (for developers)

Where to put a test for a change you just made, and how to run it. The
[Testing Strategy](testing-strategy.md) explains why the tiers exist; `make test-inventory`
generates a list of what exists today (git-ignored — read it locally).

## Principles

- Test the intent, not the line. A test pins down a behavior or contract — "a pruned node
  displays Pruned", "the gate holds until both chains sync", "an old DB migrates without losing
  history" — and reads clearly enough that its name plus a one-line comment explain why it exists.
  Don't add a test purely to move the coverage number.
- The 80% coverage gate is a floor, not a target. Uncovered defensive error-handling is fine;
  uncovered behavior (a migration path, a retention rule, a decision branch) is a gap.
- Tests are real code. They are linted (`shellcheck`), version-controlled with the change they
  protect, and listed in the inventory. A CI drift check fails if you add or remove a test without
  regenerating it.

## Commands

```bash
make test                 # everything that needs no server/docker (run before every PR)
make test-dashboard       # dashboard pytest + 80% coverage gate
make test-stack           # pithead shell suite
make test-fakes           # tier-2 contract test (real clients vs fakes)
make test-integration-selftest   # the integration harness's own logic
make test-inventory       # write a generated (git-ignored) coverage list to docs/dev/test-inventory.md
make test-mini-stack      # tier-3 docker mini-stack (needs docker)
make test-integration ARGS="--host user@box --dir pithead --check"   # tier-4 live, non-destructive
```

## Where tests live

| You changed… | Write the test here | Tier |
|---|---|---|
| Dashboard logic (a decision, metric, `/api/state` field) | `build/dashboard/tests/**/test_*.py` (pytest) | 1 |
| Frontend logic (worker sort, formatting) | `build/dashboard/tests/frontend/*.test.mjs` (`node --test`) | 1 |
| A client that parses a daemon (monerod RPC, Tari gRPC) | `tests/integration/fakes/test_contract.py` (+ extend the fakes) | 2 |
| The control plane (sync-gate #35, failover #31) | `build/dashboard/tests/service/test_data_service.py` (+ a `mini-stack` scenario) | 1 + 3 |
| `pithead` CLI behavior | `tests/stack/run.sh` | 1 |
| A compose **security/hardening** invariant (caps, `no-new-privileges`, no secret in a healthcheck, socket-proxy scope) | the #90 section of `tests/stack/test_compose.sh` | 1 |
| A new `config.json` axis | one row in `tests/integration/scenarios.sh` | 4 |
| A failure mode needing real containers | `run.sh` `--fault-injection` and/or a `mini-stack` scenario | 4 / 3 |
| The integration harness's own logic | `tests/integration/selftest.sh` | — |

## Recipes

### Dashboard behavior (tier 1)

Add a `test_*` to the matching file under `build/dashboard/tests/`. Name it for the behavior, add
a one-line docstring stating the intent, mock at the client boundary (the conftest gives you an
in-memory `state_manager`). Run `make test-dashboard`; coverage must stay ≥ 80%.

```python
def test_pruned_node_is_labelled_pruned(...):
    # Intent: a local pruned node shows "Pruned" so a config/DB mismatch is visible (#32).
    ...
```

### A client parsing a new daemon state (tier 2)

1. Teach the fake to produce the state: edit `tests/integration/fakes/fake_monerod.py` or
   `fake_tari.py` (add a `mode`, or a field the daemon returns).
2. Assert the real client parses it: add a test to `fakes/test_contract.py` that points the real
   `MoneroClient`/`TariClient` at the fake and checks the parsed result.
3. `make test-fakes`. This is the seam that catches "the daemon changed its wire format".

### A config axis (tier 4)

Add a `NAME<TAB>overrides` row to `scenario_matrix()` in `scenarios.sh`, and the value to
`axis_coverage()`. The self-test enforces that every axis value appears in some scenario, so a
half-added axis fails `make test-integration-selftest`. No code changes needed.

### A control-plane scenario (tier 3)

Add a scenario to `tests/integration/mini-stack/run-mini-stack.sh`: drive the fakes via their
`/control` endpoints (`set_monerod`/`set_tari`) and assert real container state with
`assert_state` / `assert_stays`. `make test-mini-stack` (needs docker).

### Visual check (frontend, pre-PR)

The `node --test` frontend suite renders components as strings, so it cannot see a layout bug —
an overflowing table, a wrapped stat, a broken breakpoint. Before a PR that touches the
dashboard's look, render the real frontend in a real browser against a canned `/api/state`
payload — no docker, no stack. The fixture half lives in the repo:
`tests/frontend/fixtures/_gen_state.py` writes `state.json`, a real `build_state()` payload (the
exact contract the client renders). Regenerate it whenever the payload contract changes — a
drift guard in `tests/web/test_views.py` reruns the generator and fails on any structural
difference from the checked-in fixture, down to nested keys. Then serve the real app around it:

```bash
cd build/dashboard
uv run --extra test python tests/frontend/fixtures/_gen_state.py
python3 - <<'EOF'
import http.server, mimetypes
from pathlib import Path
mimetypes.add_type("text/javascript", ".mjs")
web, fix = Path("mining_dashboard/web"), Path("tests/frontend/fixtures/state.json")
class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        p = path.split("?")[0]
        if p.startswith("/api/state"): return str(fix)
        if p.startswith("/static/"): return str(web / p.lstrip("/"))
        return str(web / "templates/index.html")
http.server.ThreadingHTTPServer(("127.0.0.1", 8000), H).serve_forever()
EOF
```

Open `http://127.0.0.1:8000` and eyeball the page at a desktop and a phone width (the browser's
device toolbar is enough). Only `/api/state` is served — every other API call fails, which the
page tolerates; the main view is the point. This is a manual pre-PR step, not a test tier: it has
caught real bugs (a "≈ 0.0 blocks" display, a WebKit table overflow) that the string-render tests
structurally cannot.

## Conventions

- Determinism, no sleep-and-hope. Wait on a real signal with a timeout (`wait_for`,
  `assert_state`, `wait_status_ok`). For time-based logic, backdate timestamps white-box rather
  than patching the global clock — push an old point into the deque, then act (see
  `test_history_older_than_retention_pruned_from_memory`).
- Shell: pure logic goes in `lib.sh`/`scenarios.sh` and is tested by `selftest.sh`. I/O (ssh,
  docker, RPC) is thin wrappers that aren't unit-tested. Everything stays
  `shellcheck --severity=warning` clean.
- `make test-inventory` writes a generated (git-ignored) coverage list you can read locally — handy
  for seeing what already exists before you add a test.
- Secrets: never print tokens, creds, or onions. The harness redacts artifacts and hashes secrets
  on the box. If you add a secret-bearing field, confirm `redact()` covers it (there's a self-test
  for the patterns).

## Gotchas learned on real hardware

The live harness was first run against a real synced, mining box. These are the calibration lessons
now baked into the tests.

- A synced local monerod shows `state: "loading"` in `/api/state`, not `"done"` — it has no target
  height once caught up. Assert "synced" via monerod's own `get_info.synchronized` (the harness's
  `monero_caught_up`), not the dashboard UI field.
- `stratum.conns` can read 0 on a healthy, mining box. Use `proxy_workers` / `total_hashes` for
  mining-liveness; `conns` is informational.
- The mini-stack must be isolated. Containers are named `itest-*` and control ports are
  28081/28152 so it can't collide with — or control — a real deployment on the same host. A fake
  server inside a container must bind `0.0.0.0`; binding `127.0.0.1` makes it unreachable from peer
  containers, which once broke release in the mini-stack.
- monerod-down failover IS simulated in the mini-stack (scenarios 6–9: outage, readmit,
  busy/mid-reorg, double outage) — but only because the fake compose sets `LOCAL_MONERO_HOST` to
  the fake monerod's hostname. If it doesn't match `MONERO_NODE_HOST`, the dashboard treats
  monerod as "remote" and never probes it for reachability, so an outage becomes a silent no-op —
  the original wiring bug. The tier-4 `run.sh --fault-injection` run still proves the
  real-binary leg on real hardware.
- Run `--check` first. Against any real box, `run.sh --check` asserts the current live state
  non-destructively (no config change). It's the safe way to validate before the config-churning
  matrix.
