# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: test test-dashboard test-stack test-compose test-integration test-integration-selftest test-fakes test-mini-stack lint lint-sh lint-py release

test: lint test-dashboard test-stack test-compose test-integration-selftest test-fakes ## Run everything that doesn't need a server/docker

test-dashboard: ## Dashboard unit/component tests with coverage gate
	cd build/dashboard && PYTHONPATH=. python3 -m pytest \
		--cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

test-stack: ## pithead shell test suite
	bash tests/stack/run.sh

test-compose: ## Validate docker-compose.yml interpolation + hardening invariants (#90)
	bash tests/stack/test_compose.sh

test-integration-selftest: ## Integration harness pure-logic self-test (no server needed)
	bash tests/integration/selftest.sh

test-fakes: ## Fake-daemon contract test — real dashboard clients vs controllable fakes (no docker)
	PYTHONPATH=build/dashboard python3 -m pytest tests/integration/fakes -q

test-mini-stack: ## Fake-daemon docker mini-stack end-to-end (needs docker; CI)
	bash tests/integration/mini-stack/run-mini-stack.sh

test-inventory: ## Regenerate the test coverage inventory (docs/test-inventory.md)
	bash tests/inventory.sh > docs/test-inventory.md

test-inventory-check: ## Fail if docs/test-inventory.md is stale (CI drift guard)
	@bash tests/inventory.sh | diff -u docs/test-inventory.md - \
		&& echo "test-inventory is up to date" \
		|| { echo "docs/test-inventory.md is stale — run 'make test-inventory'"; exit 1; }

# End-to-end matrix against a REAL test server (issue #54). Needs a provisioned box; pass
# connection + options through ARGS, e.g.:
#   make test-integration ARGS="--host miner@10.0.0.5 --dir pithead --lifecycle"
# See docs/integration-testing.md.
test-integration: ## Run the live config-matrix integration suite (requires a test box; pass ARGS=...)
	bash tests/integration/run.sh $(ARGS)

lint: lint-sh lint-py ## Lint every surface (shell + Python)

lint-sh: ## shellcheck the CLI, the build/* container scripts, the release script, and the test scripts
	shellcheck --severity=warning pithead scripts/*.sh build/*/*.sh tests/stack/run.sh tests/stack/test_compose.sh \
		tests/inventory.sh tests/integration/*.sh tests/integration/mini-stack/*.sh

lint-py: ## ruff lint + format check on all repo Python (install ruff: pip install -e "build/dashboard[dev]")
	ruff check . && ruff format --check .

# Cut a release from the private build/test server (gouda) — GHCR publish, gated on the test suite +
# the #54 integration matrix (issue #44). Pass options through ARGS, e.g. a safe plan-only preview:
#   make release ARGS="--dry-run"
# See docs/releasing.md.
release: ## Cut a versioned release (build -> stage -> smoke -> promote -> publish). Pass ARGS=...
	bash scripts/release.sh $(ARGS)
