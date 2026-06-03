# Contributing to Pithead

Thanks for taking the time to contribute! Whether it's a bug fix, a docs tweak, or a
whole new feature, contributions are very welcome. This guide covers the workflow.

## Before you start

- **Found a bug or have an idea?** Open an issue first. For anything beyond a small fix,
  please discuss it in an issue before writing code — it saves everyone time and avoids
  surprises at review.
- Check the [open issues](https://github.com/p2pool-starter-stack/pithead/issues) to see
  if someone's already on it.

## Development workflow

1. Fork the repo and create a branch off `main`.
2. Make your change. Keep it focused — one logical change per PR.
3. Run the full test suite locally:

   ```bash
   make test
   ```

   This runs everything CI does:

   - **lint** — `shellcheck` over `pithead` and the test scripts. Keep `pithead`
     shellcheck-clean (no new warnings).
   - **test-dashboard** — the dashboard `pytest` suite, which must stay at or above the
     **80% coverage gate**.
   - **test-stack** — the `pithead` shell test suite.
   - **test-compose** — `docker-compose.yml` interpolation validation.

4. Update the docs in [`docs/`](docs/) (and the README, if relevant) for any
   user-facing change.

## Opening a pull request

- Target the `main` branch and fill out the PR template.
- Link the issue your PR addresses (e.g. `Closes #123`).
- Make sure `make test` passes — CI will run the same checks.
- PRs require review before merging; the right reviewers are requested automatically via
  [CODEOWNERS](.github/CODEOWNERS).

## Style

- Match the surrounding code. Shell scripts should pass `shellcheck --severity=warning`.
- Keep commits tidy and messages descriptive.

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE). Thanks again! 🙌
