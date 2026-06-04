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
- `p2pool.stratum_bind` config option to choose which host interface the stratum port
  (`3333`) is published on (default `0.0.0.0`; set a LAN IP or `127.0.0.1` to narrow it).
- Liveness healthcheck for the p2pool container (probes the stratum port), so a stalled
  p2pool is now visible in `pithead status` and the dashboard.

### Changed

- Hardened the leaf containers (caddy, xmrig-proxy, dashboard, docker-proxy, docker-control)
  with `no-new-privileges`. All except the dashboard also `cap_drop: [ALL]` (caddy keeps
  `NET_BIND_SERVICE` for `:80`/`:443`); the dashboard keeps its default capabilities because it
  writes its SQLite history into a host-user-owned volume as root. Caddy and the two Docker
  socket proxies additionally run with a read-only root filesystem (ephemeral `tmpfs` for
  scratch; Caddy's certs persist in `caddy_data`).

### Security

- The monerod RPC credentials are no longer interpolated into the compose healthcheck command
  (they were readable via `docker inspect`); the healthcheck now reads them from the container
  environment via a script.
- Documented that the stratum port defaults to all interfaces and should be firewalled to the
  LAN — see [Connecting Miners › Firewall](docs/workers.md#firewall).
