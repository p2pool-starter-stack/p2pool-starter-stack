# Mining Dashboard

The monitoring web UI and XvB switching engine for Pithead. It aggregates
stats from the local collectors, the XMRig proxy, and the Tari node, and serves a single-page
dashboard (behind Caddy) on `127.0.0.1:8000`.

## Architecture

The server is a **data API**; the browser renders the UI. There is no server-side templating:

- **`GET /`** serves a tiny static HTML shell.
- **`GET /api/state?range=…`** returns the whole dashboard as JSON — the contract built by
  `views.build_state`. Computed domain values (effective hashrate, P2Pool/XvB averages, XvB
  tier qualification, shares-in-window, sync/down state) live in one typed place,
  `service/metrics.py` → `build_metrics() -> Metrics`; the view layer **formats** those into
  display strings + semantic tokens (`variant: "ok"`, `level: "high"`) and emits no HTML. The
  same `Metrics` is meant to back future consumers (Telegram #45, calculator #12) without
  re-deriving from the raw dict.
- The client (`static/dashboard.js` + `components.mjs`) is a small **Preact** app (rendered with
  `htm` tagged templates — no JSX, no build step). It polls `/api/state` every 30s and renders
  declaratively, so the chart instance, table sort, selected range, and the simple/advanced view
  all survive each refresh. UI state lives on the client; data lives on the server.

Everything is served from `/static` — the vendored Preact, htm and Chart.js (`static/vendor/`),
plus the app modules and `dashboard.css`. Nothing is inlined and the libraries are eval-free, so
the page runs under a strict Content-Security-Policy with no `'unsafe-inline'`/`'unsafe-eval'`.

Testing: the Python API — where all the logic and formatting live — is fully unit-tested. The
pure client logic (worker sort, tooltip formatting, hero-KPI selection in `static/logic.mjs`) is unit-tested with
**Node's built-in runner** (`node --test build/dashboard/tests/frontend/*.test.mjs`) — no
`package.json`/`node_modules`/build step, so the repo stays Node-free. Component *rendering* has
no unit tests by design; it's covered by a manual browser smoke test.

## Layout

```
mining_dashboard/
├── main.py            # entry point: build_app() wires everything; `python -m mining_dashboard.main`
├── config/            # configuration from environment variables
├── client/            # external service clients (xmrig, xmrig-proxy, xvb, tari gRPC, monerod RPC, docker control)
├── collector/         # local stats collectors (pools, system, docker logs)
├── service/           # algo_service (XvB switching), data_service (aggregation), storage_service (SQLite),
│                      #   metrics (typed computed domain values consumed by the view layer)
├── web/               # server.py (transport: / shell + /api/state + middleware),
│                      #   views.py (build_state: the JSON state object), templates/index.html
│                      #   (static shell), static/ (Preact app + dashboard.css + vendored libs)
└── helper/            # formatting utilities
```

It is a proper installable package (`pyproject.toml`): all internal imports are absolute
(`mining_dashboard.*`), and it runs as a module — no `PYTHONPATH` gymnastics.

## Development

```bash
# from build/dashboard/ — uv creates .venv and installs from the hashed uv.lock (Python 3.11+)
uv sync --extra test
```

## Tests

```bash
pytest                                   # quick run
pytest --cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

# pure client logic (needs only Node >= 18, no install):
node --test tests/frontend/*.test.mjs
```

Or from the repo root: `make test-dashboard`. The same Python suite runs in the Docker test stage:

```bash
docker build --target test ./build/dashboard
```

Tests are hermetic — no network, no containers, no real database (an in-memory SQLite is used
via the `state_manager` fixture and the auto-applied DB-isolation fixture in `tests/conftest.py`).

Two coverage ratchets back the suite: a **total** floor (`--cov-fail-under=80`) and a **patch** gate
(`make test-patch-coverage` → `diff-cover` ≥ 90% on changed lines, #286). The money/numeric logic
(earnings, the XvB controller, the donation simulator) also has **property-based tests**
(`hypothesis`, #284) asserting invariants — non-negativity, conservation, monotonicity, clamp
bounds — across a wide input range, the class of bug example tests miss (cf. the #70 overshoot).

**Typing roadmap (deferred):** the app is lightly annotated today, so a static type-checker gate is
premature (and `ty` is still pre-1.0). The on-ramp — turning on ruff's `ANN` ruleset as a
non-blocking annotation ratchet, then adopting `ty`/`pyright` once coverage is meaningful and `ty`
reaches 1.0 — is a post-1.0 follow-up (#284), not a v1.1 blocker.

## Image

The `Dockerfile` is multi-stage:

- `base` — uv (digest-pinned) + system deps + lock/metadata + source.
- `test` — `uv sync --locked --extra test` then `pytest --cov-fail-under=80` (build with `--target test`).
- `production` — `uv sync --locked` (runtime deps only) + entrypoint (the default `docker compose build` target).
