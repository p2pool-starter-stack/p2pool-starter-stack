# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/releasing.md`](docs/releasing.md).

## [Unreleased]

### Added

- A four-tier test strategy for simulating every runtime situation (#54), documented in
  `docs/testing-strategy.md` with a full scenario catalog:
  - **Live config-matrix suite** (`tests/integration/`, tier 4) that drives a real, synced
    server through the config matrix and asserts the stack behaves — containers healthy, nodes
    synced, miners mining, dashboard reading correct live state, `status` exit codes, secrets
    preserved. Runs over SSH or `--local`; the blocking pre-release gate. A `--fault-injection`
    phase deliberately breaks monerod (stop / SIGSTOP / remove) to assert `pithead status`'
    down/unhealthy/missing verdicts and the failover→recovery cycle. `make test-integration`.
  - **Controllable fake monerod/Tari + a contract test** (`tests/integration/fakes/`, tier 2)
    that points the real dashboard clients at the fakes and asserts they parse every state —
    docker-free, runs on every PR. `make test-fakes`.
  - **Fake-daemon docker mini-stack** (`tests/integration/mini-stack/`, tier 3) running the real
    dashboard + docker-control proxy against the fakes, asserting sync hold/release and Tari
    reject/readmit end-to-end with real containers (`make test-mini-stack`). Validated green
    (11/11) on a real Docker host, and isolated (namespaced container names + non-colliding
    ports) so it can run safely beside a live deployment.
  - New dashboard unit tests for the required-Tari sync gate, the #35-latch × #31-failover
    interaction, and simultaneous double outages.
  - A generated **test inventory** (`docs/test-inventory.md`, `make test-inventory`) listing
    every test/scenario across all suites, kept honest by a CI drift check.
  - A non-destructive **`--check`** mode for the live harness (assert the box's current state —
    no config change/apply/restore); the safe first run / ongoing health check. Validated with
    a 22/22 green run against a real synced, mining box, which calibrated the harness to trust
    monerod's own sync flag (a synced local node's dashboard sync panel reads "loading") and
    `proxy_workers` for mining liveness (`stratum.conns` can read 0 while mining).
  - A developer testing guide (`docs/testing-guide.md`): per-change recipes, conventions, and
    the calibration gotchas learned on real hardware.
  - Regression guards for past bugs/security fixes: extended the #90 hardening section of
    `tests/stack/test_compose.sh` with per-service least-privilege checks for the Docker socket
    proxies (the read proxy can't POST; the control proxy is start/stop-only; both mount the
    socket read-only) and the Tari `[m]inotari` self-match guard — alongside the existing
    no-new-privileges / cap_drop / credential-free-healthcheck assertions. Plus a
    `dashboard.host` "auto"-revert test and the schema-migration test that caught the DB upgrade
    bug above.
  - Release/validation-server tooling: a `--readiness` mode for the live harness (non-destructive
    assessment that a box is fit to be a release server — synced chains reusable, snapshot-capable
    filesystem, disk headroom, secrets owner-only, dashboard localhost-only), a
    `docs/release-server.md` guide (why end-to-end validation needs a dedicated server vs. what
    GitHub Actions runs free on every PR, the hardening checklist, and the **safe** self-hosted-
    runner setup), and a `release-gate.yml` workflow that runs the tier-4 matrix on a self-hosted
    runner only on trusted code (manual dispatch / push to main — never on a fork PR).
  - A `--safety-backup` rollback net for the live harness: takes a real `pithead backup` before
    the destructive scenarios and automatically rolls the box back (down → restore → up) if
    anything fails, removing the archive on success — so the destructive matrix can run on a
    precious box. The `--lifecycle` phase also does a `backup` → `restore` round-trip (assert the
    pool reverts and secrets survive), exercising both verbs end-to-end.
  - `UPDATE_INTERVAL` is now env-configurable (lets the mini-stack loop fast in CI).
- Dashboard header shows the host's **IP address** next to the hostname when the configured
  `dashboard.host` is a name, as `hostname @ ip` (e.g. `pithead.local @ 192.168.1.42`), so you can still reach the
  dashboard when the hostname doesn't resolve from your phone or another machine on the LAN. The
  address is detected on the host (the dashboard runs `network_mode: host`), and is omitted when
  the host is already an IP or can't be determined (#119).
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
- `pithead doctor` now checks that Docker is enabled to start at boot (systemd) and warns if not —
  `restart: unless-stopped` only brings the stack back after a reboot when the daemon does too,
  which matters for an unattended miner (#137).
- Low-disk warning badge in the dashboard header (#138): a heads-up at 85% used of the data
  filesystem and a prominent critical alert at 95%, on both the sync and main screens — the disk
  bar alone is easy to miss, and a full data disk corrupts the Monero database mid-write.

### Changed

- The Compose **project name is now pinned to `pithead`** (`name:` in `docker-compose.yml`), so
  the stack's images, network and volumes are prefixed `pithead*` regardless of the checkout
  directory — instead of inheriting the directory's name (which left older checkouts named after
  the repo's previous name). `pithead up`/`apply`/`upgrade` detect a stack still running under
  the old, directory-derived project name and migrate it automatically (only that project's
  containers are removed so the renamed project can take over — bind-mounted chain data and the
  Tor onion keys are untouched). One-time after the rename, Caddy re-issues its local TLS cert
  under the new project, so re-trust the dashboard cert if you'd installed the old one.
- Hardened the leaf containers (caddy, xmrig-proxy, dashboard, docker-proxy, docker-control)
  with `no-new-privileges`. All except the dashboard also `cap_drop: [ALL]` (caddy keeps
  `NET_BIND_SERVICE` for `:80`/`:443`); the dashboard keeps its default capabilities because it
  writes its SQLite history into a host-user-owned volume as root. Caddy and the two Docker
  socket proxies additionally run with a read-only root filesystem (ephemeral `tmpfs` for
  scratch; Caddy's certs persist in `caddy_data`).
- Log rotation (`json-file`, 10 MB × 3) now applies to **every** service — `caddy`,
  `docker-proxy`, and `docker-control` previously fell back to Docker's uncapped default, so
  their logs could grow without bound and fill the disk on a long-running host (#123).

### Fixed

- `pithead backup` no longer aborts when `du`/`df` exit non-zero on an unreadable file or a
  transient FS error — the disk-space pre-check now degrades gracefully (its "proceeding without
  a space check" fallback was previously unreachable under `set -e`) (#127).
- `pithead doctor` now exits non-zero when a critical check FAILS, so it can be used as a
  cron/CI/monitoring health gate (it previously always exited 0); warnings alone still exit 0 (#127).
- Dashboard P2Pool pool-type detection (Main/Mini/Nano) now matches the peer's port exactly
  instead of as a substring of the whole peer string, so a peer on an unrelated port that merely
  contains the digits can't misclassify the sidechain (which drives block-time and the PPLNS
  window the XvB controller uses) (#142).
- `pithead reset-dashboard` now resolves the data directories it wipes from `.env` (the live
  deployment) instead of re-reading `config.json` — editing a `*.data_dir` in `config.json`
  before resetting (without an `apply`) can no longer wipe a directory the stack never used. It
  also refuses to run rather than guess if `.env` doesn't name them (#139).

### Fixed

- Dashboard pruned/full label (#32) always showed **Full** on local nodes: the dashboard parsed
  `MONERO_PRUNE` with `== "true"`, but pithead writes it as `1`/`0`, so a pruned node read as
  Full. Now accepts `1`/`true`/`yes`/`on`. Found by the live integration harness on a real box.
- Dashboard DB upgrade path: opening a database created by an early (pre-`timestamp`) schema
  threw `no such column: timestamp` and aborted the migration, leaving the DB half-upgraded —
  `_create_tables` built the `idx_ts` index on a column `_migrate_db` hadn't added yet. Indexes
  are now created after migrations. Found by a new schema-migration intent test.

### Security

- The monerod RPC credentials are no longer interpolated into the compose healthcheck command
  (they were readable via `docker inspect`); the healthcheck now reads them from the container
  environment via a script.
- Documented that the stratum port defaults to all interfaces and should be firewalled to the
  LAN — see [Connecting Miners › Firewall](docs/workers.md#firewall).
- All externally-pulled base/runtime images are now pinned by immutable `@sha256` digest
  (caddy, docker-socket-proxy, the Tari node, and the `ubuntu`/`python`/`alpine` build bases),
  so a re-pushed tag or a registry MITM can't silently change the running image (#135).
- `dashboard.host` is now validated (hostname/IP characters only) before it's rendered into the
  Caddyfile, so a value containing whitespace, a newline, or `{`/`}` can no longer break the
  Caddyfile or inject reverse-proxy directives — mirroring the `stratum_bind` validation (#130).
