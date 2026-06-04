# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/releasing.md`](docs/releasing.md).

## [Unreleased]

### Added

- End-to-end integration test suite (`tests/integration/`) that drives a real, already-synced
  Pithead server through the config matrix and asserts the stack behaves — containers healthy,
  nodes synced, miners mining, the dashboard reading correct live state, `status` exit codes,
  and secrets preserved across re-applies. Runs over SSH or `--local`, reuses the synced chain
  data dirs (never re-syncs), and is the blocking pre-release gate (#54). Surfaced as `make
  test-integration`; a pure-logic `selftest` runs in CI on every PR. See
  `docs/integration-testing.md`.
- Release & versioning scaffold: top-level `VERSION` file (single source of truth),
  this changelog, and `docs/releasing.md` documenting the release process. The
  GHCR publishing pipeline and `make release` / `pithead release` command are still
  to come (see `docs/releasing.md`).
