# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/releasing.md`](docs/releasing.md).

## [Unreleased]

### Added

- **Earnings (estimated) card** on the dashboard's Advanced view: expected XMR per
  day / month / year from your current hashrate and the live Monero block reward and
  network difficulty, plus an expected time-to-share. Includes a what-if hashrate
  input (defaults to your measured hashrate) and a clear "estimates, not guarantees"
  disclaimer. XMR-only for now — Tari and the XvB tier estimate are deferred (#12).
- Release & versioning scaffold: top-level `VERSION` file (single source of truth),
  this changelog, and `docs/releasing.md` documenting the release process. The
  GHCR publishing pipeline and `make release` / `pithead release` command are still
  to come (see `docs/releasing.md`).
