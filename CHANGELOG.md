# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/releasing.md`](docs/releasing.md).

## [Unreleased]

### Added

- Dashboard header now shows which build is running, as a muted badge on both the
  syncing and main screens: a clean release shows `vX.Y.Z` (from the top-level
  `VERSION` file), while any dev/working-tree build shows `dev · branch @ hash` so
  it's never mistaken for a release. The version is baked into the dashboard image at
  build time (build-arg → env + OCI labels), so the running container is
  self-describing.
- Release & versioning scaffold: top-level `VERSION` file (single source of truth),
  this changelog, and `docs/releasing.md` documenting the release process. The
  GHCR publishing pipeline and `make release` / `pithead release` command are still
  to come (see `docs/releasing.md`).
