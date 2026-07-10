# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: test test-dashboard test-patch-coverage test-stack test-compose test-integration test-integration-selftest test-fakes test-mini-stack lint lint-sh lint-py lint-js lint-yaml lint-md lint-proto lint-toml release

test: lint test-dashboard test-stack test-compose test-integration-selftest test-fakes ## Run everything that doesn't need a server/docker

test-dashboard: ## Dashboard unit/component tests with coverage gate (deps from uv.lock); emits coverage.xml
	cd build/dashboard && uv run --locked --extra test python -m pytest \
		--cov=mining_dashboard --cov-report=term-missing --cov-report=xml --cov-fail-under=80

test-patch-coverage: ## diff-cover (#286): new/changed lines must be >=90% covered (run after test-dashboard)
	cd build/dashboard && uv run --locked --extra test \
		diff-cover coverage.xml --compare-branch=origin/develop --fail-under=90

test-stack: ## pithead shell test suite
	bash tests/stack/run.sh

test-compose: ## Validate docker-compose.yml interpolation + hardening invariants (#90)
	bash tests/stack/test_compose.sh

test-integration-selftest: ## Integration harness pure-logic self-test (no server needed)
	bash tests/integration/selftest.sh

test-fakes: ## Fake-daemon contract test — real dashboard clients vs controllable fakes (no docker)
	uv run --locked --project build/dashboard --extra test python -m pytest tests/integration/fakes -q

test-mini-stack: ## Fake-daemon docker mini-stack end-to-end (needs docker; CI)
	bash tests/integration/mini-stack/run-mini-stack.sh

test-inventory: ## Write the test coverage inventory to docs/test-inventory.md (generated, git-ignored)
	bash tests/inventory.sh > docs/test-inventory.md

# End-to-end matrix against a REAL test server (issue #54). Needs a provisioned box; pass
# connection + options through ARGS, e.g.:
#   make test-integration ARGS="--host miner@10.0.0.5 --dir pithead --lifecycle"
# See docs/integration-testing.md.
test-integration: ## Run the live config-matrix integration suite (requires a test box; pass ARGS=...)
	bash tests/integration/run.sh $(ARGS)

lint: lint-sh lint-py lint-js lint-yaml lint-md lint-docs-voice lint-proto lint-toml ## Lint/format-check every surface

lint-sh: ## shellcheck + shfmt over the CLI, build/* container scripts, release + test scripts
	shellcheck --severity=warning pithead scripts/*.sh build/*/*.sh tests/stack/run.sh tests/stack/test_compose.sh \
		tests/inventory.sh tests/integration/*.sh tests/integration/mini-stack/*.sh
	shfmt -i 4 -d pithead $(shell git ls-files '*.sh')

lint-py: ## ruff lint + format check on all repo Python (ruff runs via uv from the locked dev extra)
	uv run --locked --project build/dashboard --extra dev ruff check .
	uv run --locked --project build/dashboard --extra dev ruff format --check .

lint-js: ## Biome lint + format check on the static frontend (config: biome.json)
	npx --yes @biomejs/biome@2.5.0 check .

lint-yaml: ## yamllint over all tracked YAML (config: .yamllint)
	uvx yamllint $(shell git ls-files '*.yml' '*.yaml')

lint-md: ## markdownlint over all Markdown (config: .markdownlint-cli2.jsonc)
	npx --yes markdownlint-cli2@0.18.1

lint-docs-voice: ## Fail if banned marketing words appear in prose docs (house voice: docs/STYLE.md)
	bash scripts/lint-docs-voice.sh

lint-proto: ## buf lint + build on the vendored Tari protos (config: .../tari/proto/buf.yaml)
	cd build/dashboard/mining_dashboard/client/tari/proto && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 lint && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 build

lint-toml: ## taplo TOML format check (config: .taplo.toml)
	npx --yes @taplo/cli@0.7.0 fmt --check

# Cut a release from the private build/test server — GHCR publish, gated on the test suite +
# the #54 integration matrix (issue #44). Pass options through ARGS, e.g. a safe plan-only preview:
#   make release ARGS="--dry-run"
# See docs/releasing.md.
release: ## Cut a versioned release (build -> stage -> smoke -> promote -> publish). Pass ARGS=...
	bash scripts/release.sh $(ARGS)
