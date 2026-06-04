# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/releasing.md`](docs/releasing.md).

## [Unreleased]

### Added

- **Telegram alerts (notifications-only)** (#121): the stack can push a small, high-value set
  of operational alerts to Telegram — **node down / recovered**, **worker offline / back
  online**, and **sync finished**. Off by default; enable it with a `telegram` block in
  `config.json` (`enabled`, `bot_token`, `chat_id`, and per-event `events` toggles). Every
  alert is **debounced** so a momentary blip won't ping you and you get one message per real
  transition: node edges reuse the existing failover detector, and worker offline/online uses a
  new flap-protected per-worker presence tracker. The `bot_token` is treated as a secret
  (owner-only `.env`, never logged), and sends **fail silently** on a Tor-only / offline host.
  Messages are prefixed with the dashboard hostname so multiple stacks can share one chat. Full
  walkthrough — creating a bot, finding your chat id, and the "one chat, two bots" pattern for
  sharing a chat with the Healthchecks.io monitor (#79) — in [`docs/telegram.md`](docs/telegram.md).
  The interactive bot / command interface remains a separate, later feature (#45).
- **P2Pool Earnings (estimated) card** on the dashboard's Advanced view: expected XMR
  per day / month / year from **P2Pool mining only**, computed from your P2Pool hashrate
  and the live Monero block reward + network difficulty, plus an expected time-to-share.
  Explicitly scoped to P2Pool — XvB donations are excluded (the what-if hashrate defaults
  to your P2Pool 1h average, the same figure shown in the header / Overview, which already
  excludes any XvB-donated slice, so an active XvB split doesn't inflate the estimate and
  the number stays consistent with the rest of the dashboard) and Tari merge-mining is
  excluded. Includes a what-if hashrate input and a clear "estimates, not guarantees"
  disclaimer. Tari (#117) and the XvB tier estimate (#118) are deferred (#12).
- Dashboard header now shows which build is running, as a muted badge on both the
  syncing and main screens: a clean release shows `vX.Y.Z` (from the top-level
  `VERSION` file), while any dev/working-tree build shows `dev · branch @ hash` so
  it's never mistaken for a release. The version is baked into the dashboard image at
  build time (build-arg → env + OCI labels), so the running container is
  self-describing.
- Per-worker share stats in the dashboard's Workers table: accepted / rejected (with invalid
  folded in) counts per rig, a **⚠** flag on a high reject rate, and a **Proxy totals** footer
  (pool-wide accepted / rejected / invalid + best difficulty) collected from the xmrig-proxy
  `/summary` endpoint. The proxy already reported all of this; it was being parsed and discarded
  (#82).
- Responsive dashboard layout: the web UI now reflows for phone-sized screens — the header
  stacks, the card grid collapses to a single column, the disk bar goes full-width, and the
  workers table scrolls horizontally within its card instead of overflowing the page. Desktop
  is unchanged.
- Dashboard branding (#81): the header now leads with the Pithead mark + wordmark and demotes
  the host IP to a subtitle, and a hero KPI band above the dashboard surfaces the headline
  numbers — total hashrate, shares in the PPLNS window, blocks found, XvB tier, and mining mode.
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
