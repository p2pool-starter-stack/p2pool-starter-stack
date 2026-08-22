# Contributing to Pithead

The workflow for contributing bug fixes, docs changes, and features.

## Before you start

- Open an issue before writing code for anything beyond a small fix. Discuss the approach
  there first.
- Check the [open issues](https://github.com/p2pool-starter-stack/pithead/issues) for existing
  work on the same thing.
- This project follows a [Code of Conduct](CODE_OF_CONDUCT.md); by participating you agree to uphold it.

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
   commits only — it fast-forwards to each release's tagged commit, see
   [Releasing › Branch mechanics](docs/dev/releasing.md#branch-mechanics)).
2. Make your change. Keep it focused: one logical change per PR.
3. Run the full test suite locally:

   ```bash
   make test
   ```

   This runs everything CI does that doesn't need a live test server:

   - **lint** — every file surface gets a linter/formatter check (`make lint` runs them all; run one
     with `make lint-<surface>`): `lint-sh` (shellcheck + shfmt), `lint-py` (ruff), `lint-js` (Biome),
     `lint-yaml` (yamllint), `lint-md` (markdownlint), `lint-docs-voice` (banned-word check),
     `lint-operator-strings` (no issue/PR numbers in operator-facing `pithead`/dashboard text, and
     no bare `docs/` paths in `pithead` operator text — release bundles ship no `docs/`, so point at
     `$DOCS_URL/docs/<file>.md#anchor` instead; comments keep the plain path),
     `lint-topology` (no real-looking IPv6/IPv4 literal, `/home/<name>` path, `.lan`/`.internal`/
     `.local` hostname, or `user@host` string — a public repo, so every one of those has to stay a
     generic class, not a trace of whoever's actual box; `tests/` and `docs/` are an accepted
     exemption boundary for illustrative/fixture content, and each class also carries a small,
     explicit value-level allowlist — see the script's own header — never a per-file exemption
     comment), `lint-proto` (buf), `lint-toml` (taplo). The
     non-Python tools run via `npx`/`uvx`/`docker`, so a contributor needs **Node, uv, and Docker**
     on PATH (plus `shfmt`); `pre-commit` runs the same checks on changed files. Link-checking
     (`lychee`) runs on a weekly schedule, not per-PR.
   - **test-dashboard** — the dashboard `pytest` suite (must stay ≥ the **80% total coverage gate**).
     CI also runs **`make test-patch-coverage`** (`diff-cover`): new/changed lines must be **≥ 90%**
     covered vs `origin/develop`, the ratchet that stops coverage rotting at the margin. The gate
     says so explicitly when a diff has nothing it measures (shell/docs-only PRs pass loudly), and
     fails if a changed dashboard Python file is missing from `coverage.xml` entirely — the
     silent no-op it used to be. Run it right after `make test-dashboard`, so `coverage.xml`
     is fresh.
   - **test-frontend** — the frontend logic tests (`node --test`); uses the same Node that the
     lint surfaces already require.
   - **test-stack** — the `pithead` shell test suite.
   - **test-compose** — `docker-compose.yml` interpolation validation.
   - **test-integration-selftest** — the integration harness's own pure logic.
   - **test-fakes** — the tier-2 contract test (real dashboard clients vs controllable fakes).

   Bigger, infra-dependent suites run separately: `make test-mini-stack` (tier-3 docker) and
   `make test-integration` (tier-4 live, against a real box; start with `--check`).

4. Add or update tests for your change. Cover the *intent* (a behavior/contract), not just
   the line. The [Testing Guide](docs/dev/testing-guide.md) has per-change recipes; the
   [Testing Strategy](docs/dev/testing-strategy.md) explains the tiers.
5. Update the docs in [`docs/`](docs/) (and the README, if relevant) for any
   user-facing change. To see what the suites cover, `make test-inventory` writes a
   generated (git-ignored) inventory you can read locally.

### The two lanes, and what that means for CI config

The stack ships two ways from one repo. `develop` is the integration branch for the Docker Compose
product and is the repo's **default branch**. `develop-v2` is its twin: everything on `develop`,
plus the appliance OS tree under `os/`. Appliance work targets `develop-v2`; everything else
targets `develop`, and `develop` is merged into `develop-v2` to keep the twins level.

**Automation that GitHub reads from a fixed location must live on `develop`, and must name the
appliance branch explicitly when it needs the appliance tree.** GitHub fires a workflow's
`schedule:` trigger from the default branch only, and Dependabot reads `.github/dependabot.yml`
from the default branch only. A scheduled workflow or a Dependabot entry that lives on
`develop-v2` never runs — and a job that never runs looks exactly like a job that ran and found
nothing, which is why this went unnoticed three times (#1146, #1162, #1163). #1048 is its sibling
and worth knowing next to it: there the schedule did fire, and the job skipped itself behind an
unset repository variable, so `main` showed green for a gate that had never run.

Living on `develop` is only half of it. A workflow on `develop` still checks out `develop`, which
has no `os/`, so the appliance lane is reached by an explicit ref
(`.github/workflows/os-rootfs.yml`) or by `target-branch:` (`.github/dependabot.yml`). Both files
carry a comment saying why they are deliberately asymmetric; do not "tidy" either onto `develop-v2`.

Check this from run history, never from the file — the file always looks fine:

```bash
gh run list --workflow=<name>.yml --limit 200 --json event \
  --jq '[.[].event] | group_by(.) | map({event: .[0], n: length})'
```

No `schedule` key in that breakdown means the schedule has never fired. A `schedule` key is
necessary but not sufficient — #1048's shape passes that test — so open the newest scheduled run and
check its steps actually ran rather than skipping:

```bash
gh run view <run-id> --json jobs \
  --jq '.jobs[].steps[] | "\(.conclusion)  \(.name)"'
```

The Dependabot equivalent of the first check is to group its PRs by `baseRefName`.

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
