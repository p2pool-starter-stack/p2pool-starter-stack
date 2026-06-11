# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/releasing.md`](docs/releasing.md).

## [Unreleased]

### Added

- **Release pipeline — `scripts/release.sh` (`make release`)** (#44). A single entry point, run from
  the private build/test server, that cuts a versioned release end to end: preflight (clean tree,
  SemVer from `VERSION`, tag-not-already-released, resolve the component pins) → **blocking test gate**
  (`make test` + the #54 live integration matrix) → build the 5 first-party images with OCI labels +
  `PITHEAD_RELEASE=1` → push to a staging `:vX.Y.Z-rc.N` tag and capture digests → **smoke-verify the
  pushed images** from the registry → **promote by digest** to `:vX.Y.Z` + `:latest` (no rebuild, so
  the release is bit-for-bit what was tested) → publish the GitHub Release with an **ingredients
  manifest** (promoted digests + upstream pins) and a pinned install bundle. Safe by construction:
  `--dry-run` previews the whole plan, it never starts the live stack on the build host, and it never
  prints the registry token. Images publish to `ghcr.io/p2pool-starter-stack/pithead-*`
  (override via `PITHEAD_REGISTRY` / `PITHEAD_IMAGE_PREFIX`). The remaining hop for one-command
  pull-based installs — wiring `${STACK_VERSION}` into `docker-compose.yml` — is tracked in
  `docs/releasing.md`.

- **Chart hashrate-averaging-window toggle (#168).** A new **Avg** control on the dashboard chart
  plots any of xmrig-proxy's five native averaging windows — **1m / 10m / 1h / 12h / 24h**. It's
  separate from the existing time-**Range** buttons: Range sets how much time the x-axis spans, Avg
  sets how smooth each point is (short windows react to a rig dropping/joining within a poll or two;
  long windows show the underlying trend). **10m is the default**, so the chart is unchanged unless
  you switch — and the choice persists across reloads. Every option plots a *true* average for its
  window (the old headline "15m" was really the proxy's 10m relabeled; that's gone). All five windows
  are now captured per poll and persisted in their own history columns (additive migration, so
  existing databases upgrade in place); per-window history is **forward-only**, and the 12h/24h
  averages need that much rig uptime to fill — both are signposted in the UI. Display/observability
  only; the switching algorithm is untouched.
- **Optional dashboard login (#8).** A new `dashboard.auth` block puts a Caddy HTTP basic-auth prompt
  in front of the dashboard. It's **opt-in and off by default** — an empty `dashboard.auth.password`
  keeps today's behavior (no login), which is right for a private LAN appliance; set a password when
  the box is **shared or reachable beyond the LAN**. pithead bcrypt-hashes the password with the
  **already-pinned Caddy image** (`caddy hash-password`) and persists **only the hash** in `.env`
  (base64-encoded so bcrypt's `$` doesn't spam compose interpolation warnings) — the plaintext lives
  solely in your owner-only `config.json`. A sha256 fingerprint of the plaintext keeps the hash
  **stable across `apply` runs** (re-hashed only when the password actually changes, so the Caddyfile
  doesn't churn). The username/password are validated before render, the secret is **never echoed**
  in the change preview, and `apply` **warns** if a password is set without `dashboard.secure: true`
  (basic-auth is cleartext over plain HTTP). Documented in
  `docs/configuration.md#exposing-the-dashboard-safely`.
- **Explicit "VIP" win-eligibility indicator on the dashboard** (#158). To *collect* an XvB raffle
  win you must be a **VIP** — have a share in the P2Pool PPLNS window. This is universal across **all**
  tiers and independent of donation amount: a Mega donor pushing 1 MH/s with **no** PPLNS share is
  still skipped on a win, takes a fail, and is dropped from the raffle after the 3rd. The signal
  existed only implicitly (the "Shares in Window" stat turning red), so it was easy to miss what it
  meant. The Hero band and Simple Overview now show an explicit **VIP: Yes/No** (green/red), and a
  **"⚠ Not VIP — wins skipped"** badge appears while XvB is enabled with no share — so a high-tier
  donor can't silently waste donations on wins that won't count. Display/observability only — the
  donation controller already *protects* VIP eligibility; this surfaces it.
- **Two xmrig-proxy config knobs: optional stratum authentication (#152) and dev-fee transparency
  (#173).** `p2pool.stratum_password` (default off) turns the open `:3333` stratum port into
  *authenticated* stratum — only rigs that send the matching `pass` may mine, which also shrinks the
  #122 worker-name SSRF surface. `"auto"` generates and persists a stable secret (surfaced after
  `apply` and stored in `.env`), or set your own string; the password is cleartext over stratum, so
  it's access control, not encryption — pair it with `stratum_bind`/a firewall. `proxy.donate_level`
  exposes xmrig-proxy's built-in dev-fee donation (compiled-in default **0% — no fee**), now rendered
  **explicitly** so it's visible and operator-controllable — **default `0`** (off), or `1`–`99` to
  donate to the xmrig developers; this is **not** the XvB donation (`xvb.*`, steered by the optimizer).
  Both render to
  xmrig-proxy CLI flags (`--access-password` / `--donate-level`), are validated before render, and
  are documented in `docs/configuration.md` + `docs/workers.md#authentication`.
- **Expanded the `pithead` shell test suite over data-safety / security-relevant paths** (#140). The
  `backup`/`restore` round-trip is now covered end to end (stubbed `tar`/`du`/`df`/`docker`/`sudo`):
  archive layout (the irreplaceable bits in, blockchains out), the leading-`/` strip, a true
  restore-in-place round-trip, and the low-free-space pre-check (cancel + `--yes` proceed). Added
  `generate_caddyfile` HTTPS-vs-HTTP (`tls internal`) branch tests and unit tests for the previously
  uncovered `detect_os` / `detect_host_timezone` / `deps_satisfied` host-detection helpers. Test-only
  — would have caught the #127 `backup` errexit bug. (`upgrade` #128 and `doctor` #127 were already
  covered.)
- **CI now builds every container image, shellchecks all container scripts, and runs hadolint**
  (#124). Previously only the dashboard's *test* stage was built, so a broken Dockerfile / `COPY`
  path / entrypoint in monerod, P2Pool, Tor, or xmrig-proxy would only surface at deploy time — e.g.
  the Tor image's #180 entrypoint restructure shipped with no CI safety net. A `build-images` matrix
  now `docker build`s all five `build/*` images on every PR; `make lint` (the CI shellcheck step)
  gained the seven `build/*/*.sh` entrypoints + healthchecks; and a `hadolint` job lints the
  Dockerfiles (with a documented `.hadolint.yaml` ignore list for rules that conflict with the
  digest-pinning approach). CI shellcheck now runs via `make lint` so the file list can't drift.
- The live integration harness now asserts the **runtime privacy + resource posture**, closing the
  gap where these could regress silently past the tier-1 config checks: each service's `mem_limit` is
  actually in effect (#132), monerod makes no clearnet DNS (checkpoints off, no priority-node
  hostnames; #161), and Tari's resolver is the dead-address sinkhole rather than a clearnet
  nameserver (#162). Heavier live-coverage follow-ups filed as #201 (deploy on a non-default subnet),
  #202 (fault-inject a DB-write failure → `db_healthy`), and #203 (empty proxy token → fail closed).

- **Memory ceilings on every service** (#132). Only Tari was bounded before; now monerod, P2Pool, the
  dashboard, Tor, xmrig-proxy, and both Docker socket proxies each carry a `mem_limit` (with
  `memswap_limit == mem_limit` for a clean, swap-free OOM-kill). A leak or spike now OOM-restarts the
  offending container in its own cgroup instead of letting the host OOM-killer pick a victim — which
  could be monerod, the revenue service. The ceilings are generous (observed steady-state is far
  lower — monerod ~0.3 GiB RSS since its DB is reclaimable page cache, dashboard ~0.06, p2pool ~0.35);
  monerod's is tunable via the new **`monero.mem_limit`** config (default a generous 6 GB; its
  OOM-triggering memory is small — ~0.1 GiB at rest, ~1–3 GiB during sync — while its multi-GB DB is
  reclaimable mmap'd page cache, so initial-sync verification never trips it). The other (small)
  services carry fixed conservative ceilings.
- **`docs/privacy.md`** — a single source-of-truth network-egress reference (#164, the v1.0 close-out
  of the #160 privacy epic). It maps every off-box connection: whether it's Tor-routed, its default,
  and how to harden it — runtime egress (monerod/Tari over Tor with their clearnet DNS leaks closed;
  the XvB stats fetch now over Tor) plus the two clearnet yield paths still open in v1.0 (P2Pool
  outbound peers #165, XvB donation mining #166 — both Tor-by-default in v1.1) and the one-time
  build/install IP exposure. The absolute "your home IP isn't exposed" claims in the README,
  architecture, and FAQ are corrected to the honest **Tor-first, not yet Tor-only** reality, and all
  three cross-link the new guide.
- `pithead setup` and `doctor` now **warn when the host has a public IP** and stratum `:3333` is
  bound to all interfaces (#113). The stratum port is plain, unauthenticated stratum and must never
  face the public internet: a NAT'd home host has no public IP on its interfaces and stays silent,
  while a VPS/cloud or publicly-addressed host gets a clear nudge to firewall `:3333` to the LAN or
  narrow `p2pool.stratum_bind` (it also stays quiet if the bind is already narrowed). Warn-only,
  never fatal; `doctor` prints a ✓ when not exposed. A pure, unit-tested `is_public_ip` classifier
  handles the RFC1918 / CGNAT / ULA / link-local / loopback exclusions (IPv4 + IPv6).
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
    monerod's own sync flag as the readiness gate, and `proxy_workers` for mining liveness
    (`stratum.conns` can read 0 while mining).
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

- **Dashboard cards reordered by operator relevance** (#159, completing the #156→#159 chain). Cards
  rendered in the order they were added, so pool-wide and network-wide context (Global P2Pool Stats,
  XMR Network) sat *above and between* the things that matter for running *this* stack. The board now
  leads with the fleet at-a-glance — the hashrate **chart** and the **Workers** table go full-width up
  top (this stack may drive many machines) — then this stack's own detail cards (my P2Pool node, my
  XvB tier/VIP/routed, my earnings, my Tari), with **Global P2Pool Stats and XMR Network demoted to
  reference position at the bottom**. The Simple Overview's stats are likewise reordered to lead with
  the decision-relevant numbers (total hashrate, mode, workers, tier, VIP, shares) before the routed
  split and reference fields. "Mine" first, "the world" last — and a cleaner hero shot for launch.
- **Dashboard now shows *routed* hashrate everywhere for display, *credited* only where XvB's verdict
  matters** (#156). Two different XvB numbers were being conflated: **routed** = what the xmrig-proxy
  actually sent to a pool (`v_xvb`/`v_p2pool`, a common basis for both pools that sums to your total),
  and **credited** = what XvB's API reports back (`avg_1h`/`avg_24h`, XvB-only, on its own "credit
  factor" basis). The header, Simple Overview, and chart previously showed *credited* XvB next to
  *routed* P2Pool — two incomparable bases side by side. They now show **routed** for both pools
  (explicitly labelled "(routed)"), derived from `v_xvb` the same way P2Pool's averages already were
  (new `_avg_xvb_over_window`). **Credited** now appears in exactly two places: the swap-algorithm
  decision logic (unchanged — it must steer off credited per #9/#70) and the Advanced "XvB Donation
  Stats" card, where routed and credited 1h/24h are now juxtaposed so the live **credit factor** is
  visible. The Current Tier label stays credited-derived everywhere (the raffle assigns tiers off
  credited — an intentional exception). No schema change; reads sensibly (routed = 0) when XvB is off.
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

- **Dashboard "Current Tier" no longer overstates your XvB tier on a hashrate drop** (#157). The XvB
  raffle qualifies a tier on **both** the 1h and 24h credited average (and terminates a win if the 1h
  drops below the round minimum), but the dashboard resolved Current Tier from the 24h average alone.
  On a hashrate drop the 1h falls first while the laggy 24h still reads the old tier — so the dashboard
  showed a tier the miner had effectively already lost, exactly when an accurate signal matters most.
  Current Tier now reflects `min(1h, 24h)`; ramp-up (where 24h is the lower, conservative read) is
  unchanged. Display-only — the donation controller still steers off the credited 1h average (#9/#70).
- **Dashboard share-health panel no longer flickers to empty on a malformed proxy `/summary`** (#141).
  The pool-wide accepted/rejected/invalid/best totals are designed so a bad poll keeps the last-good
  value — but that only held when the fetch *raised*. A non-raising malformed body (a non-dict: `null`,
  a list, a string) parsed to `{}` and overwrote the last-good, blanking the panel. The parse now
  routes through `_merge_proxy_summary`, which keeps the prior totals unless the new parse is usable
  (a valid summary reporting genuine zeros is still adopted).
- **Dashboard "Stats fetched from xmrvsbeast.com (Updated: …)" timestamp now reflects the real fetch**
  (#136). It was bumped on *every* algo cycle because the controller writes `donation_fraction` each
  loop, even though the actual xmrvsbeast.com fetch only runs every 10th iteration — so the "Updated"
  time ticked fresh (~every 30s) even while the site was unreachable for hours, hiding stale data. The
  `last_update` timestamp now bumps only on a genuine fetch (when `avg_1h`/`avg_24h` arrive), not on
  the per-cycle local writes (`mode`, `donation_fraction`, `fail_count`).
- **HugePages header badge no longer reads red when reserved-but-not-yet-used** (#175). Right after
  boot, or while Monero syncs and the miner is held, HugePages are correctly allocated but `0` are in
  use yet — the badge showed **"Allocated (0 / N)" in red**, implying an error. The reserved-but-unused
  state now renders **green** (it's the normal startup state); red is reserved for the genuinely-bad
  `HugePages_Total == 0` ("Disabled") case. The "Unknown" (meminfo unreadable) state is unchanged.
- **Hashrate chart no longer reads blue-purple when mining 100% to P2Pool** (#184). The chart is a
  stacked area where each band draws a colored top border-line; when a series is flat-zero (XvB off,
  or P2Pool zero in XvB-only mode) its border was painted along the *other* series' edge — so an
  all-P2Pool window looked blue-purple, implying a split that wasn't there. Each band's border is now
  suppressed per-segment wherever the band has zero height, so a single-pool window reads as one solid
  color (the truthful picture) without having to manually hide the empty series.
- **"Workers Alive" table now tells the truth about offline workers** (#169 / #182). Two related
  bugs: (1) a disconnected worker's **Uptime kept climbing** — it was computed as seconds-since-last-share,
  so the longer a rig was down the bigger its "uptime" read (it was really *downtime*); offline rows
  now show **`DOWN`**. (2) Dead rows **never left** the table — it's titled "Workers Alive" but a rig
  that connected once (e.g. under a typo'd name) lingered forever. A new dashboard-side
  `WorkerLifecycle` tracks each worker's `connected_since` (giving online rigs a true,
  monotonically-increasing uptime even when their direct API is unreachable — replacing the
  misleading last-share estimate) and `last_active` (so an offline worker **falls off** after
  `WORKER_FALLOFF_SEC`, default 1h, operating on the live proxy list — not the dead `known_workers`
  path #144). A reconnect re-adds the worker and restarts its uptime. Raw `uptime` stays on the row
  for client-side column sorting.
- **A fully-synced monerod no longer shows as "loading" in the dashboard's Monero panel.** A synced
  node reports `target_height: 0` (no target), so the panel's `done` check — which compared
  `percent >= 100` against a target, and derived the state string from `has_target` first — never
  fired, leaving the *normal steady state* stuck at "loading" indefinitely (surfaced in the #180
  gouda validation; mining and worker-gating were unaffected — those use monerod's RPC flag
  directly). The sync state now trusts monerod's authoritative caught-up signal (`reachable &&
  not is_syncing`), and the live integration harness asserts the panel reads "done" — closing the
  test gap that let this escape both the unit suite and the e2e matrix.
- **Install no longer fails on hosts whose LAN already uses `172.28.0.0/24`** (#180). The Docker
  bridge subnet is now configurable via **`network.subnet`** (default `172.28.0.0/24`); set a free
  `X.Y.Z.0/24` and `pithead` rebases the whole stack onto it. Previously the hardcoded subnet/IPs
  made `docker compose up` fail outright with `Pool overlaps with other one on this address space`.
  The structured fixed-IP layout is preserved (services keep their `.25`–`.31` octets), so the
  host-networked dashboard's bridge addressing and the #122 worker-SSRF CIDR guard still hold — only
  the `/24` base moves. A single `NETWORK_PREFIX` flows through every config path: compose
  interpolation, monerod/Tor container `envsubst`/`sed` at start, and the Tari config render. And if
  a host *does* collide, `pithead up`/`apply` now catch Docker's overlap error and print the exact
  `network.subnet` fix (with an example) instead of a raw Docker stack trace.
- Dashboard now records **every** P2Pool share instead of at most one per 30 s poll: it tracks the
  cumulative `shares_found` counter and records the per-poll delta as N distinct shares. A
  higher-hashrate or nano-sidechain node finding 2+ shares within one poll window no longer
  undercounts the PPLNS window or skews the XvB controller's share gate (#129).
- Dashboard now surfaces broken persistence: a `db_healthy` field in `/api/state` and a loud
  "DB write failing" badge when the SQLite DB can't be initialized or written, instead of appearing
  healthy while silently losing history/shares/stats on the next restart (#131).
- `pithead up` and `pithead doctor` now warn when a data directory named in `.env` doesn't exist —
  the tell-tale of a relocated/copied install or a second checkout, which would otherwise silently
  start a fresh sync and orphan the dashboard history (data dirs are absolute paths in `.env`) (#126).
- `pithead upgrade` now re-renders the generated config (`.env`, Caddyfile, Tari config) before
  rebuilding, so a release that changes a config template, restructures the Caddyfile, or adds an
  `.env` var takes effect — `upgrade` was previously just `up --build`, running new images against
  the stale generated config from the last setup/apply (#128).
- `pithead apply` no longer silently strands the stack after a failed `docker compose up`: it leaves
  an "apply incomplete" marker so a re-run re-attempts the recreate (instead of no-opping on the
  already-committed `.env`) and prints explicit recovery guidance on failure (#125).
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
- Dashboard pruned/full label (#32) always showed **Full** for a local node: the dashboard parsed
  `MONERO_PRUNE` with `== "true"`, but pithead renders `config.json`'s `monero.prune` as `1`/`0`
  (the form monerod's CLI wants), so a correctly **pruned** node read as Full. The label is purely
  cosmetic (the node is pruned either way); the parser now accepts `1`/`true`/`yes`/`on`. Surfaced
  on a live pruned deployment whose badge read "XMR Full".

### Fixed

- Dashboard pruned/full label (#32) always showed **Full** on local nodes: the dashboard parsed
  `MONERO_PRUNE` with `== "true"`, but pithead writes it as `1`/`0`, so a pruned node read as
  Full. Now accepts `1`/`true`/`yes`/`on`. Found by the live integration harness on a real box.
- Dashboard DB upgrade path: opening a database created by an early (pre-`timestamp`) schema
  threw `no such column: timestamp` and aborted the migration, leaving the DB half-upgraded —
  `_create_tables` built the `idx_ts` index on a column `_migrate_db` hadn't added yet. Indexes
  are now created after migrations. Found by a new schema-migration intent test.

### Security

- Hardened the dashboard against an **SSRF** primitive (#122). A connecting miner fully controls its
  stratum worker name/IP, yet the `network_mode: host` dashboard fetched per-worker stats at a host
  taken *verbatim* from that input — so a miner could steer outbound GETs at `127.0.0.1`, the
  internal docker bridge (the socket proxies on `172.28.0.30/.31`), or a cloud-metadata IP. The
  worker probe now targets only a **validated real miner IP** (rejecting loopback, link-local,
  multicast, unspecified, reserved, and the `172.28.0.0/16` bridge), **never** uses the
  miner-controlled *name* as a request host, and caps the name before echoing it back as a Bearer
  token.
- The xmrig-proxy HTTP control API now **fails closed** on a missing token (#153). The API is
  writable (`--http-no-restricted`, required for XvB pool-switching) and reachable on the bridge +
  host, so it must always be authenticated. Compose now interpolates `--http-access-token` (and
  `--http-port`) with `:?`, so a hand-edited or pre-token stale `.env` with an empty
  `PROXY_AUTH_TOKEN` makes the stack **refuse to start** — instead of exposing an unauthenticated
  control API. pithead still auto-generates the token on `apply`; a `test_compose.sh` assertion
  guards both the token-present and empty-token paths.
- Closed clearnet DNS leaks in the node configs (#161, #162). **monerod** drops its priority-node
  HOSTNAMES (resolved by the local resolver *before* `--proxy`), disables DNS checkpoints
  (`disable-dns-checkpoints`, since removing `enforce-dns-checkpointing` alone doesn't stop the
  `checkpoints.moneropulse.*` lookups) and the update check (`check-updates=disabled`), and adds
  Tor-node anonymity hygiene (`pad-transactions`, `hide-my-port`). **Tari** disables DNS seeds
  (`dns_seeds = []`, bootstrapping from onion `peer_seeds` over Tor), prunes the clearnet
  `/ip4//ip6/` peer seeds, corrects a comment that implied DNS-over-TLS (it was plaintext UDP/53),
  and drops the inert `check_for_updates` gRPC method. The last clearnet DNS path — the Tari Pulse
  service's ~120 s `checkpoints.tari.com` TXT lookup (an advisory deep-reorg check with no in-binary
  off-switch) — is closed by pointing the container's resolver at a dead local address (`dns:
  127.0.0.1`); the lookup fails without a packet leaving the host and Tari tolerates it (returns
  "passed", verified in `tari_pulse_service`), so zero clearnet DNS and no functional impact. The
  container already overrode Docker's `127.0.0.11`, so no service discovery is broken. Trade-off:
  loses the Pulse deep-reorg advisory, the same class as monerod's `disable-dns-checkpoints`.
- The dashboard's XvB stats fetch (`xmrvsbeast.com`, with the wallet as a query param) now routes
  over **Tor** (`socks5h`, so the hostname resolves via Tor too) instead of clearnet from the
  host-networked container — closing a real-IP ↔ wallet correlation leak. It's also gated behind
  `XVB_ENABLED`, so disabling XvB stops the egress entirely. Dead `TARI_EXPLORER_URL` removed (#163).
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
