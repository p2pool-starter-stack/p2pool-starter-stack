# Contributing to Pithead

The workflow for contributing bug fixes, docs changes, and features.

## Before you start

- Open an issue before writing code for anything beyond a small fix. Discuss the approach
  there first.
- Check the [open issues](https://github.com/p2pool-starter-stack/pithead/issues) for existing
  work on the same thing.

## Dev environment

The dashboard uses [uv](https://docs.astral.sh/uv/) for dependency management; a hashed
`uv.lock` pins every transitive dependency for reproducible installs. Its Python tooling
([`ruff`](https://docs.astral.sh/ruff/) lint + format, [`pre-commit`](https://pre-commit.com/))
lives in the `dev` extra. Install uv, then from the repo root:

```bash
uv sync --project build/dashboard --extra dev    # deps + tooling into build/dashboard/.venv, from the lock
uv run --project build/dashboard pre-commit install
```

`make test` and `make lint-py` run through uv automatically (no venv to activate); `pre-commit`
runs `ruff` (plus a few hygiene hooks) on your changed files. If you change dependencies in
`build/dashboard/pyproject.toml`, run `uv lock` and commit the updated `uv.lock`.

## Development workflow

1. Fork the repo and create a branch off `develop` (the integration branch; `main` holds released
   commits only).
2. Make your change. Keep it focused: one logical change per PR.
3. Run the full test suite locally:

   ```bash
   make test
   ```

   This runs everything CI does without a server or Docker:

   - **lint** — every file surface gets a linter/formatter check (`make lint` runs them all; run one
     with `make lint-<surface>`): `lint-sh` (shellcheck + shfmt), `lint-py` (ruff), `lint-js` (Biome),
     `lint-yaml` (yamllint), `lint-md` (markdownlint), `lint-proto` (buf), `lint-toml` (taplo). The
     non-Python tools run via `npx`/`uvx`/`docker`, so a contributor needs **Node, uv, and Docker**
     on PATH (plus `shfmt`); `pre-commit` runs the same checks on changed files. Link-checking
     (`lychee`) runs on a weekly schedule, not per-PR.
   - **test-dashboard** — the dashboard `pytest` suite (must stay ≥ the **80% total coverage gate**).
     CI also runs **`make test-patch-coverage`** (`diff-cover`): new/changed lines must be **≥ 90%**
     covered vs `origin/develop`, the ratchet that stops coverage rotting at the margin.
   - **test-stack** — the `pithead` shell test suite.
   - **test-compose** — `docker-compose.yml` interpolation validation.
   - **test-integration-selftest** — the integration harness's own pure logic.
   - **test-fakes** — the tier-2 contract test (real dashboard clients vs controllable fakes).
   - the **test-inventory drift check** — fails if a test was added/removed without
     regenerating [`docs/test-inventory.md`](docs/test-inventory.md) (`make test-inventory`).

   Bigger, infra-dependent suites run separately: `make test-mini-stack` (tier-3 docker) and
   `make test-integration` (tier-4 live, against a real box; start with `--check`).

4. Add or update tests for your change. Cover the *intent* (a behavior/contract), not just
   the line. The [Testing Guide](docs/testing-guide.md) has per-change recipes; the
   [Testing Strategy](docs/testing-strategy.md) explains the tiers.
5. Update the docs in [`docs/`](docs/) (and the README, if relevant) for any
   user-facing change, and run `make test-inventory` if you touched the test suites.

## Opening a pull request

- Target the `develop` branch and fill out the PR template.
- Link the issue your PR addresses (e.g. `Closes #123`).
- Make sure `make test` passes; CI runs the same checks.
- PRs require review before merging; reviewers are requested automatically via
  [CODEOWNERS](.github/CODEOWNERS).

## Style

- Match the surrounding code. Shell scripts should pass `shellcheck --severity=warning`;
  Python is linted and formatted by `ruff` (config in `build/dashboard/pyproject.toml`).
  Run `make lint-py`, or `cd build/dashboard && ruff format` to apply it.
- Keep commits tidy and messages descriptive.

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).
