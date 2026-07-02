# Pithead — working notes for Claude

Pithead is a Docker-Compose stack that runs a Monero + Tari merge-mining setup behind Tor. The `pithead` bash CLI renders `.env` and generated config from `config.json`, then drives docker-compose.

Read these before making changes, and hold them for every change:

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — dev workflow, branch model (`develop` is the integration branch; `main` is released-only), how to run lint and tests.
- [`docs/STYLE.md`](docs/STYLE.md) — the house documentation voice. Every prose doc gets a voice + accuracy pass; the banned-word list is enforced by `make lint-docs-voice`.
- [`docs/testing-strategy.md`](docs/testing-strategy.md) — the fixed four-tier testing model. Test each behaviour once, at the lowest tier that proves it honestly. Do not invent a new model.

Two standing bars for any change: it ships with the docs updated in the house voice, and with coverage at the right tier. Verify locally with `make lint` and `make test` (dashboard coverage ≥ 80%; patch coverage ≥ 90% via `make test-patch-coverage`; regenerate `docs/test-inventory.md` with `make test-inventory` if tests changed).

Source of truth is the code: when a doc and the code disagree, fix the doc. Never invent a fact — mark `[TODO: verify upstream — ...]` instead.
