# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: test test-dashboard test-frontend test-patch-coverage test-stack test-compose test-integration test-integration-selftest test-fakes test-mini-stack lint lint-sh lint-py lint-js lint-yaml lint-md lint-proto lint-toml lint-topology lint-file-budget release release-smoke

test: lint test-dashboard test-frontend test-stack test-compose test-integration-selftest test-fakes ## Run everything that doesn't need a server/docker

test-dashboard: ## Dashboard unit/component tests with coverage gate (deps from uv.lock); emits coverage.xml
	cd build/dashboard && uv run --locked --extra test python -m pytest \
		--cov=mining_dashboard --cov-report=term-missing --cov-report=xml --cov-fail-under=80

test-frontend: ## Frontend logic tests with Node's built-in runner (#632; same invocation as CI)
	node --test build/dashboard/tests/frontend/*.test.mjs

test-patch-coverage: ## diff-cover (#286) minus its vacuous pass (#1000): >=90% on changed lines (run after test-dashboard)
	bash scripts/patch-coverage.sh

test-stack: ## pithead shell test suite
	bash tests/stack/run.sh
	bash tests/stack/test_data_reset.sh
	bash tests/stack/test_firstboot_journal.sh
	bash tests/stack/test_appliance_hugepages.sh

test-compose: ## Validate docker-compose.yml interpolation + hardening invariants (#90)
	bash tests/stack/test_compose.sh

test-integration-selftest: ## Integration harness pure-logic self-test (no server needed)
	bash tests/integration/selftest.sh

test-fakes: ## Fake-daemon contract test — real dashboard clients vs controllable fakes (no docker)
	uv run --locked --project build/dashboard --extra test python -m pytest tests/integration/fakes -q

test-mini-stack: ## Fake-daemon docker mini-stack end-to-end (needs docker; CI)
	bash tests/integration/mini-stack/run-mini-stack.sh

test-inventory: ## Write the test coverage inventory to docs/dev/test-inventory.md (generated, git-ignored)
	bash tests/inventory.sh > docs/dev/test-inventory.md

# End-to-end matrix against a REAL test server (issue #54). Needs a provisioned box; pass
# connection + options through ARGS, e.g.:
#   make test-integration ARGS="--host miner@10.0.0.5 --dir pithead --lifecycle"
# See docs/dev/integration-testing.md.
test-integration: ## Run the live config-matrix integration suite (requires a test box; pass ARGS=...)
	bash tests/integration/run.sh $(ARGS)

lint: lint-sh lint-py lint-js lint-yaml lint-md lint-docs-voice lint-operator-strings lint-topology lint-file-budget lint-proto lint-toml ## Lint/format-check every surface

lint-sh: ## shellcheck + shfmt over the CLI, build/* container scripts, release + test scripts
	shellcheck --severity=warning pithead pithead-completion.bash install.sh scripts/*.sh build/*/*.sh tests/stack/run.sh tests/stack/lib.sh tests/stack/test-*.sh tests/stack/test_compose.sh tests/stack/test_data_reset.sh tests/stack/test_firstboot_journal.sh \
	shellcheck --severity=warning pithead pithead-completion.bash install.sh scripts/*.sh build/*/*.sh tests/stack/run.sh tests/stack/lib.sh tests/stack/test-*.sh tests/stack/test_compose.sh tests/stack/test_data_reset.sh tests/stack/test_appliance_hugepages.sh \
		tests/inventory.sh tests/integration/*.sh tests/integration/mini-stack/*.sh \
		os/installer/pithead-install os/build-image.sh os/rauc/*.sh os/overlay/pithead-sync os/overlay/pithead-boot \
		os/overlay/pithead-data-reset os/overlay/pithead-mount-generator os/overlay/pithead-ssh-host-keys \
		os/overlay/pithead-machine-id os/overlay/pithead-media-config os/overlay/pithead-hugepages \
		os/overlay/pithead-journal-persist \
		tests/os/run.sh tests/os/verify-image.sh tests/os/hugepages-boot-verdict.sh
	shfmt -i 4 -d pithead pithead-completion.bash os/installer/pithead-install $(shell git ls-files '*.sh' | grep -v '^docs/research/')

lint-py: ## ruff lint + format check on all repo Python (ruff runs via uv from the locked dev extra)
	uv run --locked --project build/dashboard --extra dev ruff check .
	uv run --locked --project build/dashboard --extra dev ruff format --check .

lint-js: ## Biome lint + format check on the static frontend (config: biome.json)
	npx --yes @biomejs/biome@2.5.0 check .

lint-yaml: ## yamllint over all tracked YAML (config: .yamllint)
	uvx yamllint $(shell git ls-files '*.yml' '*.yaml')

lint-md: ## markdownlint over all Markdown (config: .markdownlint-cli2.jsonc)
	npx --yes markdownlint-cli2@0.18.1

lint-docs-voice: ## Fail if banned marketing words appear in prose docs (house voice: docs/dev/STYLE.md)
	bash scripts/lint-docs-voice.sh

lint-operator-strings: ## Fail if a #NNN issue/PR number or a bare docs/ path leaks into pithead or dashboard operator-facing text (#755, #1024)
	bash scripts/lint-operator-strings.sh --self-test
	bash scripts/lint-operator-strings.sh

lint-topology: ## Fail if a real-looking IPv6/IPv4/hostname/path/user@host literal leaks into the repo (generic classes only)
	bash scripts/lint-topology-classes.sh --self-test
	bash scripts/lint-topology-classes.sh

lint-file-budget: ## Fail if a tracked file crosses the 800-line hard ceiling, or an existing offender grows past its docs/dev/file-budget.tsv ceiling (#1105 Phase 0)
	bash scripts/lint-file-budget.sh --self-test
	bash scripts/lint-file-budget.sh

lint-proto: ## buf lint + build on the vendored Tari protos (config: .../tari/proto/buf.yaml)
	cd build/dashboard/mining_dashboard/client/tari/proto && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 lint && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 build

lint-toml: ## taplo TOML format check (config: .taplo.toml)
	@# Tracked files only, never a filesystem walk: taplo's walker panics on any unreadable
	@# dir (EACCES scandir — e.g. root-owned artifacts under .claude/ agent worktrees).
	@test -n "$$(git ls-files '*.toml')" || { echo "lint-toml: zero tracked TOML files — refusing a vacuous pass"; exit 1; }
	git ls-files -z '*.toml' | xargs -0 npx --yes @taplo/cli@0.7.0 fmt --check

# Cut a release from the private build/test server — GHCR publish, gated on the test suite +
# the #54 integration matrix (issue #44). Pass options through ARGS, e.g. a safe plan-only preview:
#   make release ARGS="--dry-run"
# See docs/dev/releasing.md.
release: ## Cut a versioned release (build -> stage -> smoke -> promote -> publish). Pass ARGS=...
	bash scripts/release.sh $(ARGS)

# Post-publish smoke test (#459) — run ONCE, right after `make release` publishes vX.Y.Z. Real
# cosign verify of the published bundle + images, and (with ARGS="--upgrade DIR") the real #59
# one-click upgrade against a previous-release install. See docs/dev/releasing.md § Post-publish smoke.
#   make release-smoke                         # verify the just-published version's signature/bundle
#   make release-smoke ARGS="--upgrade /srv/code/previous"   # + drive the real #59 upgrade
release-smoke: ## Post-publish: real cosign verify + real #59 upgrade against the published bundle. Pass ARGS=...
	bash scripts/release-smoke.sh $(ARGS)
