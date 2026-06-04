# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: test test-dashboard test-stack test-compose test-integration test-integration-selftest test-fakes test-mini-stack lint

test: lint test-dashboard test-stack test-compose test-integration-selftest test-fakes ## Run everything that doesn't need a server/docker

test-dashboard: ## Dashboard unit/component tests with coverage gate
	cd build/dashboard && PYTHONPATH=. python3 -m pytest \
		--cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

test-stack: ## pithead shell test suite
	bash tests/stack/run.sh

test-compose: ## Validate docker-compose.yml interpolation
	bash tests/stack/test_compose.sh

test-integration-selftest: ## Integration harness pure-logic self-test (no server needed)
	bash tests/integration/selftest.sh

test-fakes: ## Fake-daemon contract test — real dashboard clients vs controllable fakes (no docker)
	PYTHONPATH=build/dashboard python3 -m pytest tests/integration/fakes -q

test-mini-stack: ## Fake-daemon docker mini-stack end-to-end (needs docker; CI)
	bash tests/integration/mini-stack/run-mini-stack.sh

# End-to-end matrix against a REAL test server (issue #54). Needs a provisioned box; pass
# connection + options through ARGS, e.g.:
#   make test-integration ARGS="--host miner@10.0.0.5 --dir pithead --lifecycle"
# See docs/integration-testing.md.
test-integration: ## Run the live config-matrix integration suite (requires a test box; pass ARGS=...)
	bash tests/integration/run.sh $(ARGS)

lint: ## shellcheck the stack scripts
	shellcheck --severity=warning pithead tests/stack/run.sh tests/stack/test_compose.sh \
		tests/integration/*.sh tests/integration/mini-stack/*.sh
