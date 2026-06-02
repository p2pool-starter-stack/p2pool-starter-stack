# Mining Dashboard

The monitoring web UI and XvB switching engine for the P2Pool Starter Stack. It aggregates
stats from the local collectors, the XMRig proxy, and the Tari node, and serves a single-page
dashboard (behind Caddy) on `127.0.0.1:8000`.

The page updates **live in place**: a small client loop re-fetches the rendered page and swaps
the server-rendered region `<div>`s (and updates the chart from a JSON data island) instead of
reloading, so scroll position, table sort, and chart state survive each refresh.

## Layout

```
mining_dashboard/
├── main.py            # entry point: build_app() wires everything; `python -m mining_dashboard.main`
├── config/            # configuration from environment variables
├── client/            # external service clients (xmrig, xmrig-proxy, xvb, tari gRPC, monerod RPC, docker control)
├── collector/         # local stats collectors (pools, system, docker logs)
├── service/           # algo_service (XvB switching), data_service (aggregation), storage_service (SQLite)
├── web/               # server.py (transport: routing + middleware), views.py (rendering:
│                      #   typed context dataclasses + render_dashboard), HTML template, static assets
└── helper/            # formatting utilities
```

It is a proper installable package (`pyproject.toml`): all internal imports are absolute
(`mining_dashboard.*`), and it runs as a module — no `PYTHONPATH` gymnastics.

## Development

```bash
# from build/dashboard/
python3 -m venv .venv && source .venv/bin/activate     # Python 3.11+
pip install -e ".[test]"
```

## Tests

```bash
pytest                                   # quick run
pytest --cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80
```

Or from the repo root: `make test-dashboard`. The same suite runs in the Docker test stage:

```bash
docker build --target test ./build/dashboard
```

Tests are hermetic — no network, no containers, no real database (an in-memory SQLite is used
via the `state_manager` fixture and the auto-applied DB-isolation fixture in `tests/conftest.py`).

## Image

The `Dockerfile` is multi-stage:

- `base` — system deps + package metadata + source.
- `test` — `pip install -e .[test]` then `pytest --cov-fail-under=80` (build with `--target test`).
- `production` — runtime install + entrypoint (the default `docker compose build` target).
