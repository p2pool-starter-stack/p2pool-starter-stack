<!--
Thanks for contributing to Pithead! Please fill out the checklist below.
For anything non-trivial, open an issue first to discuss the change.
-->

## What & why

<!-- What does this PR change, and why? -->

## Related issue

<!-- e.g. Closes #123 -->
Closes #

## Checklist

- [ ] `make test` passes locally (lint + dashboard pytest ≥ coverage gate + `pithead` shell suite + compose validation)
- [ ] `pithead` and test scripts are shellcheck-clean (no new warnings)
- [ ] Docs in `docs/` (and the README, if relevant) are updated for any user-facing change, in the house voice (`docs/dev/STYLE.md`)
- [ ] New/changed behaviour is tested at the right tier (`docs/dev/testing-strategy.md`); patch coverage clears the gate
- [ ] This PR is focused on a single logical change
- [ ] A linked issue exists for non-trivial changes
