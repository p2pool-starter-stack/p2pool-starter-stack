# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: test test-dashboard test-stack test-compose lint

test: lint test-dashboard test-stack test-compose ## Run everything

test-dashboard: ## Dashboard unit/component tests with coverage gate
	cd build/dashboard && PYTHONPATH=. python3 -m pytest \
		--cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

test-stack: ## pithead shell test suite
	bash tests/stack/run.sh

test-compose: ## Validate docker-compose.yml interpolation
	bash tests/stack/test_compose.sh

lint: ## shellcheck the stack scripts
	shellcheck --severity=warning pithead tests/stack/run.sh tests/stack/test_compose.sh
