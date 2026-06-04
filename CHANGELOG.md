# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/releasing.md`](docs/releasing.md).

## [Unreleased]

### Added

- Responsive dashboard layout: the web UI now reflows for phone-sized screens — the header
  stacks, the card grid collapses to a single column, the disk bar goes full-width, and the
  workers table scrolls horizontally within its card instead of overflowing the page. Desktop
  is unchanged.
- Release & versioning scaffold: top-level `VERSION` file (single source of truth),
  this changelog, and `docs/releasing.md` documenting the release process. The
  GHCR publishing pipeline and `make release` / `pithead release` command are still
  to come (see `docs/releasing.md`).
