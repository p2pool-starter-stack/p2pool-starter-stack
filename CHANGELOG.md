# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/dev/releasing.md`](docs/dev/releasing.md).

## [1.19.2] - 2026-08-18

### Fixed

- **A release can no longer ship unsigned when no install would accept it
  ([#1108](https://github.com/p2pool-starter-stack/pithead/issues/1108),
  [#960](https://github.com/p2pool-starter-stack/pithead/issues/960)).** The release pipeline
  treated signing as optional while every install treats it as mandatory: once `cosign.pub` is
  committed it ships in every bundle, and the one-click upgrade refuses any release with no
  `pithead.tar.gz.sig`. A cut made on a box without the signing key therefore published a bundle
  the whole fleet rejects — and release assets are immutable, so the signature could never be
  attached afterwards. That is why v1.18.0 had to be withdrawn. The cut now aborts instead, naming
  what is missing; `--unsigned` publishes one deliberately. `COSIGN_PASSWORD` is checked too, which
  it never was — cosign would otherwise have prompted for it after the images were promoted.
- **A release rehearsal now reports the decision the real cut will make.** The signing check sat
  inside the dry-run guard, so `--dry-run` always printed "Release signing OFF" whatever the box was
  configured to do. The one check that exists to protect a cut could only ever report failure.
- **The pinned signature verifier is proven before a release is published
  ([#1084](https://github.com/p2pool-starter-stack/pithead/issues/1084)).** Every install verifies
  its images and its upgrade bundle by running one digest-pinned cosign container, and nothing
  validated that pin. A bad digest would have shipped a stack that cannot start, reported to
  operators as *signature verification failed* — tampering, rather than an image we could not fetch.
  The cut now signs a probe blob, verifies it through that container, and requires a tampered blob
  to be refused. The same round trip catches a `cosign.pub` that no longer matches the release key.
- **`pithead doctor` answers whether this box can take an upgrade, before one is attempted.** It
  reports whether the pinned verifier image is present and how to pre-fetch it, and says plainly
  that a source checkout cannot take the dashboard's one-click upgrade at all.
- **Caddy restarts whenever its rendered configuration changes
  ([#1052](https://github.com/p2pool-starter-stack/pithead/issues/1052)).** The restart was decided
  from a list of config keys, so any setting missing from that list re-rendered the Caddyfile and
  left the running Caddy on the old one. The decision is now a comparison of the rendered file.
- **`doctor` reports a control channel pointing at another install
  ([#1097](https://github.com/p2pool-starter-stack/pithead/issues/1097)).** A failed upgrade could
  leave the systemd control units aimed at a directory the stack no longer runs from, which silently
  disabled every dashboard action, and nothing reported it.
- **Operator messages point at published documentation rather than repository paths
  ([#1024](https://github.com/p2pool-starter-stack/pithead/issues/1024)).** Release bundles ship
  lean, so the `docs/dev/...` paths several refusals named did not exist on an operator's machine.

### Changed

- The self-hosted release gate no longer claims to gate `main`
  ([#1048](https://github.com/p2pool-starter-stack/pithead/issues/1048)). It recorded a skipped —
  and therefore green — run on every merge of a job that had never once executed, because no runner
  is registered. It is manual-dispatch only now, and `docs/dev/releasing.md` names in one table
  which gates are automated and which are run by hand.
- Release signing is documented as what it is: mandatory to publish, because it is mandatory to
  consume. The docs had described it as opt-in since before installs began failing closed.

### Upgrade note

Installs still on **v1.18.1 or v1.19.0** verify releases with a host `cosign` binary rather than the
container introduced in v1.19.1, and an upgrade runs the code the box is already on — so those
installs refuse the upgrade until cosign is installed once. Use the pinned **v2.6.3**, not the
newest: cosign v3 satisfies the check and then fails the verification. See
[Releasing › Upgrading an install older than v1.19.1](docs/dev/releasing.md#upgrading-an-install-older-than-v1191).

## [1.19.1] - 2026-08-17

### Fixed

- **The one-click upgrade no longer needs anything installed on the host
  ([#1072](https://github.com/p2pool-starter-stack/pithead/issues/1072)).** Release verification
  used to require the `cosign` binary, which has no Ubuntu package — so it was a prerequisite no
  prerequisites list mentioned and no dependency check installed. Because the first start gates on
  it too, a fresh install from the documented Quick Start dead-ended on any clean host, after the
  wizard had already collected the operator's wallet addresses; and every install predating signed
  releases hit the same wall on its first signed upgrade. The verifier now runs as a pinned
  container through Docker, which the stack already requires. Nothing to install, and the
  prerequisites are unchanged.
- **A failed upgrade can no longer disable the upgrade button
  ([#1070](https://github.com/p2pool-starter-stack/pithead/issues/1070)).** The control-runner
  systemd units were pointed at the new release's directory before that release was live, so an
  upgrade that aborted partway left them watching a directory the running dashboard never writes
  to. The control channel went quiet with no error anywhere, taking the one-click upgrade with it —
  the repair needed a shell on the host. The units are now updated only once the new version is
  actually live, so a failed upgrade leaves the working install untouched and still serving.
- **A slow upgrade is no longer reported as a failed one
  ([#1071](https://github.com/p2pool-starter-stack/pithead/issues/1071)).** The dashboard gave up
  waiting before the host had spent even its download budget, then blamed the control channel —
  which was working. Re-clicking then met the ten-minute throttle. The page now waits long enough
  for a slow connection and, if it does stop watching, says the host is still working rather than
  claiming the upgrade failed.
- **Container image scanning is green again
  ([#1073](https://github.com/p2pool-starter-stack/pithead/issues/1073)).** A util-linux
  vulnerability became fixable upstream and started failing the image gate on every branch at once.
  The base image is bumped and the finding accepted until the patched build reaches it, the way the
  other base-distro findings already are.

## [1.19.0] - 2026-08-16

### Added

- **Worker Inspect shows a per-rig hashrate chart, and config changes mark it (#1013/#1014/#1015).**
  The same range-selectable chart the fleet view uses (24 Hr / 1 Wk / All) now renders for a
  single rig, and every config apply or upgrade against that rig appears on it as a marker — a
  diamond for an apply, a triangle for an upgrade, coloured by outcome. A one-click rig upgrade
  now leaves a change-history row too: the immediate 202 response previously meant nothing ever
  recorded how the rebuild finished, whether or not the operator's tab stayed open to see it land.
- **Container healthchecks cover the five services that had none (#904).** xmrig-proxy, dashboard,
  Caddy, and the two Docker socket proxies used to report `Up` with no health signal, so a
  dead-inside container — the v1.8.1 incident, dashboard serving 502s behind an `Up` container —
  stayed invisible to `pithead status` and the container-health alert. Each new probe checks
  actual readiness, not just that the process exists, using only tooling its own image ships.
- **The XvB winners-feed archiver ships as an operator tool (#906).**
  `scripts/xvb-winners-archive.sh` snapshots the public winners feed daily (Tor-routed, atomic
  writes, about 90 KB/day) for recalibrating the measured delivery band over time. `operations.md`
  documents what it collects and a crontab line that points at a directory outside the
  version-numbered install path — a version-dir default would have lost every snapshot on the
  next upgrade.

### Fixed

- **The one-click upgrade refuses to run without cosign, key or no key (#1023).** The
  pre-download guard checked only the locally installed `cosign.pub`, missing the one case that
  needed it most: an install cut before release signing engaged, upgrading to a signed release.
  That combination hit production on the v1.18.1 upgrade — the guard passed, the bundle
  downloaded and extracted, and the abort landed inside the new CLI's image gate mid-upgrade,
  leaving the operator to finish from a shell. cosign is now a flat precondition, checked up
  front alongside the existing source-checkout refusal.
- **monerod restarts whenever tor restarts, and `doctor` catches it when that doesn't happen
  (#972).** A tor container restart or recreate kills every SOCKS connection monerod is using,
  and monerod doesn't notice on its own — bench runs saw a node sit at 0 peers for hours with
  every healthcheck still green. monerod now carries a tor dependency that restarts it whenever
  tor does (through `pithead up`, `apply`, `upgrade`, or `restart tor`), the auto-heal path
  cycles it directly, and `pithead doctor` gained a sync check that warns and names
  `restart monerod` as the fix for whatever still slips through.
- **Rig config applies and upgrades no longer get stuck reading "accepted" (#1001, #1009).**
  RigForge can end a rig operation in `noop`, `throttled`, or `failed`, not only the outcomes
  pithead already understood; the apply/upgrade poll and the enriched-feed reconciler that
  catches slower terminal outcomes both recognized just a subset. A rig that hit one of the
  missing outcomes burned its full poll window and then sat in the change-history table reading
  "accepted" forever. Both paths now recognize the full six-outcome vocabulary RigForge ships as
  of v1.15.0.
- **Dashboard text meets WCAG AA contrast in both themes (#939).** The palette's `--ok`/`--bad`/
  `--warn`/`--purple`/`--accent` tokens are fill shades, but the dashboard also used them as text
  colour — white-on-accent badges measured 2.53:1 on dark and status-tinted worker names 3.74:1,
  both under the AA threshold, with a hovered status-tinted row bottoming at 2.75:1. New
  `-emphasis` (fill under white text) and `-fg` (colour as text) tokens split the two roles per
  theme; hovered status-tinted rows drop the tint entirely, and the light theme's borderline
  muted/warn/accent text steps off the 4.5-5.0 range.
- **The XvB decision table stays visible when XvB is disabled (#938).** The per-tier odds,
  donation cost, and tempered-estimate table exists to help decide whether to turn XvB on, so
  hiding it behind the flag defeated the point. It still computes from local config and the
  cached public feeds with XvB off; only the live-donation surfaces (current tier, header split,
  hero KPIs) go quiet, since those need the raffle actually running.
- **A won XvB round is protected within minutes instead of up to half an hour (#892).** The
  in-round hold that stops a controller from spending down a round it just won only engages once
  the dashboard notices the win, and the fixed 30-minute sync gate left that window open long
  enough to actually end a whale-tier round live. The gate now tightens to 150 seconds whenever
  the credited average sits close to the tier threshold or a win landed in the last 90 minutes,
  cutting detection latency to about 5 minutes in that window while the normal-case sync rate is
  unchanged.
- **The energy tab's net profit and the XvB expected-reward table price XvB at measured
  delivery, not face value (#902).** Every other XvB money surface already tempers the published
  raffle bonus by what winners measurably receive; these two still used the raw figure and read
  roughly 3x high on a donating box. Both now follow the same precedence — a wallet's own
  measured realization once it has enough wins, otherwise the delivery study's midpoint.
- **Three dashboard display oddities are fixed (#992).** The expected-vs-actual percentage
  withholds the number past 999% and explains why in the row's tooltip, instead of printing a
  five-digit ratio for a box that was idle most of the window. The Tari per-block reward now
  shows whenever p2pool reports it, instead of disappearing behind the same hashrate gate as the
  what-if estimates derived from it. And the pool's last-block time reads as `<duration> ago`
  — "Never" before the pool's first block — instead of a bare timestamp with no date or timezone.

### Changed

- **The Tari disk budget is raised from 170 to 200 GiB (#1004).** The live reference deployment
  measured 149 GiB on 2026-08-15, continuing a linear ~6.6-6.8 GiB/month growth rate that had
  left the 170 GiB budget about three months of headroom. 200 GiB restores roughly eight months
  at the observed rate; the summed minimums setup preflight, `doctor`, and the docs quote move
  with it, to about 330 GB pruned / 530 GB full.
- **Documentation corrected against the code, remote-node story first (#1034).** `hardware.md`
  never mentioned `tari.mode: remote` and stated that remote-node mode still runs Tari, true only
  of the Monero half — a real gap, since Tari is the larger line item in the disk budget the code
  enforces. A wider sweep re-derived and corrected other stale claims across the doc set: a
  sizing example, the non-root service list, the control channel's action count, and the
  configured key count among them. A separate pass cleaned up a stale code comment, the repo's
  last unverified-upstream doc marker, and three unused image files (#989).
- **Test coverage and CI hardening.** The dashboard's frontend entry point is unit-tested for the
  first time, having previously run its side effects at import (#903). The live e2e matrix gained
  five rows — remote Tari, stratum TLS, the Tor-egress-firewall-off path, payout confirmation,
  and insecure mode paired with the main sidechain — plus rig-upgrade and writable-config legs
  (#942, #1002), and the harness itself is more honest: a pre-flight bench-sync check, a
  `--no-miner` flag that actually skips the mining-only assertions it claims to, and a
  post-restore proof that the running containers match the on-disk config, not just a passing
  healthcheck (#914, #905, #880, #971). The patch-coverage gate no longer passes vacuously on an
  untested changed file (#1000), the test-inventory drift check now runs on every PR (#981), and
  the frontend fixture-drift guard compares the full nested payload shape instead of only
  top-level keys (#974) — the fixture itself was regenerated to match what the server actually
  sends (#948).

## [1.18.1] - 2026-08-14

Supersedes 1.18.0, withdrawn before general adoption. Investigating its missing bundle signature
surfaced the real state: release signing (#376) had never engaged — the key pair was generated on
the release box but `cosign.pub` was never committed, so every release to date shipped its bundle
unsigned and no install holds a key to verify with. 1.18.1 draws the line: it commits
`cosign.pub`, carries every 1.18.0 change, and is the first release signed end to end. Installs
that upgrade to it come out holding the key and verify every release after; immutable release
assets mean 1.18.0 itself can never be amended, hence the new number.

## [1.18.0] - 2026-08-13 (withdrawn — unsigned install bundle; use 1.18.1)

### Added

- **The XvB calculator is a decision table with measured estimates (#900).** One row per tier:
  the odds of a win per day at your hashrate, the donation cost, what XvB's published bonus
  figure implies, and a study estimate that tempers the published figure by what winners
  measurably receive on-chain — 33% of face value (95% CI 28–39%), from a 25-round delivery
  study run against this stack's own wallet and the public winners feed. The yearly net shows
  as a band, and a tier is coloured profitable or unprofitable only when the whole band agrees.
  Once the dashboard has confirmed enough local wins, your own measured realization replaces
  the study band. The expected-vs-actual card's XvB expectation is tempered the same way.
- **The dashboard stands down XvB when it is disabled.** The hero raffle KPIs, the Overview
  tiles, and the stats panel disappear instead of showing dashes. When XvB is on, the win
  forecast follows the tier the donation actually targets, not only the tier already held.
- **The XvB delivery study ships in the repo
  ([docs/research/xvb-delivery-study](docs/research/xvb-delivery-study/PAPER.md)).** The full
  paper — methods, per-round data, figures, analysis scripts, and checksummed source archives —
  documents how the measured band was derived and how to reproduce it.

### Fixed

- **The donation cap holds during catch-up (#898).** After an under-tier hour, catch-up aimed
  at the tier target even when the configured donation cap could never reach it, so the
  algorithm donated at the cap ceiling indefinitely. Catch-up now aims at the achievable
  ceiling — the lesser of the tier target and the cap times stable hashrate — so a cap set
  below the tier target holds.
- **The e2e upgrade test seeds from the live release bundle (#880),** not the canonical
  checkout, so the pre-cut bench run exercises the same starting state an operator upgrades
  from.

### Changed

- **The repository is reorganized (#907).** The research record lives under `docs/research/`,
  root-level files are pruned or moved to their subject directories, and the dev docs got an
  accuracy pass — release branch mechanics, withdrawing a bad release, the operator-run
  pre-cut e2e gate, service and config-key counts.

### Dependencies

- Python (dashboard): diff-cover 10.5.0, hypothesis 6.165.2, ruff refresh. Docker: refreshed
  the pinned `ubuntu` base digest in the monero, p2pool, and xmrig-proxy images.

## [1.17.0] - 2026-08-02

### Added

- **Log navigation for the Security panels (#823).** The access log and the config-change audit
  trail share one control row: range presets (24 Hr / 1 Wk / 1 Mo / All, the chart's idiom) for
  following a live log, two date fields for jumping to a specific day or span, and a search box
  that matches any field and narrows as you type. Filters compose, and filtering happens on the
  server, so a match deeper than the on-screen tail is still found — the access log's read stays
  size-bounded either way. Below the row, a pager reports how many entries matched and walks
  them a page at a time — 5 to 100 rows per page with Prev/Next — replacing the audit trail's
  hour/day/month grouping dropdown, whose job the date controls now do better. A filter with no
  matches says so; the failed-login counter always describes the whole log.

### Dependencies

- Compose-pinned third-party images, now under Dependabot's watch: refreshed digests for the
  Tari console wallet (within v5.3.1-mainnet) and Caddy (within 2.11.4).

## [1.16.1] - 2026-08-01

### Fixed

- **The expected-vs-actual card no longer scrolls, and compares honestly (#817).** Every row now
  shares one trailing 30-day window, and Monero and XvB are one combined row on both sides: an
  XvB win pays out through ordinary payouts the payout table cannot attribute, so the confirmed
  actual always contains win XMR — the expectation now folds XvB's published tier estimate in
  (only when fresh, and never a negative one), so the percent compares like with like. The card's
  values wrap instead of panning, and every short dashboard card now hugs its content instead of
  stretching into a mostly-empty box beside a taller neighbour.
- **The Worker Inspect close button sits in the top-right corner (#817).** The panel header's
  layout class was never defined in the stylesheet, so the ✕ rendered beside the title instead.

## [1.16.0] - 2026-08-01

### Added

- **Expected vs actual earnings, at a glance and in both views (#808).** A new dashboard card
  puts each income stream's estimate beside what the view-only wallets actually confirmed, over
  the same window: Monero XMR over the trailing 7 days — expected from the 7-day average routed
  P2Pool hashrate, the hashrate that actually ran the window — with a percent-of-expected; Tari
  in blocks over 30 days (solo merge-mining pays whole blocks, and a fraction of a block per
  month is the normal expectation, shown as such); and XvB raffle wins in the window beside XvB's
  published estimate for the current tier. The card appears in the Simple view too — its first
  earnings figure. Streams without payout confirmation show the config key to set rather than a
  zero, and windows that outrun the recorded payout history keep their partial marking. No XvB
  XMR figure is shown anywhere: a win pays out through ordinary small payouts the payout table
  cannot attribute, so any such number would be an invention.

### Fixed

- **A local→remote node switch now retires the old node container (#795).** Switching
  `monero.mode` or `tari.mode` to `remote` dropped the node's compose profile as promised, but
  compose never removes the running container of a profile-disabled service — it is not an
  orphan — so the old node kept running, offline and re-syncing, against a remote-mode config.
  Every `up` now removes the containers of profile-disabled services before recreating anything,
  which also heals a box already stuck in that state on its next `apply` or `up`. On-disk chain
  data is untouched, exactly as the apply preview says.
- **The tari-wallet container can now actually report healthy (#777).** Its liveness probe
  grepped for the full `minotari_console_wallet` process name, but `ps` truncates the command
  column at 15 characters, so the check could never match and the container reported unhealthy
  forever — a permanently-firing container alert for the first user of Tari payout confirmation.
  The probe now matches the truncated form `ps` actually prints.

## [1.15.0] - 2026-08-01

### Added

- **Running confirmed earnings (#787).** The dashboard's Confirmed on-chain block and the Telegram
  `/earnings` reply now answer "what did I actually earn yesterday / this week / this month?" —
  running yesterday / 7d / 30d totals from the confirmed payouts the view-only wallets record
  (#381/#462), beside the existing estimate. Yesterday is the previous full calendar day in the
  dashboard's timezone, not a trailing 24 hours, so it matches the daily summary's clock — even
  across a DST change. A window that reaches back past the oldest recorded payout is marked
  partial, with a footnote naming where the recorded history starts, so a total summed over less
  than its labelled span never reads as a complete one. Both surfaces read one shared roll-up, so
  they cannot drift apart.

### Dependencies

- Dashboard Python group (#788): `aiohttp` 3.14.3, `grpcio` 1.83.0 (floors still satisfy the
  checked-in Tari gRPC stubs), plus test/dev tooling — `diff-cover` ≥ 10.4.1, `hypothesis`
  ≥ 6.163.0, `ruff` 0.16.0, `pre-commit` ≥ 4.6.1.

## [1.14.1] - 2026-07-24

### Fixed

- **Won XvB raffle rounds no longer terminate on the controller's own thin margin (#769).** XvB ends
  a won bonus round if your credited 1h average dips below the round minimum while the round runs.
  The donation controller held that average only ~1% above the whale threshold — inside the credited
  average's own measured noise — so rounds died mid-flight and paid a fraction of their value. Two
  guards: the cushion above the tier threshold widens to 5% (capped at 5 kH/s, so a whale-tier stack
  now deliberately donates a few kH/s more than before), and for 90 minutes after a recorded raffle
  win the controller refuses to ease the donation down. Safety behaviour is unchanged: the VIP
  reserve, stale-read hold, and prolonged-outage decay all still override the win-protection hold.

## [1.14.0] - 2026-07-23

### Added

- **Node LAN exposure switches (#760)** — the serving side of the remote-node modes. `monero.zmq_lan_access`
  publishes monerod's ZMQ feed on the LAN (with the existing `rpc_lan_access`, everything a remote
  P2Pool needs), and `tari.grpc_lan_access` publishes the bundled Tari base node's gRPC, so one
  stack's synced nodes can serve other stacks running `monero.mode`/`tari.mode: remote` (#103).
  Both default off, publish loopback-only otherwise, and flipping either to the LAN is a
  host-confirmed destructive change. The Tari gRPC and ZMQ feeds carry no authentication —
  trusted networks only (see the remote-node sections in `docs/configuration.md`).
  **Upgrading:** monerod's `18083` and the Tari node's `18142` are now published on the host from
  this release — on loopback unless you turn a switch on. If something else on the host already
  holds either port (a hand-rolled `socat` forward serving another machine is the likely one, since
  that is what these switches replace), free it first: Docker refuses to start the container on a
  taken port, and the upgrade stops there.
- **Remote Tari node (#103).** `tari.mode: remote` merge-mines against a Tari base node running
  elsewhere instead of the bundled one: set `tari.remote.host` (required) and
  `tari.remote.grpc_port` (default `18142`). Remote mode skips the bundled `tari` container, its
  memory cap, and payout confirmation. The remote node's mining-template
  RPC is request-scoped, so one node can serve several pithead stacks at once, each with its own
  wallet — a shared node for a fleet or household is the intended pattern. The gRPC link stays
  plaintext and unauthenticated (p2pool has no way to speak TLS or auth to it), so use a node you
  trust: its operator, or anyone on the network path, can silently redirect Tari rewards. Monero
  mining is unaffected either way. LAN/trusted-network only for now — a `.onion` remote is a
  follow-up. See [Configuration › Remote Tari node](docs/configuration.md#remote-tari-node).
- Dual-distribution plan (#77/#78): the architecture decision record for shipping Pithead as a
  curl-installed Compose stack, a flashable immutable appliance (Debian 13 + Rugix A/B, Podman
  Quadlet), and a git clone — one release manifest across all three. Dev doc only, no behaviour
  change. See [`docs/dev/dual-distribution-plan.md`](docs/dev/dual-distribution-plan.md).

### Changed

- Operator-facing text no longer carries this project's internal issue numbers (#755). A message
  you read in the terminal or the dashboard is now written for you, not for the tracker; the
  numbers stay in the source comments, where they explain *why* the code is the way it is. A lint
  guard (`make lint`) keeps them out from here on.
- `upgrade`'s help text describes what it actually does — re-render generated config, then rebuild
  and restart — for both source checkouts and extracted release bundles, instead of naming only
  `git pull` (#757).

### Fixed

- **No onion for a node that isn't here (#103).** With `monero.mode` or `tari.mode: remote`, Tor
  kept publishing that node's inbound hidden service even though the container never starts, so the
  stack advertised an onion address that accepted connections into nothing. Each node's hidden
  service is now published only while that node runs locally; P2Pool's is unchanged, since p2pool
  always runs. Switching a node back to `local` republishes it at the same address — the key never
  left `tor.data_dir` — and a stack first set up in remote mode mints the address on the apply that
  makes the node local.
- Config validation closes two gaps a dashboard-committed config could otherwise walk into: a
  `data_dir` containing `:` is rejected (it would forge a third field in the container's volume
  mount and could silently turn a data mount read-only), and a `tari.wallet_address` containing
  whitespace is rejected instead of mining to a wrong address. A remote node's host and ports are
  validated once, at parse time, and reused verbatim by the renderer — the value that passes
  validation is the value that ships.

## [1.13.0] - 2026-07-22

### Added

- Mine cart train (#748): a pixel-art strip under the hero band retelling the chart window as
  cargo — one cart per interval, token coins for what landed (orange ɱ per share interval, a
  pair for a found block, a purple gem per confirmed Tari payout, a blue X per XvB raffle win),
  with a tipple, a sleeping cat, and drifting clouds. Static under reduced motion. `/api/state`
  gains a `payouts` key: confirmed payouts per chain as `{x, amount}` timeline points, gated on
  the payout-confirmation flags.

### Changed

- Earnings calculator standardized (#748): every tab presents its estimate in one
  Day / Month / Year table with a shared-precision coin column and a `≈` fiat column once the
  price is known. Tari gains month/year spans, XvB gains the published current-tier reward
  table, Energy gains Revenue (est.) / Power Cost / Net columns. Net figures carry the one
  judgment colour — green in profit, red in loss.
- Dashboard panel round (#748): stat-heavy cards open collapsed to their headline stats with a
  "Show all" toggle, the Advanced grid gains Your Stack / The Wider Pool section labels, the
  workers table gains tabular numerics + row hover with offline-red scoped to the rig name,
  chart active chips move from green to accent, and the topology diagram gains zone tints and
  marching-ants on live routes.

## [1.12.0] - 2026-07-22

### Added

- **Configurable Caddy host port (#740).** Caddy binds the host's 80/443 by default; on a machine
  already running another reverse proxy (Nginx Proxy Manager, Traefik, a separate Caddy) those
  ports are taken and the stack fails to start. `dashboard.port` moves the LAN vhost off them —
  `"auto"` (default) keeps the scheme's standard port (443 with `dashboard.secure`, 80 without);
  a number (e.g. `8443`) binds that instead, so an existing proxy keeps 80/443 and fronts the
  stack. In HTTPS mode a custom port also drops Caddy's automatic HTTP→HTTPS redirect (which would
  otherwise hold port 80), leaving that to the fronting proxy. Caddy stays in the path, so the
  `dashboard.auth` login is unaffected. Split from the co-hosting umbrella (#181). See
  [Configuration › Co-hosting on a shared server](docs/configuration.md#co-hosting-on-a-shared-server).
- **Confirmed payouts on the dashboard** (#381). The on-chain payout totals the stack already
  scans for now surface in the earnings card: a **Confirmed on-chain** block under the Monero
  estimate shows 24-hour, 7-day, and all-time XMR plus the time since the last payout (and the same
  in XTM on the Tari tab). Each confirmed Monero payout also drops a green **Payouts** coin marker
  onto the hashrate chart at the block time it landed, and — when XvB is on — a dashed **XvB
  donation %** overlay on a right-side 0–100% axis lets you line payouts up against how much
  hashrate you were donating. Both are legend-toggleable like the other chart series.

### Changed

- **Docs: the remote-node ZMQ requirement is called out at the migration decision point** (#181).
  "Reusing an existing node → Option B — Connect to a remote node" now states up front that a
  remote node must expose ZMQ (and have its RPC reachable), so a general-purpose public "open node"
  won't work — the constraint that was previously only documented one section further down.

## [1.11.0] - 2026-07-21

### Added

- **Confirm-gated config editing for operationally-disruptive settings** (#719). The dashboard
  config editor can now commit a small set of disruptive-but-recoverable settings behind a
  type-to-confirm, instead of refusing them outright: the four service data directories (a move
  re-syncs), the stratum port (rigs must repoint), the Monero/Tari clearnet initial-sync toggles
  (the host IP is exposed during IBD, then auto-reverts to Tor), and enabling Monero pruning. Each
  renders editable with a "you'll type `APPLY` to confirm" affordance; the typed confirmation rides
  to the host approval gate, which requires it before the change proceeds and records the apply in
  the control audit log as a distinct `commit-confirmed` action.

### Changed

- **The control-channel security perimeter stays host-only** (#719). Type-to-confirm is UX
  friction, not a security control — a compromised dashboard that can set a field can also fill the
  confirm box — so the perimeter is unchanged: wallets and view keys, the dashboard login and onion
  settings, the control channel itself, the Tor egress firewall, the stratum password, node
  endpoints and credentials, and the per-rig hosts and tokens all remain refused from the dashboard,
  as does the heavier direction of a confirm-gated key (disabling pruning forces a full re-sync).
- **Dashboard-confirmed data-directory moves are allowlisted to the stack's data root** (#728).
  #719 made the four `*_DATA_DIR` moves confirmable from the dashboard behind a typed `APPLY`, but
  the destination was still checked only by the host-side blocklist (`assert_safe_dir`), which
  passes any non-catastrophic absolute path. A confirmed move from the dashboard is now further
  held to an allowlist: the new location must sit under the stack's own data root (the install
  dir's `data/`) or a parent the stack already keeps data in, else the move is refused even with
  the typed confirmation and stays host-CLI only. The host `./pithead apply` path keeps the wider
  blocklist — a shell operator already has filesystem-wide reach; only the dashboard-reachable move
  is tightened, closing the destination trust-escalation the confirm-gate opened.
- **Opt-in local miner** (#593). A box that runs the stack 24/7 can mine with its spare CPU by
  co-locating a RigForge worker on the stack host. `./pithead setup` now asks "Also mine on this
  machine with its spare CPU?" (off by default; also the new `local_miner.enabled` config flag),
  and setup/apply print the two values a RigForge install needs — the stack's own stratum URL
  (loopback `127.0.0.1:3333`, or the configured `p2pool.stratum_bind`/`stratum_port`) and the
  stratum secret already in `.env`. The co-located worker self-registers through the proxy like any
  other rig. Pithead only declares the intent and hands off those values; RigForge owns all
  host-level tuning (HugePages, GRUB, MSR, governor) and the miner service. See
  [docs/workers.md](docs/workers.md#mine-on-the-stack-host-itself).
- **Warm XvB donation state on a backup stack (#249).** On a two-host failover pair — same wallet,
  workers listing both hosts in `pools[]` — the backup's XvB donation controller used to cold-start
  when the fleet failed over to it: the closed-loop split restarted from the feedforward estimate
  and re-ramped for hours, over- or under-shooting the credited tier until it reconverged. The
  controller's commanded donation fraction is now persisted, so a plain restart resumes the warmed
  split instead of re-seeding cold. A backup can also point `xvb.standby.source` at the primary
  dashboard's new read-only `/api/xvb-standby` endpoint; it periodically pulls the primary's
  controller state and holds it as standby (inspectable in `/api/state`), then adopts it the first
  time it actually donates at failover — so the split resumes warm. One-way (backup pulls from
  primary), inert unless configured, and never acted on while the primary is authoritative (an idle
  backup has no workers, so its controller stays on P2Pool). The pull follows the dashboard's
  privacy-safe egress rule: an `.onion` source, a public IP, or any hostname rides the bridge Tor
  SOCKS (the primary sees a Tor exit, never the backup's IP); only a provably-private/loopback IP
  literal dials direct as a LAN hop — so the pull never opens a clearnet path, and the Security
  panel reports its route.
- **Opt-in fail-closed miner hold on an unrecoverable dashboard health failure** (#490). New
  `dashboard.fail_closed` toggle, default **off**. The dashboard is an observability layer, not the
  mining datapath (`xmrig-proxy` → `p2pool` → `monerod` runs independently of it), so by default an
  unhealthy condition only alerts (Telegram/Healthchecks/webhook) and shows a badge while mining
  continues. Set it `true` and a genuinely unrecoverable failure — the SQLite database failing to
  rebuild after its own auto-heal attempt (disk full, permissions), or the `dashboard` container
  itself crash-looping past the #337 debounce — holds `p2pool` and `xmrig-proxy` using the same
  #35 sync-gate stop/start mechanism, with a `Miner held (fail-closed)` badge. Unlike the sync
  gate's one-way latch it re-checks every cycle and releases on its own once the condition clears.
  A transient write blip, a slow query, or a single failed external fetch never trips it — those
  still only alert. Gated by the #33 control-approval path like other `dashboard.*` toggles.
- **`/api/state` exposure for three of the #196 telemetry-backbone series (Tier-1).** The backbone
  PR (#600) added five persisted SQLite tables with capture, storage, and retention, but shipped
  without surfacing them to the client. This slice exposes three — `blocks` (pool block-found
  events), `disk_growth` (hourly monerod-DB-size + host-disk-usage samples), and `xvb_history`
  (~5-min XvB-credited scalar samples) — as range-filtered arrays under those same keys, bounded
  at the existing 700-point chart cap for the two higher-cadence series. `network_history` and
  `worker_history` are a separate (Tier-2) slice, not touched here. No chart renders any of these
  series yet — that's a further follow-up.

### Security

- **The out-of-band audit trail is now flood-capped per worker (#724).** The `rig-edit` audit
  source (#530) reads a worker's reported change id off the unauthenticated LAN worker feed. The
  #530 deterministic row id collapses *repeats* of one change id to a single row, but not *distinct*
  ones — so a malicious or compromised device presenting as a worker could report a fresh random
  change id every poll, writing a new permanent `audit_events` row each ~30s cycle and slowly
  filling the dashboard database (the table has no pruning). New `rig-edit` rows are now capped per
  worker per rolling hour; beyond the cap the extra rows are dropped behind a single `rate-limited`
  marker row and a logged warning, so the flood stays visible instead of growing the table without
  limit. A genuine occasional rig change still records normally, and the non-attacker-controllable
  `host-edit` and mirrored `control.log` rows are unaffected.

## [1.10.2] - 2026-07-21

### Fixed

- **The payout wallet no longer reports the whole stack unhealthy during its first scan (#718).**
  With the genesis-scan default, `wallet-rpc`'s initial full-chain scan takes hours, and
  monero-wallet-rpc doesn't answer its RPC while scanning — so the healthcheck flipped `unhealthy`
  and could fire stack-health alerts for the entire scan, even though the wallet was working. The
  healthcheck now tolerates an unreachable RPC while a first-scan marker is present (armed on wallet
  creation, cleared the first time the RPC answers), so it stays healthy through the initial scan
  and turns strict once caught up.
- **Control-gate refusal messages no longer cite a closed, unrelated issue (#713).** The
  "security-sensitive setting" and "destructive change" refusals pointed operators at #338 (a
  closed Telegram-control issue) for "out-of-band approval"; they now just name the real path —
  edit `config.json` on the host and run `./pithead apply`.

## [1.10.1] - 2026-07-21

### Fixed

- **The view-only payout wallet builds again (#714).** Setting `monero.view_key` starts a
  view-only `wallet-rpc` that confirms p2pool payouts actually land, but it crash-looped on first
  run — the create-from-keys JSON set an empty `"spendkey": ""`, which monero-wallet-rpc parses as
  a secret key and rejects. The field is now omitted (the view-only form), so the wallet creates
  and scans. A correct view key was never the problem; the entrypoint was.

### Changed

- **The payout wallet now scans the full chain by default.** The view-only payout-confirmation
  wallet's default restore height (`monero.payout_scan_height: auto`) is genesis (0) instead of the
  chain tip, so it captures **every** p2pool payout this address has ever received, not only those
  after it was set up. The initial scan is long but one-time — the wallet persists its progress.
  Set an explicit block number to start later and skip it. Its memory ceiling is raised to 2 GiB
  (from 512 MiB) so the one-time full scan, which peaks above 0.5 GiB, doesn't OOM-loop.
- **Net profit now includes the XvB raffle's expected reward (#712).** The Energy tab's net figure
  adds the current XvB tier's published expected reward, valued at your XMR price, on top of P2Pool
  (and Tari, when priced). The whole net is already probabilistic, so it stays a single number — the
  XvB slice is labelled `(est.)` in the heading and tooltip because the raffle draw is random among
  qualifiers. It folds in only while the fetched estimate is fresh (the same staleness rule as the
  *XvB Donation Stats* card) and you clear a donor tier; otherwise it is left out, never guessed.

## [1.10.0] - 2026-07-20

### Added

- **One-click remote worker upgrade** (#597). Where the per-worker badge shows and the rig is
  editable, Worker Inspect gains an Upgrade rig… button: arm, confirm, and the rig installs the
  latest RigForge release itself (rig ≥ v1.11.2 with its default-off `control_upgrade` flag chain
  enabled). The intent carries the worker name and confirmed version only; the host runner
  re-derives the real target from the RigForge release API over Tor (throttled, cached), resolves
  the rig's address and bearer from `config.json`, dials over the LAN, and polls the rig to a
  terminal applied / rolled-back / failed with a hard cap. Already-current rigs no-op without
  dialing; a rig-side throttle refusal reads as retry-later. Per-rig only — no "upgrade all".

- **Per-worker RigForge "new version available" badge** (#596). A rig whose reported RigForge
  version is older than the latest published release gets a clickable badge in the Workers Alive
  table and in Worker Inspect, linking to the release notes — the worker-level twin of the
  header's stack-release badge. Notify-only; one hourly, Tor-routed, fail-silent fetch covers the
  whole fleet, gated on the same `dashboard.check_for_updates` flag. Rigs that report no version
  (plain xmrig, sister API off) show no badge — unknown, not "up to date".

### Fixed

- **Removing the control runner no longer strands a sibling checkout's stack (#689).** The
  `pithead-control.{path,service}` unit names are global to the host, but a bench box holds
  several checkouts at once — and a checkout applying with dashboard control off (or the e2e
  harness tearing down) removed whatever units were installed, including the live stack's,
  leaving its config editor stuck at "Previewing…" until the next apply. Both removal paths now
  check the service unit's `ExecStart` and only touch units owned by the acting checkout,
  comparing physical paths so the `current` symlink and the versioned directory it targets
  count as the same checkout.

- **An unedited Save & preview shows zero changes (#695, #696).** On a bundle-deployed box the
  Review changes modal reported two changes with nothing edited. First, a path "change" such as
  `CLEARNET_STATE_DIR: /srv/code/current/... → /srv/code/pithead-vX.Y.Z/...`: pithead resolved
  its own directory with a logical `pwd`, so `.env` paths derived from the checkout dir took the
  spelling of whoever invoked it — the deploy symlink interactively, the physical dir under the
  control runner's systemd unit — and the same directory diffed against itself. The script now
  canonicalizes with `pwd -P`, and `CLEARNET_STATE_DIR` joins its siblings (`CONTROL_DIR`,
  `CADDY_LOG_DIR`) as a silent internal path in the change preview. Second, a permanent
  "Energy calculator settings updated" row on any box whose `config.json` never set
  `dashboard.energy`: the editor round-trips the reference-merged form, so the staged copy
  carries the materialized energy defaults, and the preview compared them against the absent
  block. The comparison — in the preview row and the commit's audit-key derivation alike — now
  merges the reference defaults into both sides, so only a real value change raises the row.

- **The egress panel no longer reports a phantom clearnet leak for the XvB stats fetch (#701).**
  With `xvb.tor: false`, the #170 posture panel and topology view showed the dashboard's XvB
  stats connection as a clearnet leak. That fetch is unconditionally routed over Tor (`socks5h`,
  #163) — `xvb.tor` gates only the xmrig-proxy donation dial (#166) — so the panel warned about
  a leak that cannot happen. The dashboard's XvB stats route is now Tor whenever XvB is enabled,
  matching what the code actually does and what `docs/privacy.md` already documented.

- **The egress panel and network map now list the webhook/ntfy alert sinks (#380).** Both views
  derived every dashboard egress except the alert sinks, so a `notifications.tor: false` sink
  POSTing to a public endpoint — a real clearnet leak from the host-networked dashboard, which the
  egress firewall cannot cover — went uncounted. The new "alert sinks (webhook / ntfy)" entry is
  Tor when configured (the default), a counted clearnet leak when Tor is off and any endpoint is
  public, and **local** — the LAN carve-out, not a leak — only when every configured endpoint is a
  private or loopback IP literal, since a hostname cannot be proven private without a DNS lookup.

### Changed

- **The release process requires the targeted end-to-end run.** `docs/dev/releasing.md` now
  states that the borrowed-rig `e2e.sh --mode targeted` pass on the release candidate is a
  required pre-release gate — `release.sh`'s `--readiness` assessment alone is not enough — and
  documents the post-deploy `--check` sweep and its expected parked-bench baseline. Private
  bench hostnames in docs, comments, and one harness message are replaced with generic role
  names; each box's specifics live in its own `~/README.md`, not the repo.

### Security

- **The dashboard's external API fetches are size-capped** (#660). The GitHub release check, the
  CoinGecko price feed, and the XvB client's calls (stats, reward estimates, winners, register)
  now stream their responses through a shared `bounded_get` helper that cuts the body at 1 MiB,
  so a hostile or broken endpoint can no longer make these clients buffer an unbounded payload.
  Over-cap reads follow each client's existing failure contract (no result / keep the last good
  one). The remaining external GETs — the Tor egress probe, the Healthchecks ping, and the
  Telegram `getUpdates` long-poll — ride the same cap; `getUpdates` also caps its batch at 10
  updates so a capped batch can never wedge the poll loop on an offset it cannot advance.

## [1.9.3] - 2026-07-19

### Fixed

- **Keyboard users can sort the Workers table (#671).** Each sort header's click target is now a
  real `<button>` (the #657 pattern), so it is focusable and activates on Enter/Space. The
  worker-history table also stops advertising a pointer cursor on headers that do nothing.
- **The configuration reference says how to make an edit take effect (#675).** The callout above
  the key table now states that editing `config.json` changes nothing until `./pithead apply`,
  for readers who deep-link into the table and never see the intro.
- **Config editor saves work again (#679).** Every save through the dashboard's Configuration
  editor — Form and JSON mode alike — was rejected with the "sets both workers.list[] and
  dashboard.workers[]" error: the editor merges `config.reference.json` (which ships both worker
  keys as empty-array defaults) under the operator's config and round-trips the merged document,
  and validation refused on key presence. The refusal now keys on populated lists; an empty array
  beside the populated key is the schema default and passes. The editor's own
  `_core_keys`/`_editable_keys` metadata is likewise stripped from the intent before it reaches
  the host gate.

### Changed

- **The disk readout switches to TB at 1 TB (#677).** The system card and the Telegram `/system`
  reply format disk used/total through one shared helper: GB with one decimal below 1024 GB
  (unchanged), both values scaled to TB together at or above it — `Disk: 0.4 / 3.6 TB` instead
  of `Disk: 408.6 / 3666.4 GB`. RAM, stored telemetry, and the metrics endpoint stay GB.
- **`apply` migrates the deprecated `dashboard.workers[]` to `workers.list[]` (#679).** A
  validated legacy list is moved in place on the next apply: entries land under `workers.list`,
  the old key is deleted, and the pre-migration file is kept beside the config as
  `config.json.bak-workers`. Dry runs (including every dashboard preview) never write.

## [1.9.2] - 2026-07-19

### Added

- **Event and raffle markers join the chart legend (#652).** The hashrate chart's legend now
  toggles every layer, not just the three series: the degradation/recovery diamonds (#99) and
  the XvB raffle-win stars (#644) each get a show/hide button, persisted across reloads like
  the rest.

### Fixed

- **Overview docs match the rendered card (#659).** The doc's field table follows the actual
  #159 stat order, names the two wallet cards (Wallet XMR / Wallet TARI) instead of a single
  "Wallets" row, and the stat card's label casing unifies on "Share in Window" to match the
  hero KPI and the doc.
- **UI preferences now all survive a reload (#658).** The Workers-table sort, earnings tab,
  Form/JSON and Table/JSON editor modes, and the topology mesh toggle join the already-persisted
  theme, view, averaging window and series toggles. A saved choice that becomes invalid (a
  removed column, an unavailable tab) falls back to the default.
- **Every toggle control now announces itself like the theme switcher (#657).** The chart
  Range row becomes real buttons in a labelled group (it was bare links), and the view
  toggle, Form/JSON and Table/JSON editors, and the topology mesh button gain
  `aria-pressed` and hover titles. The button resets move into `.btn-range`, which also
  gives the Avg buttons the pointer cursor they were missing.
- **The Workers table shows its sort state (#656).** The sorted column now carries a direction
  arrow and `aria-sort`, and every header names its action on hover — before, clicking sorted
  the rows with no indication of which column or direction was active.
- **The chart's default full-history range gets an "All" button (#655).** Before, no range
  button read as selected on first load, and once a preset was clicked the full-history view
  was unreachable without hand-editing the URL.
- **The header no longer advertises the release you are already running (#664).** Right after an
  upgrade, the "New release vX.Y.Z available" badge and the Upgrade button could linger while the
  version badge already showed vX.Y.Z — the pre-upgrade check result was restored from the
  persisted snapshot and nothing was obligated to clear it promptly. Two fixes: derived update
  state is no longer restored across a restart (the checker recomputes it), and the render seam
  now suppresses the badge whenever the advertised release is not strictly newer than the running
  one — the contradictory state is unrepresentable, whatever produces it. Clicking the stale
  button was always refused host-side; this was display-truth damage only.

### Changed

- **Developer docs moved to `docs/dev/` (#669).** `STYLE.md`, the testing docs, and the
  release/server docs now live under `docs/dev/`; `docs/` keeps the operator guides. Old
  in-repo links are updated; bookmarks to the old paths need a refresh.

## [1.9.1] - 2026-07-19

### Added

- **Opt-in live XMR/XTM price feed for the energy calculator (#651 — the auto half #520
  deferred).** `dashboard.energy.price_feed` (default off) fetches both spot prices from
  CoinGecko in your configured currency — always over Tor, same route as every other stack
  egress; no clearnet branch exists. The earnings card states which price it is using (live
  with age, or static from config.json — the static numbers stay the fallback), and the
  Monero/Tari/XvB tabs gain fiat mirrors of their coin figures. The new egress appears in the
  egress-posture panel, the Stack Topology, and the privacy table. Hardened against a hostile
  price response (non-finite values rejected) and a crafted currency label (plainly alphabetic
  or no request leaves the host).

## [1.9.0] - 2026-07-18

**Stratum link security.** v1.9 locks the last cleartext link — miner ↔ stack
stratum. New installs ship with the stratum access-password on (#208), and
`p2pool.stratum_tls` serves TLS on the same stratum port with per-rig
fingerprint pinning (#261), so a mixed fleet migrates one rig at a time.
Around the theme: the one-click upgrade now keeps the versioned deploy
layout honest and preserves the rollback bundle (#629), and Tor's
steady-state CPU cost drops via healthcheck and peer-count tuning (#595).

### Added

- **One-click upgrade names its restore point (#637).** Before an in-place upgrade overwrites
  the running install, the runner copies `config.json` and the rendered `.env` to timestamped
  `.bak-upgrade-*` siblings — and refuses to proceed if it cannot; a failure during the
  upgrade names those copies in the result and the dashboard modal. On the versioned layout
  the result (and the "Upgraded" modal) names the previous version dir — the rollback copy
  #629 already kept but never pointed at. The copies are written symlink-safely (mktemp +
  rename, the #629 co-tenant threat model) and pruned to the newest three pairs.

- **XvB raffle wins on the chart and in a log (#644).** The dashboard reads XvB's public winners
  log (over Tor, about every 30 minutes) and records every round your wallet won. Wins show as
  gold stars on the hashrate chart (hover for the round type and credited hashrate), as a
  **Raffle Wins** list in the XvB Donation Stats card, and each new win is announced once in the
  dashboard log. Win history outlives the ~4-day window the winners file itself keeps — it is
  kept effectively forever (bounded only far beyond any real win history, since the file is
  remote content the stack does not control). Each new win also fires a Telegram/webhook alert (`raffle_win` event, on by
  default like the rest; opt out via `telegram.events.raffle_win: false`).
- **Stratum authentication is on by default for new installs (#208, #152 Phase 2).** The setup
  wizard and `config.minimal.json` now write `p2pool.stratum_password: "auto"` into every new
  `config.json`: the stack generates a stable secret, prints it after `setup`/`apply`, and
  RigForge's setup prompts for it — a fresh stack plus fresh rigs authenticate end-to-end with
  no manual edits. Existing installs are untouched: the key is written explicitly for new
  configs, never assumed for old ones, so an upgrade flips nothing and a fleet on the open
  `:3333` keeps mining. Set the key to `""` (or delete it) to run unauthenticated.
- **Stratum-over-TLS (#261).** `p2pool.stratum_tls: true` serves TLS on the same stratum port —
  xmrig-proxy detects TLS vs plain per connection, so a mixed fleet migrates one rig at a time
  with nothing re-pointed. The stack generates a self-signed certificate once (under the data
  root, so its fingerprint survives upgrades) and prints the SHA-256 fingerprint each rig pins
  (`pools[].tls-fingerprint` — XMRig does no CA validation for stratum, so the pin is the trust
  model; the RigForge side shipped in rigforge#21/#115). Default off; confidentiality only —
  the #152 access-password stays the access control; use both.

### Fixed

- **Configuration form: sections that mix top-level keys label rows with the full dotted path
  (#640).** "Wallets & payout" showed two rows both named `view_key`; they are
  `monero.view_key` and `tari.view_key` and now say so. Single-key sections keep their short
  labels.
- **One-click upgrade keeps the versioned deploy layout honest (#629).** On the documented
  layout (`pithead-vX.Y.Z` dirs beside a shared data root), the dashboard upgrade used to
  extract the new release *over* the running install: the dir name and `current ->` symlink
  kept the old version string while holding the new release, and the previous bundle — the
  rollback copy — was destroyed. It now extracts into a fresh `pithead-v<new>/` sibling,
  seeds `config.json`, `.env`, and the control spool, runs the new dir's `pithead upgrade`,
  and repoints `current ->` on success, leaving the previous dir intact for rollback — the
  same steps as a manual bundle deploy. Installs whose data directories resolve inside the
  install dir still upgrade in place (a dir swap would strand the data) and say so in the
  journal.
- **`make test` now runs the frontend logic suite (#632).** The `node --test` frontend tests
  ran only in CI; a local `make test` could pass with a frontend regression. Local and CI now
  run the same chain.

### Documentation

- **The one-time false "HTTP 502 — did not complete" when upgrading from ≤ v1.7.x is
  documented (#631).** The #622 fix rides in the release being installed, so the upgrade that
  delivers it still polls with the old, unfixed client. The dashboard guide now says how to
  confirm the upgrade landed (version badge, cleared release banner) and that the modal is a
  one-time artifact.

## [1.8.1] - 2026-07-18

### Fixed

- **One-click upgrade no longer shows a false "HTTP 502 — did not complete" on a
  successful upgrade (#622).** The self-upgrade recreates the dashboard container
  itself; while it restarts, caddy (the reverse proxy) stays up and answers
  502/503/504 because the upstream is briefly gone. The result poller already rode
  out a dropped connection but treated a gateway 5xx as terminal, so the modal
  jumped to "failed" even though the upgrade landed. Gateway 502/503/504 are now
  ridden out like a dropped connection; the durable control result is the real
  outcome. A genuine backend 500 still fast-fails.

## [1.8.0] - 2026-07-17

**Config UX round 2.** The Configuration view is regrouped around logical
sections (not one-per-service), the telegram/ntfy event toggles collapse into
nested groups, and fields the control gate can't commit — pruning, data
directories, secrets — are greyed out with a host-only note instead of failing
at commit. The energy calculator's net profit now folds in Tari revenue, not
just P2Pool XMR. Alongside the features, a coverage push added the failover and
privacy behaviors that were previously real-hardware-only: a fake monerod in
the CI mini-stack (monerod-down/busy/double-outage failover, Tari-optional
keeps mining), and tier-4 fault-injection for Tor-down, cosign verification,
clock drift, and ENOSPC — which surfaced and fixed a real gap where `doctor`
reported all-clear while the Tor privacy backbone was down.

### Added

- **Energy calculator: Tari revenue in net profit (#520).** `dashboard.energy.tari_price` (fiat
  price of 1 XTM, default `0`/off) folds the estimated Tari merge-mining revenue into the Energy
  tab's net profit once it's set alongside the existing `xmr_price` — previously net profit counted
  P2Pool XMR only, undercounting a Tari merge-miner's actual revenue. Uses the same what-if Tari/day
  estimate the Tari tab already shows, no new estimate invented. XvB stays excluded (raffle status,
  not a clean per-day income estimate). The card's heading and Net/day tooltip now say exactly
  what's counted ("P2Pool + Tari, after power" vs "P2Pool XMR only, after power") so the figure is
  never silently partial. Static, operator-supplied price only — an opt-in Tor-routed price feed is
  a deferred follow-up, not implemented here (fetching one is a clearnet egress this privacy-first
  stack avoids).

### Changed

- **Configuration view: logical section grouping, nested event groups, host-only grey-out
  (#611/#612/#613).** The form no longer groups fields one section per top-level `config.json`
  key — a display-layer map now groups them the way an operator thinks about them (Wallets &
  payout, Monero node, Mining, Workers, Dashboard & access, Notifications, Energy, Alerts &
  thresholds, System / advanced), so a grab-bag key like `dashboard` splits across the sections
  its fields actually belong to; a path no group claims still renders, in a catch-all **Other**
  group, and a frontend test fails if any `config.reference.json` path would ever land there
  unclaimed (#611). Within Notifications, the 26 `telegram.events` toggles, the ntfy/webhook
  sinks, and Healthchecks each nest one level deeper into their own collapsed sub-group instead of
  dominating the section (#612). And a field the control-channel gate wouldn't actually commit —
  derived from the SAME allowlist the gate enforces, surfaced to the browser as `_editable_keys` on
  `GET /api/config` — now renders disabled with a "Host-only" tooltip up front, instead of letting
  it be edited and rejected only at Save; a drift-guard test keeps the surfaced set in lockstep
  with the gate's real allowlist (#613). `config.json` itself is unchanged; the staged-preview →
  closed-schema gate → commit pipeline is unaffected. JSON mode (which edits the whole config as
  text) is unaffected by any of this.

## [1.7.0] - 2026-07-17

The **Config UX & telemetry** cycle. Config editing becomes humane — worker
configuration unifies under `workers.list[]`, the Configuration view regroups
around a core shortlist with a JSON mode, Worker Inspect gets structured
editors, and the first-run wizard slims to the essentials with `mini` as the
default sidechain. Telemetry stops being discarded — a five-table time-series
backbone persists blocks, XvB, network, disk-growth, and per-worker history,
with per-config-version hashrate correlation in Worker Inspect. Every new
surface is exercised end-to-end (the `workers.list` real-rig path and the
telemetry schema are asserted at tier 4) and the docs were passed for
cross-consistency before the cut.

### Added

- **Worker Inspect: hashrate correlated to config version (#492).** The per-worker change
  timeline (#185) now carries the measured hashrate (`worker_history`, #196) each version ran
  at: a sample is attributed to the most recent *applied* config change at or before its
  timestamp, then averaged/min/max'd per version, so an operator can compare "config #3 did
  5.1 kH/s, config #4 did 4.8 kH/s" empirically instead of guessing. Correlation happens in
  Python (`StateManager.get_worker_hashrate_by_config`) against the existing tables — no new
  schema, no rig-side change needed. Surfaced as a new table in the Worker Inspect panel,
  alongside the existing change-history table.

- **Worker Inspect: a table editor and a JSON mode for the writable-config edit path (#518).**
  The raw JSON textarea is now the fallback of two modes: **Table** (the default) renders one row
  per writable key (`pools`, `DONATION`, `autotune`, `watchdog`, `watchdog_interval_min`,
  `max_temp_c`), typed off the value the dashboard last applied, and records only the rows you
  touch; **JSON** keeps the old paste-a-whole-object flow, with a **Load from file** button
  (`FileReader`, no upload) to fill it from a local config for pushing one profile to several
  rigs, and an inline error the moment the JSON stops parsing instead of only on Apply. Both modes
  submit the same `{worker, changes}` request through the existing `/api/control/worker-apply`
  path — the writable allowlist is still the only thing that decides what's accepted, at every
  layer. A masked value (the `{__secret__: true}` sentinel the Configuration view already uses)
  renders as a blank password field in table mode, never as JSON to mangle, and round-trips
  untouched in JSON mode unless you edit it yourself.

- **`config.core-keys.json` (#502/#529).** A committed list of the config-key shortlist only the
  operator can answer — wallet addresses, `monero.mode`, `p2pool.pool`, dashboard auth + host,
  `workers.list` — the single shared artifact between the first-run wizard and the dashboard's
  future core form section (#529). A tier-1 test pins every path in it to an entry in
  `config.reference.json`.

- **Time-series persistence backbone for five telemetry series (#196).** Five dedicated,
  independently-retained SQLite tables — `blocks` (pool block-found events, permanent),
  `xvb_history` (XvB scalars, ~5 min wall-clock, 30-day retention), `network_history` (Monero
  difficulty/height/reward + pool hashrate, hourly, 90-day retention), `disk_growth` (monerod DB
  size + host disk usage, hourly, permanent), and `worker_history` (per-rig hashrate + share
  counts, ~5 min wall-clock batched write, 30-day retention). Additive tables (no new columns on
  the existing `history` table, no row multiplication), each with a per-table "last successful
  write" health signal so a silently-failing capture hook is visible. Backbone only — capture,
  storage, retention, and a getter per series; charts/UI and `/api/state` exposure are deliberate
  follow-ups.

- **The Configuration view regroups around core-vs-sections, plus a JSON edit mode (#529, RATIFIED
  Wave-0 decision).** **Form** (the default) now pins a **Core** group at the top — the SAME
  `config.core-keys.json` shortlist the first-run wizard reads, surfaced to the browser as
  `_core_keys` on `GET /api/config` (one shared artifact, not a hand-maintained duplicate) — above
  the rest of the schema, regrouped into its natural top-level sections and collapsed by default
  (native `<details>`), so a typical edit shows a handful of fields instead of all ~94. **JSON**
  sits beside it: the whole fetched config as one editable text block, with a **Load from file**
  fill button (`FileReader`, no upload) — mirroring #518's Worker Inspect editor shape exactly,
  down to reusing its `jsonSyntaxError` helper. Both modes build the identical staged config object
  and submit it through the unchanged preview → confirm → commit pipeline; the host-side
  closed-schema gate is still the only validation authority; neither mode opens a path the other
  lacks. A masked secret (`{__secret__: true}`) still renders as a blank password field in Form
  mode and round-trips untouched in JSON mode unless you edit it yourself.

### Changed

- **The first-run wizard now asks a pool tier and a few shape questions, instead of hardcoding
  `p2pool.pool: "main"` (#502).** `./pithead setup` asks two short stages: required answers (wallet
  addresses, local/remote Monero node, pool tier, an optional dashboard login) and a few
  Enter-through "how should this run" questions (clearnet initial sync, remote dashboard access
  over Tor, Telegram alerts). Everything else keeps its `config.reference.json` default silently;
  the wizard prints a pointer to `config.json` and the docs at the end.

- **The default P2Pool sidechain is now `mini`, not `main` (#502).** `mini` has a lower share
  difficulty, so a typical home rig — the common case for this stack — finds shares far more often
  (smoother, more frequent PPLNS payouts). The default is now consistent everywhere: the wizard
  Enter-through, `config.reference.json`, and the code fallback (`.p2pool.pool // "mini"`) all
  agree. Raise it to `main` for a large farm. **Existing installs:** a config that explicitly sets
  `p2pool.pool` is unaffected; one that OMITS the key (relying on the old `main` default) moves to
  the `mini` sidechain on its next `apply`/`upgrade` — set `p2pool.pool: "main"` to stay on main.

- **Per-worker descriptors moved to `workers.list[]`, out from under `dashboard.*` (#506).** The
  per-rig `{name, host, port, control_port, token, watts}` entries lived at `dashboard.workers[]`
  (#172), split from the rest of the fleet's worker-API settings under the top-level `workers.*`
  block. They're now one block: `workers.list[]`. `dashboard.workers[]` is read as a deprecated
  fallback when `workers.list` is unset — a config carrying both is refused at apply — and is
  removed in v1.9.

- **Worker Inspect is a native `<dialog>` (#518).** The hand-rolled overlay `<div>` is now
  `showModal()` + `::backdrop`, which gets Escape-to-close and focus handling from the browser —
  the manual click-outside JS is gone, replaced by one `close()` call the dialog's own `close`
  event already funnels through.

### Testing

- **The tier-4 RigForge control leg now drives `workers.list[]` by default (#506/#513/#514/#516/#517).**
  The real-rig descriptor injection, and every read/assert site that resolves it, moved to the
  primary shape; a box whose baseline still carries the deprecated `dashboard.workers[]` fallback
  is left as-is rather than force-migrated, so that shape stays exercised on real hardware too, at
  no extra cost, through the v1.9 removal window.

- **A tier-4 `--check` assertion for the #196 telemetry backbone.** After an upgrade, asserts the
  five additive SQLite tables (`blocks`, `xvb_history`, `network_history`, `disk_growth`,
  `worker_history`) exist in the live dashboard's database — proof the migration ran against a
  real, already-populated DB. Row presence isn't asserted; the capture-hook writes are already
  covered at tier 1.

- **A tier-1 wizard case for the un-auth'd remote branch + the `nano` pool tier (#502).** Neither
  case arm was reached by the existing piped-answers tests: declining remote-node auth (leaving
  the RPC credentials empty rather than auto-generated) and picking the `nano` sidechain.

### Fixed

- **A rig rollback slower than the host runner's 20s status-poll deadline never reached a terminal
  state in the #185 worker-config history (#579).** The runner honestly records `accepted`
  ("queued; outcome not yet observed") when its poll lapses before a slow auto-rollback
  (rigforge#236) finishes — observed taking 2-3 minutes on the bench — and nothing revisited that
  row afterward, even though the rig itself did reach a terminal outcome. The dashboard's regular
  per-rig read poll now reconciles it: when a RigForge rig mirrors a terminal outcome
  (`applied`/`rejected`/`rolled_back`) for a `change_id` into its enriched feed, any history row
  still `accepted` for that `change_id` is updated to match. Rides the existing poll — no new
  network dial, no host-runner change, and the 20s synchronous deadline is unchanged. A row already
  terminal is never overwritten by a stale or duplicate report.

## [1.6.3] - 2026-07-17

The v1.7 plan's Wave 0.5 — the remaining seven findings from the 2026-07 scan (#556–#561, #566),
shipped early as a patch so the fixes reach live boxes before the longer config-UX cycle lands —
plus the applied cuts from a whole-repo over-engineering audit.

### Fixed

- **`apply --dry-run` no longer writes to `config.json` (#556).** A dry run that saw empty or
  placeholder local-node RPC credentials still called `persist_node_credentials`, which generated
  and saved a fresh password — breaking the documented read-only contract and, over the control
  channel, dirtying the host-side staged copy the commit gate re-validates. `persist_node_credentials`
  now skips the write while in dry-run mode; the generated credentials are still used in memory so
  the preview stays accurate, and a real `apply` persists them exactly as before.

- **Four friendly-error branches were unreachable under `errexit` (#557).** A plain
  `var="$(cmd)"` assignment aborts the script before the crafted diagnostic on the next line can
  run. Fixed in `verify_release_images` (the "#451 not digest-pinned" abort), both digest reads in
  `scripts/release.sh` (`stage_push` and the `--resume-promote` recovery path — the fourth site,
  found in review), and `reset-dashboard`'s final `compose_up_checked` call (the #180
  subnet-collision explanation). The new tests deliberately keep `errexit` ON — the suite's usual
  `set +e` harness was masking exactly this bug class.

- **`dashboard.host` length bound (#558).** Charset validation has existed since #130; the check
  now also caps the value at 253 characters (a DNS name's maximum), matching the worker-host guard.

- **"Last update" reports the snapshot's real age (#559).** After a restart the dashboard serves
  the restored snapshot until the first collection cycle; `/api/state` stamped it with the current
  time, so hours-old workers and hashrate read as fresh. It now uses the snapshot's own timestamp.

- **A rejected Healthchecks ping no longer counts as sent (#560).** Any HTTP response — including
  a 404 from a revoked or typo'd ping URL — advanced the throttle silently. Only 2xx counts now;
  a rejection logs one WARNING on the transition (and an INFO on recovery) instead of spamming.

- **Bash completion works when pithead is invoked from `$PATH` (#566).** The service lookup
  resolved `docker-compose.yml` relative to the literal command word; a bare-name invocation from
  an unrelated directory completed nothing. The real script path is now resolved (symlinks
  followed, bounded), with the old behavior as the silent fallback.

### Changed

- Applied the cuts from a whole-repo over-engineering audit: two dead CSS rules removed and a
  duplicated `ATOMIC_PER_XMR` constant now imported from its one home. The bash surface and the
  Python package audited clean.

### Testing

- Guard against drift between pithead's config.json reads and config.reference.json: a tier-1 test
  extracts every path pithead reads (config_bool/`jq ... "$CONFIG_FILE"` sites) and asserts each has
  a reference entry, failing loud on a read shape it doesn't recognize instead of skipping it (#561).

## [1.6.2] - 2026-07-17

The ten v1.6-milestone findings from the 2026-07 full-repo scan (#546–#555): two high-severity
bugs, five hardening fixes on the backup/upgrade/config paths, two documentation corrections, and
the regression test for the bug that withdrew 1.6.0.

### Fixed

- **The dashboard's HTTPS onion vhost now appears on the run that captures the address (#546).**
  Enabling the onion via `apply` rendered the Caddyfile while the address was still `placeholder`;
  the capture that runs after `docker compose up` only refreshed `.env`, so the `https://<onion>`
  vhost (#360) never appeared until some unrelated later config change. `rotate-dashboard-onion`
  restarted Caddy without regenerating the Caddyfile at all, so it kept serving the retired onion's
  vhost with none for the new address. Enabling via `upgrade` had the same hole as `apply` (#355's
  supported path). All three paths now regenerate the Caddyfile (and restart Caddy) the moment the
  address is captured.

- **A stats-file read race can no longer replay the whole share counter as fresh PPLNS shares
  (#547).** P2Pool rewrites its stats files in place; a poll that caught one mid-write read as
  `{}`, which the dashboard took for a counter reset — the next good poll then recorded the entire
  cumulative `shares_found` (hundreds of shares on a long-lived node) as new, inflating PPLNS
  weight, luck, and the XvB inputs, and could fire a false payout alert. The same race blanked
  `pplns_window` to 0, flapping the "no PPLNS share" alert and forcing a real pool switch. The
  collector now serves the last good parse per stats file (the pattern #141 already used for proxy
  totals), and `pplns_window` is only reported when the source actually carries it.

- **A bundle without `pithead/VERSION` fails the one-click upgrade cleanly instead of killing the
  control runner (#548).** The version read ran as a plain assignment under `errexit`, so a corrupt
  or foreign archive killed the runner mid-request: the result stayed `running` forever, the claim
  file leaked, and the rest of the queue was abandoned. The read is now guarded into the existing
  failure path, and the hourly sweep also clears orphaned claim files.

- **`restore` verifies plaintext archives before extracting (#549).** Only encrypted backups got
  the full-stream integrity check; a truncated plaintext archive aborted `tar` mid-extraction with
  the live `config.json`/`.env`/onion keys half-overwritten — during disaster recovery. Both
  formats now refuse a corrupt archive before anything on disk is touched.

- **A failed backup restarts the stack and removes the partial archive (#551).** Both the
  encrypted and plaintext branches stopped a running stack for the copy but only restarted it
  after success — a disk-full cron backup left the miner down until a human noticed, and the
  plaintext branch also left a partial root-owned archive that looked like a valid backup.

- **`setup` and `reset-dashboard` work for operators whose uid isn't 1000 (#550).** Both chowned
  the data tree to the container uid and then ran an unprivileged `mkdir` inside it — EACCES for
  any other operator uid, and in `reset-dashboard` the abort landed after the data wipe. Directories
  are now created before the chown, matching `ensure_directories`.

- **The apply preview no longer misreports payout-confirm toggles as a Monero node switch (#552).**
  `COMPOSE_PROFILES` also carries the payout-confirmation profiles (#381/#462); the preview keyed
  on empty-vs-non-empty, so setting a view key warned "Switching to a LOCAL Monero node — monerod
  will SYNC the blockchain" on the destructive-confirm prompt. The node-switch text (and its
  destructive flag) now keys on the `local_node` token itself.

### Documentation

- **SECURITY.md states the real release-integrity posture (#553).** It claimed releases are
  cosign-signed and verified before upgrade; signing is opt-in (#376) and no release has shipped
  signed — digest-pinned images and the TLS-fetched bundle are the protections today, and `pithead`
  warns rather than blocks when `cosign.pub` is absent. The policy now says exactly that.

- **Small accuracy fixes (#554).** `docs/monitoring.md` told operators to run `./pithead stop`
  (the command is `down`); `docs/dev/releasing.md` claimed `VERSION` is `1.0.3`; a compose comment
  called the dashboard a Flask app (it is aiohttp).

### Testing

- **The tier-1 fake upgrade bundle now reproduces the bug that withdrew 1.6.0 (#555).** The
  fixture ships `build/*` members mirroring the real bundle and pre-seeds the sandbox install with
  non-empty `build/*` dirs, so a regression of the #544 two-pass extraction fails `make test`
  instead of the release smoke.

## [1.6.1] - 2026-07-16

Supersedes 1.6.0, which was withdrawn before general adoption: the #459 post-publish smoke caught
the #59 one-click-upgrade bug (the release bundle failed to extract over an existing install), and
its published artifacts were removed. 1.6.1 carries every 1.6.0 change plus the fix below.

### Added

- **Commit `dashboard.energy` from the config editor (#504).** The energy calculator's settings
  (`cost_per_kwh`, `currency`, `xmr_price`) are now editable from the dashboard and applied through
  the #33 control channel, replacing the host-only note added in #519. The approval gate allowlists
  this one `config.json`-only block; any other `config.json` change it does not own is still refused,
  so the exemption cannot carry a wallet, endpoint, or credential edit.

- **Worker Inspect: enriched rig stats as a label/value table (#507).** The single-rig detail view
  renders RigForge's governor, HugePages, mainboard, power/efficiency, tuning, and temperature as a
  scannable label→value table instead of a badge row. The compact worker list keeps its badges; both
  are built from one server-side pass so they cannot drift.

### Changed

- **Expanded test coverage.** CI-tier: the whole editable-allowlist commit round-trip, the
  `telegram.control` fail-closed paths, and previously-unasserted config validators and effects
  (#521, #522, #523). Live-bench (tier-4): the dashboard↔RigForge control write-paths against a real
  rig, and a non-default `network.subnet` deployment (#513, #514, #516, #517, #201). Release: a
  post-publish smoke test that runs a real cosign verify and a real one-click upgrade against the
  published bundle (#459).

### Fixed

- **Charts no longer hijack page scroll (#533).** Scrolling the page with the cursor over a chart
  zoomed the chart instead of scrolling. Wheel-zoom is now gated behind Ctrl (a trackpad pinch still
  zooms); a bare scroll passes through to the page.

- **One-click upgrade no longer aborts on an existing install (#59).** The dashboard upgrade
  extracted the release bundle in place with a single unlink-first `tar` pass, which failed on the
  install's non-empty `build/*` config-template dirs (`Cannot unlink: Directory not empty`) and left
  the install half-written. It now extracts in two passes — merge the tree, then replace only the
  running `pithead` script on a fresh inode — so an upgrade over any prior install completes.

### Security

- **The config-apply gate now enforces a closed schema (#33 hardening).** The dashboard control
  channel's approval gate rejects any staged `config.json` key outside the schema, in addition to its
  existing per-key allowlist — defense in depth so a config edit committed through the dashboard can
  only touch known keys, never introduce new ones. No operator action required.

## [1.5.3] - 2026-07-14

### Fixed

- **Config editor: a clear note for host-only blocks instead of a silent "no changes" (#519).**
  Editing `dashboard.energy` — read straight from `config.json` and never rendered to `.env` — made
  the editor report "No configuration changes detected" and disable Apply, a silent no-op that looked
  broken. The preview now surfaces a non-committable note that the block is applied on the host.
  (Committing `dashboard.energy` from the dashboard is tracked separately in #504.)
- **Configuration tab spacing (#505).** Fixed the run-together "setdashboard.control.enabled" in the
  disabled-editing hint, and added a gap between the Configuration editor and the Access-log panel.

### Testing

- Guard against drift in the worker writable-key allowlist across its pithead-repo copies (#515).

## [1.5.2] - 2026-07-14

### Fixed

- **Enriched per-rig stats work again when `dashboard.workers[]` is populated (regression from 1.5.1).**
  1.5.1's #508 fix kept a worker descriptor whose token is the masked `{"__secret__": true}` sentinel;
  the read-probe auth then stringified that dict into the `Authorization: Bearer` header, so every
  enriched-feed probe returned HTTP 401 and per-rig stats disappeared. The probe now uses a per-worker
  token only when it's a real string, falling through to the fleet auth mode (e.g. `name`) for the
  masked sentinel — the host-side runner still uses the real token for the control path.

## [1.5.1] - 2026-07-14

### Fixed

- **Worker Inspect edit path now activates for configured rigs (#508).** The dashboard reads a masked
  copy of `config.json` (the container never holds real tokens, #440), where a rig's `token` is the
  sentinel `{"__secret__": true}`. The worker-endpoint loader required a string token and dropped the
  entry whole, so every worker showed as non-editable even with `dashboard.workers[]` set correctly.
  The loader now accepts the masked sentinel as "token present"; the host-side runner still supplies
  the real token when it dials the rig.

## [1.5.0] - 2026-07-13

### Added

- **Worker Inspect: view and edit a rig's config from the dashboard (#185).** Click a worker's name in
  the Workers Alive table (with the control channel on) to open a panel showing the rig's live
  telemetry, an editor for the writable slice of its config (`pools`, `DONATION`, `autotune`,
  `watchdog`, `watchdog_interval_min`, `max_temp_c`), and the change history. Applying a change goes
  through RigForge's writable control API (rigforge#236) — the rig validates it, applies it, and rolls
  back automatically if the miner doesn't return to a live hashrate; the panel shows the outcome
  (applied / rejected / rolled back) and records every change to a per-worker history you can browse.
  **Security:** the write path is fail-closed — it only exists when `dashboard.control.enabled` is on
  (which requires a dashboard password), every request carries the CSRF header, and the change surface
  is the writable allowlist only. The dashboard container **never holds the rig's token**: it spools
  the worker name plus the change, and the host-side control runner resolves the rig's address and
  bearer from `config.json` and dials the rig — so a compromised container can neither read the token
  nor point the write at an arbitrary host (the [#122 SSRF](docs/workers.md) rule). Each rig needs
  `host`, `token`, and (if not the default `8082`) `control_port` in its `dashboard.workers[]`
  descriptor to be editable. RigForge keeps no config history on the rig, so Pithead owns it; the
  rig's enriched feed doesn't expose the writable values, so the editor prefills from the last config
  the dashboard applied. See [Dashboard › Worker Inspect](docs/dashboard.md#worker-inspect).

- **Contract test for the RigForge worker API ↔ dashboard seam (#209).** A tier-2 contract test
  points the real `XMRigWorkerClient` at a controllable fake RigForge worker API over a real socket
  and asserts the whole `none`/`name`/`token` auth matrix (the #315 model), a wrong-token 401, and
  that the enriched `/1/summary` (rigforge#99 shape) parses through the real consumer — so a drift in
  either the auth handshake or the enriched-feed shape goes red in CI instead of only on a live rig.
  `docs/dev/testing-strategy.md` gains a per-flow tier map for the two-repo contract; the real-mining and
  real-proxy accept/reject legs stay tier-4 (documented, run on a bench rig).

- **Energy & profit calculator on the dashboard (#260).** The Advanced-view earnings card gains an
  **Energy** tab that totals fleet power draw and efficiency, and — once you set a price — the net
  profit after power. It sums each worker's watts from RigForge's enriched feed (#235); a worker
  whose feed reports no RAPL watts (macOS, a non-RigForge rig, an older kit) can carry a manual
  estimate via a `watts` field on its `dashboard.workers[]` descriptor, marked *estimated*, and a
  worker with neither is excluded so the total reads as a lower bound rather than a fabricated zero.
  The tab shows fleet watts, H/s-per-watt, and kWh per day/month/year always; set
  `dashboard.energy.cost_per_kwh` to add the energy **cost**, and `dashboard.energy.xmr_price` to add
  **net profit** (`net = P2Pool XMR earnings × your XMR price − power cost`), each in your
  `dashboard.energy.currency` label. No price feed ships — fetching one is a clearnet egress this
  stack avoids — so both prices are operator-supplied; leave either unset and that layer stays
  hidden. Net profit is P2Pool XMR only: Tari is lumpy solo merge-mining (priced separately) and XvB
  is raffle status, not income, so both are excluded, as the earnings card already frames them. See
  [Dashboard › Energy & profit](docs/dashboard.md#energy--profit).

- **Read RigForge's enriched worker feed on the dashboard (#235).** A RigForge rig serves an
  enriched read API on port `8081` — the same `/1/summary` the dashboard already polls, plus a
  `rigforge` block with the rig's version, tuning state, power draw and efficiency, CPU/firmware
  health, and watchdog temperatures. Point that rig's `dashboard.workers[]` descriptor `port` at the
  feed and the Workers Alive table gains a RigForge version badge and health/power/tune/watchdog
  chips next to the rig — throttling and a non-performance governor read red or amber, the rest are
  muted read-outs. Because the feed is a strict superset, uptime and per-miner hashrate still come
  from the same response, and a plain-xmrig rig (no `rigforge` block) reads exactly as before: no
  chips, no error. A rig whose RigForge is up but whose miner has stopped stays in the table with a
  **miner down** chip instead of dropping to offline. Every enriched field is nullable, so a rig with
  no RAPL shows no power chip and a disabled watchdog shows no temperature. The [#122 SSRF
  guard](docs/workers.md) is unchanged — the dashboard still polls only the operator-set descriptor
  host/port, never a miner-advertised value. See [Connecting
  Miners](docs/workers.md#rigforge-enriched-feed).

- **Confirm Tari payouts on-chain, too (#462).** The Tari sibling of #381, for the other half of
  the merge-mine. Tari merge-mining here is solo — the whole block reward lands at once when your
  hashrate finds a Tari block — so a payout is a rare, large event worth ground-truth confirmation.
  Set `tari.view_key` and `tari.spend_public_key` (exported from your Tari wallet) and the stack runs
  a view-only `minotari_console_wallet` against your **local** Tari node; the Tari tab of the
  earnings card gains a **Confirmed** total (24h / 7d / all-time XTM) beside the time-to-block
  estimate, and the shared `payout_confirmed` alert fires once per Tari payout (it carries the
  chain). Confirmed payouts persist to the same local table as the Monero side, so a restart never
  re-alerts; the restore point is a **birthday** (`tari.payout_scan_birthday`, days since the Unix
  epoch), not a block height, so a fresh wallet doesn't rescan from genesis. **Security:** the Tari
  view key is handled exactly like `monero.view_key` (scan-only, never spend; owner-only `.env`;
  never logged, echoed, on a container command line, or in the dashboard editor), with one extra
  safeguard — because Tari has no key-import file, the wallet secrets reach the container through a
  tmpfs secret mount, so they never appear in `docker inspect`. Off by default (empty view key =
  nothing new runs); **local Tari node only.** See
  [Dashboard › Payout confirmation](docs/dashboard.md#payout-confirmation).

- **Confirm payouts on-chain with a view-only wallet (#381).** Every earnings figure the dashboard
  shows is an *estimate*; nothing checked that a P2Pool payout actually landed in your wallet.
  Now, when you set `monero.view_key` (the private **view** key for your payout address), the stack
  runs a view-only `monero-wallet-rpc` against your **local** node and confirms payouts from the
  chain — the coinbase outputs P2Pool pays you are the only ground truth. The earnings card gains a
  **Confirmed** total (24h / 7d / all-time XMR) beside the estimate, and a new `payout_confirmed`
  alert fires once per payout across every sink (Telegram, webhook, ntfy). It polls on a slow
  cadence and records each payout locally, so a restart never re-alerts; coinbase outputs are
  recorded when confirmed in a block, not when they mature 60 blocks later; a pruned node works
  fine. **Security:** a view key can scan but never spend, yet it reveals every incoming amount and
  its timing — so it's handled exactly like `node_password` (owner-only `.env`, never logged or
  echoed, off the dashboard config editor, never on a container command line). The wallet-rpc runs
  non-root with a read-only root filesystem, is published only to the host loopback
  (`127.0.0.1:18082`), and is password-authenticated. Off by default (empty view key = nothing new
  runs); **local node only** — a view key set with `monero.mode: remote` is refused. See
  [Dashboard › Payout confirmation](docs/dashboard.md#payout-confirmation).

- **Telegram control commands: `/restart` and `/apply` (#338).** The Telegram bot, until now
  strictly read-only, can accept two commands that act on the host: `/restart` recreates the stack
  and `/apply` re-applies the current on-disk config. Off by default (`telegram.control.enabled`)
  and gated as a remotely-reachable control surface: honoured only from the numeric Telegram **user
  ids** in `telegram.control.allowed_ids` (being in the chat, or knowing the bot token, is not
  enough), and each command needs an explicit in-chat **confirmation** (an inline button) from the
  same operator within `confirm_timeout` seconds — an unconfirmed command is **denied**, never
  queued. The two verbs are the whole action set (no arbitrary execution), and they ride the same
  host-control spool the config editor uses (#33) rather than a new privileged path: the root runner
  validates and runs the fixed verb and audits the actor (`tg-<user-id>`) and outcome. Requires
  `dashboard.control` (the spool + runner) and the read-only command bot; a config-*changing* apply
  stays in the dashboard editor behind its default-deny allowlist. See
  [Telegram › Control commands](docs/telegram.md#control-commands).

- **Configurable stratum port & per-worker endpoints (#172).** `p2pool.stratum_port` (default
  `3333`) sets the port the stratum endpoint your rigs connect to is published on — thread through
  the `xmrig-proxy` bind, the compose publish, the `:PORT` healthcheck, and the "point your rigs
  at host:PORT" hint. The default preserves today's behaviour; changing it repoints every rig
  (RigForge: `pool.port`) and `apply` flags it destructive. P2Pool's container-internal stratum
  stays fixed at `3333`. New `dashboard.workers[]` — a list of `{name, host?, port?, token?}` —
  overrides the worker-API probe per rig when one differs from the fleet defaults: per-worker
  field > fleet default (`workers.api_port`/`api_auth`/`api_token`) > inherit. Entries match by
  stratum name, then by connecting IP against an operator-set `host` (first-declared wins on
  duplicate names); a per-worker `token` forces token-auth for that rig only. The `host` must be
  operator-set in `config.json` and is never taken from a miner-advertised value — the dashboard
  never sends a configured token to a miner-controlled host (SSRF guard, #122). The standard path
  (3333 / 8080 / token = rig name) needs no config. Pairs with rigforge#21 (`pool.port`) and
  rigforge#23 (`api.port`). See [Connecting Miners](docs/workers.md).

- **Alert sinks beyond Telegram: generic JSON webhook + ntfy (#380).** Every alert the stack
  produces — node down/recovered, worker offline/joined/left, sync, disk, DB, XvB, clearnet
  exposure, blocks and payouts, the daily digest — can now also be pushed to a **generic JSON
  webhook** (one POST per alert with `event`/`text`/`ts` keys, for Gotify, Home Assistant, or any
  endpoint that accepts a POST) and/or an **[ntfy](https://ntfy.sh) topic** (the alert text as the
  message body, optional `Authorization: Bearer` token). Configured in a new top-level
  `notifications` block (`webhooks` list, `ntfy.url`/`ntfy.token`); all unset — the default —
  runs nothing new, and Telegram plus its per-event toggles are unchanged (the new sinks carry
  every event). Both sinks copy the Telegram alerter's discipline: fail-silent, secrets (webhook
  URLs, the ntfy token) never logged or echoed, and **Tor-routed by default** so the endpoint
  sees a Tor exit, not your host IP. `notifications.tor: false` is the LAN/self-hosted carve-out
  (Tor exits can't reach private addresses) — with it, clearnet endpoints see your host IP. See
  [Telegram › Webhook and ntfy sinks](docs/telegram.md#webhook-and-ntfy-sinks).

### Changed

- **The deploy-box layout is a product feature (#455).** `./pithead setup` and `./pithead upgrade`
  now maintain a `current -> pithead-vX.Y.Z` symlink beside the install when the install directory
  is version-named — one authoritative pointer to the live install, updated (`ln -sfn`) only on a
  successful upgrade; the dashboard's one-click upgrade (#59) runs the same `upgrade` and moves it
  too. The dashboard database also stops living inside the install directory: when the four other
  `*.data_dir` share one parent, `dashboard.data_dir`'s default joins them there, and a one-time
  migration in `upgrade`/`apply` moves data from the old `./data/dashboard` default (stop the
  dashboard, move, verify the DB arrived; an explicit `dashboard.data_dir` is warned about and
  left alone, and data at both locations stops the run instead of guessing). The canonical layout
  — `current`, one rollback version dir, the shared data root — is documented in
  [Operations › The deploy-box layout](docs/operations.md#the-deploy-box-layout), replacing the
  hand-written per-box READMEs.

### Fixed

- **The `payout_confirmed` alert is now listed and silenceable (#381/#462 follow-up).** The
  confirmed-on-chain-payout alert shipped on-by-default but `pithead` never rendered
  `telegram.events.payout_confirmed`, so it couldn't be turned off and was missing from the event
  reference. It's now wired end to end (config.json → `.env` → dashboard) and documented in the
  Telegram alert tables alongside the others; set `telegram.events.payout_confirmed: false` to silence
  it.
- **The shared bench-lock opens read-only, matching RigForge byte-for-byte (#499, ports rigforge#252).**
  The tier-4 harness's `rig_lock` helper (`tests/integration/lib.sh`) opened its flock file write-open
  (`exec 9>`); on a shared box where the lock was first created by a non-root reserve,
  `fs.protected_regular=2` blocks even root's write-open of the foreign-owned file with EACCES, so the
  flock was silently *not* held and the box read as unreserved. It now opens read-only (`exec 9<`,
  RigForge #242) — never guarded, and `flock -x/-s` works fine on a read fd — with a symlink guard and
  the holder breadcrumb beside the lock. The helper is byte-identical to RigForge's canonical copy
  again (the same lock path + open semantics on every box *is* the reservation protocol). Test-harness
  only; no runtime change.
- **The tier-4 hardening phase always reaps its root control units (#477).** The phase installs the
  `pithead-control.{path,service}` systemd units to exercise the #33 spool, and relied on the restore
  `apply` to remove them — but that removal runs early in `apply`, so a restore that died partway (a
  render failure, or the settle timeout firing mid-apply) could leave the **root** `pithead-control.path`
  unit watching the control spool after the run, exactly the host residue tier-4 exists to prevent. The
  phase now tears the units down unconditionally at the end, independent of the restore's exit code, and
  warns loudly if any survive (a no-op on hosts without systemd). Test-harness only; no runtime change.

- **Telegram control prompts are rate-limited per operator, not globally (#470).** The `ControlGate`
  budget (max approval prompts per rolling hour) was one shared list, so a single allow-listed id —
  or one compromised-but-allow-listed session — could exhaust it and lock the *other* operators out
  of `/restart` / `/apply` for up to an hour. The budget is now keyed by operator id, so each caps
  independently. A confidentiality/integrity fix this is not (the host-side fixed-verb runner is the
  real boundary, #33/#338) — only availability among already-trusted operators; the `ControlGate`
  docstring was corrected to say so.

- **The dashboard auto-heals a corrupt SQLite database instead of erroring forever (#489).** A
  clashed WAL checkpoint (seen when a container was recreated twice in quick succession) could leave
  `mining_data.db` malformed; the dashboard then logged a write error every cycle **indefinitely** and
  silently lost all history — and that DB now holds XvB-credited and payout state, so corruption can
  skew the donation loop. On startup (`PRAGMA integrity_check`) and on any write that reports the file
  malformed, the dashboard now quarantines the bad file to `mining_data.db.corrupt-<UTC>` (kept for
  post-mortem, oldest pruned), rebuilds a fresh schema, and resumes persisting. A one-shot **`db_reset`
  alert** fires through Telegram and the other sinks so you know history before that point was cleared
  — a plain "DB write failing" badge could be missed, since a startup reset has no prior state and a
  runtime reset flips back to healthy within one cycle. A *transient* failure (disk full, locked,
  permissions) is unchanged: it still just flags the persistence badge and retries, never discarding
  history.

- **`pithead <verb> --help` no longer runs the command (#493).** `-h`/`--help` on any subcommand now
  prints usage and exits 0 **before any side effect** — previously `pithead upgrade --help` ignored
  the flag and ran a full upgrade (image pull + container recreation). On the v1.4.0 deploy that
  stray recreation collided with the real upgrade and corrupted the dashboard's SQLite DB (see the
  auto-heal fix). Unrecognized flags on a no-option verb (`upgrade`, `up`, `down`, `status`,
  `doctor`, `control-run-pending`, `onion-client-key`) now error and name the bad flag instead of
  being silently ignored while the command runs anyway. `--dry-run` and other real options are
  unaffected; `logs` still forwards its args to `docker compose logs`.

- **The tier-4 e2e harness survives a dirty bench and restores the right stack (#454).** Two
  environmental failures from the v1.4 release gate: provisioning aborted when a leftover untracked
  file (a stray bench script) sat in the disposable `/srv/code/pithead-e2e` checkout — `git checkout`
  refused with "would be overwritten." Provisioning now forces a pristine tree (`checkout -f` +
  `reset --hard` + `clean -fdx`, keeping the harness's `results/` and the gitignored
  `config.json`/`.env`/`data/`/`backups/`). And the restore path ran `pithead apply/up` from
  `CANONICAL_DIR`, but on a release box the live stack runs from a per-version bundle dir — so the
  source checkout took over the `pithead` project with locally-built `:dev` images and Tari
  crash-looped. Restore now targets the directory the live stack actually ran from, read at preflight
  off the running container's `com.docker.compose.project.working_dir` label, and falls back to
  `CANONICAL_DIR` only when the stack is down.

### Security

- **The dashboard container never sees a plaintext secret (#440).** The one accepted residual
  from the #33 control-channel reviews is closed: the dashboard no longer bind-mounts the raw
  `config.json` to prefill its Configuration form. The host now renders a pre-masked copy —
  every set secret (node RPC credentials, stratum and dashboard passwords, the Telegram bot
  token, the Healthchecks ping URL) already replaced by a sentinel — into a read-only leg of the
  control spool (`data/control/masked/`), and the form serves from that. The
  "leave blank to keep the current value" merge moved host-side too: an untouched secret rides
  back as the sentinel and the runner swaps in the live value at staging, so the request spool
  is also secret-free. A fully compromised dashboard container can now read masked config,
  results, and the audit log, and ask to change an allowlisted key — nothing else. The copy is
  re-rendered on every `setup`/`apply`/`upgrade` and runner pass, so it never serves stale state
  for long. See [SECURITY.md](SECURITY.md#secret-trust-boundary-for-dashboard-config-editing).

- **Image verification is bound to the pulled bytes (#451).** `verify_release_images` now cosign-
  verifies the immutable `@sha256` digest the bundled compose pins each first-party image to (#461),
  not the mutable tag. Verify and pull resolve the same content-addressed bytes, so a tampered
  registry can no longer serve the signed manifest to cosign and a different one to docker in a
  separate dial. With a key present, an image whose compose line is not digest-pinned aborts too —
  there is nothing to bind the check to.

- **First install verifies signatures, not just upgrades (#452).** A fresh release install's first
  `pithead up` pulled the five first-party images with no signature check; the gate now runs on that
  path as well, under the same rules as `upgrade` — source checkouts skip, a missing `cosign.pub`
  warns and proceeds (signing is opt-in), a present key that fails aborts before anything starts.
  (`apply` and `rotate-secrets` recreate from the already-verified local images, so the two
  registry-pull paths — first `up` and `upgrade` — are now both gated.)

## [1.4.0] - 2026-07-11

### Added

- **Tor guard self-heal (#424).** Tor can bootstrap to 100% and then sit on a failing guard:
  circuits time out, so every Tor-clearnet feature — Healthchecks pings, the Telegram bot, XvB
  stats — breaks at once while mining (established onion circuits) keeps working. v1.3.1 added
  the doctor check that detects this; this adds the heal. `./pithead restart tor` restarts only
  the tor container so it picks fresh guards (the `restart` command now takes an optional `tor`
  argument, tab-completed). Opt-in `tor.auto_heal: true` makes the dashboard do it automatically:
  it probes Tor clearnet egress every 5 minutes (the doctor check's `generate_204`-through-SOCKS
  probe) and restarts tor — through the same start/stop-only docker-control proxy as the #31
  failover — once egress has been broken for 15 minutes. At most 3 restarts per outage, 30
  minutes apart, every restart logged at WARNING and recovery followed by a one-time Telegram
  note; if egress stays broken (the Tor network itself overloaded), it stops restarting and keeps
  warning. Off by default: a tor restart drops all circuits, so the stack never restarts its
  privacy boundary unbidden. The doctor WARN now names both fixes. See
  [Operations › Troubleshooting](docs/operations.md#troubleshooting).
- **Simple view points at the Advanced-only calculators (#425).** The P2Pool Earnings card — the
  XMR/XTM estimates and the XvB tier calculator — renders only in Advanced view, and operators on
  the default Simple view concluded it didn't exist. Simple view now shows a one-time dismissible
  banner linking to Advanced view; dismissing it (or opening Advanced view) retires it for good
  in that browser.
- **Subcommand chaining + bash/zsh tab-completion (#94).** `./pithead apply upgrade` runs both
  commands in order, failing fast on the first non-zero step and reporting what did and didn't
  run. The whole chain is validated first: non-chainable commands (`setup`, `logs`, `restore`,
  `reset-dashboard`, the info commands), duplicates, more than one of `up`/`down`/`restart`, or
  `down` anywhere but last are rejected with nothing executed. Single-command invocations are
  unchanged. `pithead-completion.bash` (repo root, shipped in the release bundle) adds
  tab-completion for subcommands and `logs <service>` in bash and zsh; a test pins its command
  list to the CLI dispatch so the two can't drift. See
  [Operations](docs/operations.md#chaining-commands).
- **`pithead rotate-secrets` regenerates the stack's internal credentials in one command (#378).**
  After a suspected leak (a backup that left the box, a pasted `.env`), one command rotates the
  local Monero RPC password (skipped in remote mode — that credential belongs to the remote node),
  the stratum access-password when `p2pool.stratum_password` is `"auto"` (the new value is printed
  and every rig must update its `pass`; a literal is left in `config.json` with a pointer), and the
  xmrig-proxy control-API token (always), then recreates the containers that consume them. The old
  values stay recoverable in owner-only `config.json.bak-<timestamp>` / `.env.bak-<timestamp>`
  copies taken before anything changes, and a failed recreate leaves the retry marker so
  `./pithead apply` finishes the job. The dashboard onion keeps its own `rotate-dashboard-onion`.
  See [Operations › Rotating the internal secrets](docs/operations.md#rotating-the-internal-secrets).
- **`pithead backup` encrypts archives by default (#374).** The backup archive carries the stack's
  full secret material (`.env`, the onion private keys, the dashboard DB), and its `chmod 600` only
  protects it on the local disk. `backup` now prompts for a passphrase (twice) and streams the tar
  through `openssl enc -aes-256-cbc -pbkdf2 -iter 600000` into a `.tar.gz.enc` — no plaintext
  archive ever touches the disk, and the passphrase travels over a file descriptor, never argv.
  `PITHEAD_BACKUP_PASSPHRASE` covers unattended runs; an unattended run (`--yes`) with no passphrase
  set **refuses** rather than writing plaintext (a cron job that lost its passphrase fails loudly
  instead of archiving your onion keys in the clear), while `--no-encrypt` — or an empty passphrase
  at the interactive prompt — chooses plaintext explicitly. `restore` detects encrypted vs plaintext
  archives by magic bytes, so every existing backup restores unchanged; a wrong passphrase fails
  before anything on disk is touched, and because CBC carries no authentication, `restore`
  verifies the whole decrypted stream (`tar -tzf -`, no plaintext on disk) before extracting, so a
  tampered or truncated archive is refused rather than half-restored over the live config.

- **Edit config from the dashboard (#33).** A new **Configuration** view — opt-in via
  `dashboard.control.enabled` (default off; requires a `dashboard.auth.password`) — prefills a
  form from the live `config.json` with secrets masked ("set — leave blank to keep"), previews
  the exact change rows `pithead apply` prints (disruptive rows flagged ⚠), and applies the
  result. The form covers the full schema — `config.reference.json` is merged under the operator's
  sparse `config.json`, so every setting is editable, not just the keys already present. The
  dashboard container never runs `pithead`: it writes typed JSON intents into
  `./data/control/requests/` (its only writable spool leg; results and the audit log are mounted
  read-only), and a root systemd path unit (`pithead-control`) validates each intent with
  pithead's own config validation and dispatches only `apply --dry-run --porcelain` or `apply -y`.
  A change outside a small allowlist of operational settings (wallets, auth, onion exposure,
  clearnet toggles, credentials, and anything destructive) is refused at the host — the
  client-side confirm is not a security control, since a compromised container writes the spool
  directly — and must be applied from the host CLI until out-of-band approval (#338) lands. Every mutation lands in a host-side audit log with the logged-in user (Caddy forwards it
  as `X-Auth-User`); a failed apply keeps the previous config at `config.json.bak-control`. This is
  the canonical host-mutation channel that the upgrade button (#59) and the first-boot wizard (#77)
  build on.
- **`pithead apply --dry-run [--porcelain]`.** Print the change preview and stop — `.env`,
  generated files, and containers are untouched. `--porcelain` emits machine-readable
  `FLAG<TAB>KEY<TAB>MESSAGE` rows (what the control runner consumes), and `PITHEAD_CONFIG_FILE`
  points a single invocation at a candidate config file.
- **`pithead control-run-pending`.** The host-side runner behind the Configuration view; fired by
  the systemd path unit, runnable by hand.
- **One-click upgrade from the dashboard (#59).** With `dashboard.control.enabled` on, a release
  install shows an **Upgrade to vX.Y.Z** button next to the existing new-release badge (#224).
  After a typed `UPGRADE` confirm, the host-side control runner performs the documented update —
  download the new release bundle, run `pithead upgrade` — surviving the dashboard container's own
  recreation, and the page rides out the restart and reports the outcome. The intent carries only
  the version the operator saw: the runner re-derives the latest release from the GitHub API over
  Tor and refuses a mismatch, an older-or-equal version, a source checkout, or more than one
  attempt per 10 minutes, and audits every attempt. A failed release lookup or bundle download
  changes nothing; a failure inside `pithead upgrade` leaves not-yet-recreated containers on the
  previous images and is finished with `./pithead upgrade` on the host.
- **Audit + access logs for attack visibility (#349).** The #33 audit log now records *what*
  changed — the env-key names from the same host-side dry-run the approval gate runs; never
  values — and is size-bounded (trimmed to the newest 2000 entries past 512 KiB). Caddy gains a
  JSON access log on every vhost (`./data/caddy-logs/access.log`, rolled natively at 4 MiB × 3
  files, credential headers redacted). The Configuration view surfaces both read-only: recent
  config changes, recent accesses, and a failed-login (401) count for the last 24 h with a
  rotate-the-password/onion nudge when failures spike — over Tor there is no source IP, so the
  rate of 401s *is* the intrusion signal. Every field read from either log is treated as hostile
  input and whitelisted to a safe character set before display. See
  [Operations › Watching for intruders](docs/operations.md#watching-for-intruders).
- **`status` shows per-chain sync progress (#384).** While a chain is still syncing, `./pithead
  status` reads the dashboard's own `/api/state` and prints each chain's percent and blocks
  remaining inline, instead of only pointing you at the dashboard. No ETA is shown — block rate
  isn't sampled, so blocks-remaining is the honest figure. The lines are skipped once both chains
  are synced or when the dashboard app isn't answering yet.
- **First-run "what happens next" note (#384).** The first time the stack comes up, `pithead` prints
  a short epilogue explaining that the miner is held until Monero and Tari finish their initial sync
  and then starts automatically, plus where to watch progress. It shows once (keyed on a marker file
  beside `.env`), not on every restart.
- **`pithead version` prints the installed stack version (#386).** `version` (and the `-V` /
  `--version` aliases) prints one line identifying the build — `pithead vX.Y.Z (release images
  vX.Y.Z)` for a release install, `pithead dev (branch @ commit, VERSION X.Y.Z)` for a source
  checkout — with no network call or update check. `doctor` repeats the line in its header, so every
  pasted diagnostics report carries the version.
- **`CODE_OF_CONDUCT.md`** — the Contributor Covenant v2.1, filling the last empty slot in the
  GitHub community profile. Enforcement reports go through the same private channel as security
  reports (see [`SECURITY.md`](SECURITY.md)). CONTRIBUTING links it (#372).

### Changed

- **`build/tor/Dockerfile`** now pins Alpine to a named minor version (`alpine:3.24`) alongside its
  digest, instead of the floating `latest` tag, so Dependabot has a real version line to track
  (#373).
- **CONTRIBUTING** describes `make test` accurately: it needs Docker (via `lint-proto`), and the
  lint-surface list now includes `lint-docs-voice` (#371).

### Fixed

- **The XvB donation controller no longer overshoots the target tier in steady state (#423).**
  During a split cycle the p2pool remainder dwell ended on its first 30-second check, because the
  dwell's early-exit asked "would we donate at all?" — a question the held split answers yes to by
  construction. The donated share of wall-clock time became slice/(slice + tick) instead of
  slice/cycle, an order of magnitude above the commanded fraction, and the controller couldn't
  unwind it: its command was already near zero. Live on v1.3.0 that held the credited averages
  26-44% above the tier threshold — donation above threshold buys zero extra raffle chance —
  and the resulting sawtooth intermittently dipped *below* tier too. The dwell now ends early only
  when the decision actually *changed* (or the fresh 1h average slips under tier — the catch-up
  path is untouched). A new wall-clock simulation (`run_actuated` in
  `mining_dashboard/sim/donation_model.py`) replays the run loop through the real dwell rules —
  the layer the fixed-step #70 sim was blind to — and pins steady state at 1.03x target with the
  tier held; pre-fix it reproduces the overshoot at 1.17-1.21x with the tier intermittently lost.
  The split decision log now also carries the instantaneous donated rate (`inst ~N H/s`) next to
  the credited 1h/24h averages, so a live soak can watch the routed-vs-credited gap directly.
- **`release.sh` rides out GHCR's read-after-push lag (#429).** A tag the registry just accepted can
  fail to resolve for a few seconds; the digest-capture and smoke-stage manifest reads killed the
  v1.3.1 cut twice this way. Both reads now retry with backoff (5 tries by default, tunable via
  `PITHEAD_REGISTRY_READ_RETRIES` / `PITHEAD_REGISTRY_READ_BACKOFF`) before giving up, so a slow-to-
  propagate push no longer turns a release into a relaunch exercise. A genuinely-missing image still
  stops the release after the retries exhaust.
- **`release.sh` preflight checks the lint toolchain before building (#426).** A reimaged release box
  can lack `shellcheck`/`shfmt`/`node`/`uv`; the release used to die about a minute in with a bare
  `shellcheck: not found` mid-gate. Preflight now verifies the tools the test gate needs are on PATH
  and fails fast, naming the missing tool and pointing at the provisioning steps in
  `docs/dev/release-server.md`, before anything is built.
- **`tests/integration/build-pruned-chain.sh`** no longer defaults `SRC_DIR` to a maintainer's
  personal path (baked in under the pre-rename repo name); it's now a required variable with a clear
  error (#373).

### Security

- **Signed releases, verified before upgrade (#376).** The release pipeline now cosign-signs the
  five promoted image digests and the install bundle with a key that lives only on the release
  box; the public key is committed as `cosign.pub` and ships in every bundle. On a release
  install, `pithead upgrade` verifies every image signature against `cosign.pub` before pulling,
  and the dashboard's one-click upgrade (#59) verifies the downloaded bundle against the key
  already on disk before extracting — a new bundle's own key never vouches for itself.
  Verification fails closed: with the key present, a bad signature, a stripped `.sig`, or a
  missing cosign binary aborts the upgrade with nothing pulled or restarted. Installs without
  `cosign.pub` (bundles up to v1.3.x) keep today's TLS-to-GitHub + tag-pinning behaviour with a
  loud warning, and `doctor` reports the verification state. See
  [Releasing › Signed releases](docs/dev/releasing.md#signed-releases).
- **Read-only root filesystems on every service (#377).** tor, monerod, tari, p2pool, xmrig-proxy
  and the dashboard now run with `read_only: true` like Caddy and the two socket proxies already
  did. Each service keeps exactly its verified write paths: the bind-mounted data dir plus a
  size-capped, `noexec` tmpfs for rendered configs and scratch (`/tmp` everywhere; xmrig-proxy also
  gets a tmpfs over its image-only home in case the binary persists an API-driven config change).
  A compromised process can no longer stage tools in, or persist changes to, its container image.
  Nothing durable moves: the tmpfs mounts are wiped on restart by design, and every config
  re-renders at container start.
- **Reject control characters in every config string (#33).** `parse_and_validate_config` — the
  chokepoint both the preview and the real apply run — now refuses any config value carrying a
  newline or other control character. A newline in a secret that renders unquoted into `.env`
  (`node_password`, `bot_token`, `api_token`, …) could otherwise inject a second `KEY=value` line
  such as `PITHEAD_REGISTRY=evil.tld`, which the root apply would then trust for every image pull.
  Now that a full config crosses the control-channel boundary, these fields are attacker-reachable.
- **Require Tor client authorization for the control channel on a published onion (#33).** Enabling
  `dashboard.control` while `dashboard.onion` is on now fails validation unless
  `dashboard.onion.client_auth` is true (the default). A root-capable, funds-redirecting mutation
  channel must not sit behind only a brute-forceable password on an anonymously-reachable onion.
- **Default-deny commit gate at the host (#33).** The control approval gate refuses any commit
  that changes an env key outside an explicit allowlist of operational settings (pool tier, XvB
  enable and donation level, alert toggles, memory limits, time zone, …) — in either direction,
  enable or disable — plus anything the change preview flags destructive. An allowlist, not a
  blocklist: wallets, auth, onion exposure, the control channel itself, Tor egress and clearnet
  toggles, node endpoints, the XvB pool URL and donor id, and every credential stay host-CLI-only,
  and so does any key added in the future until it is deliberately listed. The changed-key set and
  destructiveness are re-derived host-side from the staged config — the container's result is
  never trusted. The hook is shaped for #338 to drop in out-of-band Telegram approval.
- **Bound the root-runner spool (#33).** Intents over 64 KB are refused before `jq` parses them, a
  run drains at most 50 intents, and `staged/` + `requests/` files older than an hour are swept at
  run start. Symlinked or non-regular claimed files are refused (never followed), and the intent-id
  gate is a strict canonical uuid4.
- **Mask `healthchecks.ping_url` and narrow the secret mount (#33).** The dashboard config API now
  masks the Healthchecks ping URL (a capability secret) alongside the other secrets, host-side
  staged copies carrying merged secrets are written mode 600, and `SECURITY.md` records that the
  read-only `config.json` bind mount — not the API masking — is the real secret trust boundary.

### Dependencies

- **Move `grpcio` off the yanked 1.82.0 release (#419).** PyPI yanked 1.82.0 for a bad protobuf
  constraint, so every `uv lock` warned. The floor moves to 1.82.1, the first non-yanked release
  above it; the lock now resolves to 1.82.1 with the warning gone. `grpcio` core carries no protobuf
  dependency, so protobuf stays on 6.x and the checked-in Tari stubs (which floor at
  `GRPC_GENERATED_VERSION = '1.78.0'`) import unchanged — no regeneration needed.

## [1.3.1] - 2026-07-10

A patch release: an honest Tari earnings headline for solo merge-mining, a fail-safe for the XvB
donation controller during a prolonged stats outage, an XvB per-tier payout comparison, and a
tabbed earnings panel.

### Added

- **XvB per-tier payout comparison.** The XvB section of the earnings card now shows, for a tier you
  pick from a dropdown, its **Expected** reward (XvB's own published per-tier figure, in XMR/year),
  its **Cost** (the P2Pool earnings foregone by donating the tier threshold for a year), and the
  **Net** of the two — so you can weigh, say, Whale against VIP Donor at a glance. The expected
  figure comes from XvB's pre-computed `reward_estimate_pub.txt` (their `reward_calc` output),
  fetched over Tor on the same cadence and staleness rules as the XvB stats: a stale or failed fetch
  degrades to "estimate unavailable" — never a stale number implied fresh, and never a fabricated
  one. The card keeps its standing note that a tier is raffle status, not a payout, and that
  donating above the threshold buys no extra win chance.
- **Tabbed earnings panel.** The earnings card now splits into `Monero`, `Tari`, and `XvB` tabs,
  driven by one shared what-if hashrate input, so the (now three-domain) card isn't one long wall of
  figures. The XvB tab appears only when XvB is enabled.

### Fixed

- **`doctor` catches a Tor guard failure that silently breaks Healthchecks, Telegram, and XvB
  (#424).** Tor can bootstrap to 100% yet sit on a failing guard: circuits build but clearnet exits
  time out, so the dead-man's-switch pings, the Telegram bot, and XvB stats all stop while mining
  (onion circuits) keeps working — the stack looks healthy as three features die. A new doctor check
  makes one request through Tor's SOCKS to a no-content endpoint and WARNs with the fix (restart the
  tor container to pick fresh guards) when clearnet exits fail. Found live on the production stack after the
  v1.3.0 deploy.
- **A release-box checkout that has run the stack no longer fails `lint-toml` (#421).** taplo globs
  the filesystem, not the git index, so the generated (git-ignored) `build/tari/config.toml` left by
  a past stack run failed the release gate on a real checkout — CI never sees it. The generated file
  is now excluded in `.taplo.toml`.
- **P2Pool Earnings shows Tari as the lumpy solo income it is.** Tari merge-mining here is solo — the
  whole block reward lands at once when your own hashrate finds a Tari block, which at the current
  network difficulty can be months apart. The earnings card headlined a per-day XTM figure that read
  like steady income you never actually receive. It now leads with the expected **time to a Tari
  block** (`difficulty ÷ hashrate`) and the full **per-block reward**, and keeps the per-day figure
  only as a clearly labelled long-run average. The server publishes the rate (one source of truth,
  #61); the client scales it to the what-if hashrate.
- **XvB donation controller decays a blind donation through a prolonged stats outage.** When the
  xmrvsbeast.com stats fetch goes quiet, `avg_1h` freezes; the controller already holds the last
  donation fraction rather than steering off the frozen number (#311). That hold was indefinite —
  through a multi-hour outage it kept donating blind, and if staleness began mid-ramp it held a
  high fraction (over-donation, #70 territory). Past a longer grace (`XVB_STALE_DECAY_AFTER_S`,
  default 30 min, distinct from the short-hold `XVB_STATS_STALE_AFTER_S`) the controller now decays
  the held fraction geometrically toward 0 each cycle and stops donating: when it can't confirm the
  donation is still needed, it stops wasting hashrate. A fresh fetch resumes normal control. The
  brief-blip hold is unchanged.

## [1.3.0] - 2026-07-09

v1.3 makes the stack remember and reason. The dashboard used to fetch telemetry, render it live, and
throw it away — you got a last value, never a trend. This release persists the share-health series it
was discarding, detects block and payout events, and turns both into panels, calculators, and alerts.
Around that arc: a payout-wallet tamper tripwire, three new `doctor` runtime checks, a Prometheus
`/metrics` endpoint, and a batch of accuracy and tooling fixes. Run `./pithead upgrade` to pick it up.

### Added

- **Pool Cadence & Luck card + Telegram `/luck` command (#84).** A read-only Advanced-view card
  showing time since the pool's last block (pool-wide), the estimated time for your hashrate to
  find a sidechain share, luck (actual vs. expected shares in the PPLNS window — over 100 % =
  running lucky), and your own PPLNS share-weight (the sum of your share difficulty in the window,
  distinct from the pool-wide PPLNS weight). `/luck` answers with the same four figures. Everything
  derives from the per-share difficulty the dashboard already stores — no new data captured.
- **Tari earnings in the calculator and `/earnings` (#117).** The earnings card now also estimates
  the XTM the same hashrate merge-mines alongside the XMR — day/month/year rows driven by the one
  what-if input, from the Tari block reward and difficulty p2pool's merge-mine stats already
  report. `—` while merge-mining is inactive or Tari is still syncing; the Telegram `/earnings`
  reply gains the matching XTM/day line, shown only while those figures are live.
- **Share-health time-series and reject-rate trends (#116, first slice of the #196 epic).**
  Pool-wide accepted/rejected/invalid/expired share deltas persist per poll in the dashboard
  database, reset-safe across proxy restarts. `/api/state` serves the series plus a trailing 24h
  reject rate, and a `high_reject_rate` Telegram alert fires when the trailing hour crosses 5 %
  (`telegram.events.high_reject_rate`, on by default).
- **Telegram alerts for the good news: block found and payout found (#336).** Fires on P2Pool block
  finds from the pool stats the loop already reads; the payout variant additionally requires a share
  in the PPLNS window. Both on by default (`telegram.events.block_found` / `payout_found`).
- **Payout-wallet tamper tripwire (#375).** The dashboard persists the wallet p2pool actually mines
  to; any change raises a Telegram alert and a 72-hour top-bar warning (addresses truncated to
  8 chars), and `pithead apply` requires typing the new address's first 8 characters before applying
  a wallet change (`--yes` still works for automation). A silently swapped `monero.wallet_address`
  no longer goes unnoticed.
- **Prometheus `/metrics` endpoint (#379).** ~28 `pithead_*` gauges rendered from the metrics the
  dashboard already computes — no new dependency, same bind and auth as the dashboard. Scrape
  example in [docs/monitoring.md](docs/monitoring.md).
- **Telegram `/status` shows the 24h P2Pool/XvB split (#365)** when XvB is enabled, using the same
  math as the daily digest.
- **Three `doctor` runtime checks (#383).** The Tor-egress firewall rules are actually installed (a
  host reboot silently drops them while the containers auto-restart), something is listening on
  stratum `:3333` while xmrig-proxy runs, and the dashboard app answers behind its container.
- **Workers-table first-run hint (#385).** Until the first worker connects, the empty table is
  replaced by "point each rig at `<host-ip>:3333`" with the real address filled in.
- **Tier-4 fault injection: dashboard DB write failure (#202).** The live matrix proves
  `db_healthy` flips false when the data dir goes read-only and recovers on restore.

### Fixed

- **A hung `/api/state` poll no longer freezes the dashboard (#382).** The refresh fetch had no
  timeout, so a Tor circuit that hung (rather than failed) left stale numbers looking live
  indefinitely. Polls now abort after 25 s and the disconnected banner names the timestamp of the
  data on screen.
- **Worker-table columns tell the truth (#387).** The "10s / 60s / 15m" labels sat over 1m/1m/10m
  proxy data; the columns are now labelled `1m`/`10m` and the duplicate first column is gone (API
  consumers: worker rows no longer carry `h10`/`h10_str`). The chart tooltip abbreviates hashrate
  like every other surface, and Telegram XMR figures use the dashboard's adaptive decimals.
- **The CLI's own messages say `./pithead` (#389)** — thirteen remediation hints told the operator
  to run a `pithead` command that isn't on PATH.

### Changed

- **Naming sweep (#388).** The CLI log prefix is `[pithead]` (the last survivor of the pre-rename
  wordmark), the browser tab says Pithead, and "merge-mining" is hyphenated everywhere.
- **XvB tier calculator in the earnings card + richer `/xvb` (#118).** The same what-if hashrate
  now also answers which XMRvsBeast donor tier it can sustain (the donation controller's own auto
  rule), the tier's threshold, and the cost of holding it — about the threshold in continuous
  donation, since XvB qualifies a tier on both the 1h and 24h credited averages. Labelled as
  raffle status, never an XMR payout, with no entry counts or win odds shown (the draw is random
  above the threshold). Hidden while XvB is disabled. The Telegram `/xvb` reply gains the matching
  threshold, cost, and not-a-payout lines.

## [1.2.2] - 2026-07-04

Patch — the dashboard Tor onion (#343) now works with a stock Tor Browser, plus two provisioning
fixes found running the onion on a live box. Re-download the bundle or run `./pithead upgrade` to pick
it up; enabling the onion (`dashboard.onion.enabled`) is unchanged.

### Added

- **The dashboard onion serves HTTPS as well as HTTP (#343).** Tor Browser upgrades `http://` to
  `https://` by default, and the onion previously served only plain HTTP, so the upgraded request hit
  a refused `:443` and dead-ended — you had to disable the upgrade in `about:config` to reach the
  dashboard. The onion now also serves HTTPS (a second `HiddenServicePort` and a Caddy vhost with a
  self-signed cert for the `.onion`, the same one-time "accept the risk" the LAN dashboard already
  uses, since a `.onion` can't obtain a browser-trusted cert). Stock Tor Browser now reaches it with
  no settings changes.

### Fixed

- **`pithead upgrade` auto-generates the onion password like `apply`/`setup` do (#355).** Enabling the
  onion without a `dashboard.auth.password` is meant to generate a strong one; `upgrade` validated
  before generating, so it errored instead. It now generates first, matching the other commands.
- **`pithead rotate-dashboard-onion` no longer crashes, and `upgrade` captures the onion address
  (#356).** `rotate-dashboard-onion` aborted on an unbound `HOST_IP` and reset the deployment flag;
  both are fixed. Separately, enabling the onion via `upgrade` now reads the generated `.onion`
  address back into `.env` so `pithead status` / `onion-client-key` show it (previously only `apply`
  captured it).

## [1.2.1] - 2026-07-03

Patch — surface the remote-access **dashboard onion URL in `pithead status`**. The running stack
images are unchanged from 1.2.0; the fix is in the `pithead` CLI, so re-download the bundle or run
`./pithead upgrade` to pick it up.

### Fixed

- **`pithead status` now prints the dashboard onion address (#343, #352).** With the remote-access
  onion enabled, its `.onion` URL — plus a pointer to `pithead onion-client-key` for the client key —
  now shows in `pithead status`, where an operator looks first. Previously only `pithead doctor`
  printed it, even though the docs pointed at `status`. The client **private key** is never shown in
  either report (it stays behind `onion-client-key`), and `status` and `doctor` now share one resolver
  so they can't drift. The docs are corrected to name both commands.

## [1.2.0] - 2026-07-03

**Operator-visibility release — the stack can now tell you when something is wrong, and let you reach
it from anywhere over Tor.** A Telegram operator bot pushes a curated set of alerts and answers
on-demand status commands; an optional Healthchecks.io dead-man's switch catches a whole-host death
that an in-stack notifier structurally can't report; and the dashboard can publish an optional Tor
onion so you can reach it remotely without a port-forward or public IP. All three run over Tor. This
minor also isolates the Docker socket proxies onto their own network, off the mining bridge.

**Upgrade note:** every new surface is opt-in and off by default — enable them in `config.json`
(`telegram`, `healthchecks.ping_url`, `dashboard.onion`). Pick the changes up with `./pithead upgrade`
(or re-download the bundle); your `config.json` and preserved secrets (Tor onions, RPC credentials,
proxy token) are untouched.

### Added

- **Telegram operator bot (#121, #45).** Opt-in. Pushes a curated set of operational edges — node
  down/recovered, worker offline/joined/left, sync finished, disk filling, database unhealthy, host
  advisories (HugePages off, low RAM), a hashrate-drop detector, XvB no-share and registration
  problems, clearnet exposure, and a once-a-day digest — and answers read-only on-demand commands
  (`/status`, `/hashrate`, `/workers`, `/sync`, `/system`, `/pool`, `/xvb`, `/earnings`, `/info`,
  `/help`) from a single configured chat. Alerts and commands are separate opt-ins, every event has a
  toggle, and both the sends and the command poll ride the bridge Tor SOCKS (#340), so Telegram sees a
  Tor exit and not your host IP. See [`docs/telegram.md`](docs/telegram.md).
- **Healthchecks.io dead-man's switch (#79).** Opt-in. Set `healthchecks.ping_url` and the dashboard
  pings it every cycle; if the whole host dies the pings stop and Healthchecks.io alerts you on the
  *absence* of a ping — the one failure mode an in-stack notifier can't report. The ping always rides
  Tor, so it is never a clearnet beacon; the URL must be Tor-reachable (hosted `hc-ping.com`, or a
  self-hosted onion/public instance).
- **Optional Tor onion for the remote dashboard (#343).** Opt-in (`dashboard.onion.enabled`, default
  off). Publishes a fourth onion that fronts the authenticated Caddy login, so you can reach the
  dashboard remotely over Tor with no port-forward and no public IP. It defaults to Tor v3 client
  authorization (the onion does not respond without your client key), and `pithead` refuses to publish
  it unless the dashboard password is at least 16 characters. This is inbound access and does not
  change the egress posture. See
  [Remote access over Tor](docs/configuration.md#remote-access-over-tor-onion-service).

### Changed

- **Docker socket proxies isolated off the mining bridge (#345).** The read-only and start/stop socket
  proxies now sit on their own network, published only to the host loopback, so no mining container
  can reach the Docker API even through the proxies. The host-networked dashboard reaches them at
  `127.0.0.1`; the dashboard's SSRF guard rejects the proxy addresses as before.

### Fixed

- **xmrig-proxy no longer renders a stray empty command argument (#347).** With no stratum password
  set (the default), the optional `--access-password` compose item rendered a literal empty argument
  and xmrig-proxy logged `unsupported non-option argument ''` on startup. The flag now passes through a
  wrapper entrypoint from an env var, so an unset password appends nothing. It was harmless, but the
  warning is gone.

### Documentation & tests

- A house-voice and factual-accuracy pass across the prose docs (#334), with the banned-word voice
  check and the testing-tier guidance enforced as CI guardrails (#335). Added coverage for flagged
  edge cases (#330), the Tor-onion container entrypoint and the daily-digest time parser (#348), and
  made the integration egress verifier survive a release-bundle `--dir` (#332).

## [1.1.0] - 2026-07-01

**Privacy release — the stack is now Tor-first by default and fail-closed.** Outbound P2Pool sidechain
peers (#165) and XvB donation mining (#166) route over Tor out of the box, a host firewall enforces
**Tor-only egress fail-closed** (#270) so a misconfiguration can't silently leak your IP, and every
container now runs **non-root** (#255/#91). Plus XvB raffle auto-registration, a Stack Topology panel,
and a large supply-chain / CI hardening wave. This is the first minor release on top of the 1.0.x line;
upgrade in place with `./pithead upgrade` (or re-download the bundle).

**Upgrade note:** the Tor-by-default routing and the fail-closed egress firewall are picked up
automatically on `upgrade`. The two config example files were renamed for clarity —
**`config.minimal.json`** (the quick-start: just the two wallet addresses) and
**`config.reference.json`** (all options); your own `config.json` and preserved secrets (Tor onions,
RPC credentials, proxy token) are untouched.

### Added

- **Tor-by-default outbound routing.** P2Pool's outbound sidechain P2P (#165) and XvB donation mining
  (#166) now ride Tor by default, closing the two clearnet yield paths that were left open in v1.0.
  The local monerod RPC/ZMQ path stays **direct** via a loopback bridge so mining is unaffected (see
  Fixed, #278).
- **Tor-only egress enforced fail-closed by a host firewall (#270).** A `DOCKER-USER` firewall installed
  before the containers start (#276) blocks any non-Tor egress, so a bad flag or a stale image can't
  leak your IP — it fails closed instead of leaking. The integration harness carries a **standing
  no-clearnet-leak egress gate** (#274) so a regression is caught in CI.
- **XvB raffle auto-registration (#263).** Miners are registered with the XMRvsBeast raffle
  automatically — no manual signup — so donations count toward the raffle without an extra step.
- **Stack Topology panel on the dashboard (#170).** A full wiring map of the stack: every ingress,
  egress, and internal hop, labelled Tor vs clearnet, so you can see at a glance what talks to what
  and over which transport.
- **One config-driven worker-API probe, default no-auth (#171, #172).** The dashboard's per-worker
  stats probe is now a single, config-driven request that defaults to no authentication (matching
  RigForge's open-by-default worker API), eliminating the spurious `401` log noise; auth is opt-in via
  `workers.api_auth` / an access token.
- **Autonomous Tor-vs-clearnet benchmark harness (#256).** A self-driving benchmark that measures the
  yield cost of running over Tor; the finalized methodology and results ship in `docs/privacy.md`
  (Tor costs ~10% P2Pool yield on a mini node, with zero extra rejects — so Tor stays the default).
- **Third-party attribution + GPLv3 source pointers (#259).** The bundled upstream components
  (P2Pool, Monero, XMRig-proxy, Tari, Caddy, …) are now attributed with license and source pointers.

### Changed

- **All containers run non-root (uid 1000) (#255, #91).** Every first-party image declares a non-root
  `USER`; data moved from `/root` to the user's home, and `pithead` chowns the data dirs to match on
  `apply`/`upgrade`/`restore`. The dashboard now owns its volume, so it can finally `cap_drop: [ALL]`.
  The migration handles an install upgraded from the root-container era (root-owned files under a
  user-owned dir are chowned to the container uid).
- **Config example files renamed** to `config.minimal.json` and `config.reference.json` (#326) — clearer
  than the old names; the quick start and `setup` guidance point at the minimal one.
- **Reproducible Python builds** with `uv` + a committed `uv.lock` (#283).

### Fixed

- **Tari merge-mining works under Tor (#313).** The Tor default silently killed Tari merge-mining —
  p2pool dialled the merge-mine gRPC at a private Docker IP through Tor, which rejects RFC1918, so the
  channel stuck at `TRANSIENT_FAILURE`. Fixed with a loopback bridge (mirroring #278), and the
  dashboard "✔" is now gated on the channel actually being `READY`, not just configured.
- **P2Pool ↔ monerod stays direct under Tor (#278).** #165's `--socks5` also proxied p2pool's *local*
  monerod RPC/ZMQ, which p2pool only exempts for loopback — so with Tor on, p2pool couldn't fetch block
  templates and mining stopped. The entrypoint now bridges `127.0.0.1` → the real node with `socat`, so
  the node stays direct while the sidechain still rides Tor.
- **Fail loud when a stale p2pool image drops the Tor flags (#273).** A compose↔image mismatch that
  would have silently disabled Tor routing now fails the start instead of running clearnet unnoticed.
- **Tor-egress firewall installed before compose on `upgrade` (#291)** and before containers start on
  first bring-up (#276) — closing the startup window where a container could reach clearnet before the
  firewall was in place.
- **Tari clearnet peer dials now route through Tor SOCKS (#271).**
- **XvB controller guarded against a stale/frozen stats fetch (#311).** A frozen XvB stats response no
  longer steers the donation controller off stale data; the stale state is surfaced instead.
- **Snapshot persistence-health bug (#330).**

### Security

- **Supply-chain & secrets hardening (#282).** gitleaks secret-scanning, Trivy image/filesystem
  scanning, Dependabot scoped to safe updates, all GitHub Actions SHA-pinned, and zizmor for workflow
  auditing — with `develop` branch protection wiring the checks in as required gates.
- Non-root containers (#255) and Tor-only fail-closed egress (#270) are themselves the release's two
  biggest security wins (see Changed / Added).

### Internal

- Repo-wide **ruff** lint + format (#280), per-surface linters (shfmt, Biome, yamllint, markdownlint,
  buf, taplo) (#281), Hypothesis property tests over the money/numeric logic (#284), diff-cover patch
  coverage adopted from RigForge (#286), and expanded live-validation coverage for the security
  features (#206, #295, #170). Dev-facing only; no runtime change.

## [1.0.3] - 2026-06-14

Hotfix — **validate the Monero payout address is a primary address**, so nobody silently mines to an
address that can't be paid. The published images are unchanged from 1.0.1; the fix is in the `pithead`
CLI (re-download the bundle / `pithead upgrade` to pick it up).

### Fixed

- **Reject non-primary Monero wallet addresses (#250).** p2pool pays out via coinbase, which **cannot**
  send to a **subaddress** (`8…`) or an **integrated** address — it needs a **primary/standard** address
  (`4…`, 95 chars), and XvB credits by the same address. Previously a subaddress passed validation, the
  stack mined, and **rewards silently went nowhere**. Now `setup` re-prompts on a bad address, `apply`
  hard-fails with a message that names the mistake (subaddress vs integrated vs malformed), and `doctor`
  flags an existing install whose payout address can't be paid.

**Already running an earlier version?** Run `./pithead doctor` — it tells you whether your Monero payout
address is a subaddress (i.e. you've been mining unpaid). Install/upgrade: see
[Getting Started](docs/getting-started.md) and [Updating the stack](docs/operations.md#updating-the-stack).

## [1.0.2] - 2026-06-14

Packaging-only patch — the published images are **byte-identical to 1.0.1**; nothing in the running
stack changed. It exists because releases are immutable, so 1.0.1's install bundle couldn't be corrected
in place. See **[v1.0.1](https://github.com/p2pool-starter-stack/pithead/releases/tag/v1.0.1)** for the
full feature set (P2Pool v4.16, optional clearnet initial sync, dashboard, …).

### Fixed

- **The install bundle is now complete and has a stable download URL.** It ships `config.json.template`
  (the basic quick-start config — just the two payout addresses) alongside the advanced example, and is
  attached as a versionless **`pithead.tar.gz`** so
  `https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz` always
  fetches the latest release. 1.0.1's bundle shipped only the advanced example under a versioned name,
  and — because releases are immutable — could not be fixed in place (#247).

### Install

```sh
curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz
cd pithead && cp config.json.template config.json   # set your Monero + Tari payout addresses
./pithead setup
```

See [Getting Started](docs/getting-started.md) and [Updating the stack](docs/operations.md#updating-the-stack).

## [1.0.1] - 2026-06-13

First installable stable release. **Supersedes 1.0.0**, whose published images were `arm64`-only
(built on an Apple-Silicon host) and whose install bundle was incomplete — it could not run on
x86_64. **No feature changes** from 1.0.0; the fixes are entirely in the release pipeline (correct
`linux/amd64` image builds + a complete install bundle). 1.0.0 is kept as a superseded tombstone at
the bottom.

Bundled, SHA-pinned upstream components: **P2Pool v4.16**, **Monero v0.18.5.0**, **XMRig-proxy
6.26.0**, **Tari/minotari_node v5.3.1-mainnet**, **Caddy 2.11.4**, **docker-socket-proxy v0.4.2**.
The exact image digests for each release ship in the GitHub Release's ingredients manifest.

monerod follows P2Pool v4.16's recommendations where they're compatible with the Tor-first model:
`in-peers=64` (the inbound/open-files cap) is honored exactly, and the optional clearnet initial sync
(#183) runs monerod as a clearnet node should — `out-peers=32` + P2Pool's recommended priority nodes
(`p2pmd.xmrvsbeast.com`, `nodes.hashvault.pro`) for that window. The DNS-based recommendations
(priority hostnames, DNS blocklist/checkpointing) stay off in Tor mode — they leak clearnet DNS
(#161) — with monerod's compiled-in checkpoints as the substitute. `./pithead doctor` now also checks
that the **system clock is NTP-synchronized** (clock skew gets shares/blocks rejected), per P2Pool's
"synchronize your clock before mining" guidance.

### Install / Upgrade

**Install** — download the latest release bundle (pulls the published, tested images) and run setup; see the [quickstart](docs/getting-started.md):

```sh
curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz
cd pithead && cp config.json.template config.json   # set your Monero + Tari payout addresses
./pithead setup
```

**Upgrade** — re-download the bundle over your install (or `git pull` for a source checkout), then `./pithead upgrade`. It **re-renders the generated config itself** — the P2Pool v4.16 monerod settings (`out-peers`, the clearnet-window priority nodes) and the new `doctor` clock check are picked up automatically — so **no separate `./pithead apply` is needed for this release**, and your `config.json` plus preserved secrets (Tor onions, RPC credentials, proxy token) are kept untouched. Run `./pithead apply` only when *you* edit `config.json` — e.g. to opt into the new, default-off [clearnet initial sync](docs/privacy.md). See [`docs/operations.md`](docs/operations.md) for the full lifecycle reference.

### Added

- **Healthchecks.io dead-man's switch** (`healthchecks.ping_url` in `config.json`, **off until
  set**): an optional external liveness monitor. Set a ping URL and the dashboard loop pings it
  every cycle; if the host dies (power loss, kernel panic, NIC death) the pings stop and
  Healthchecks.io alerts you — the one failure mode an in-stack notifier can't report from a dead
  machine. It's a **pure "is the stack alive" signal** — in-stack node-health alerting (a node down
  while the box is up) is out of scope, handled separately by the Telegram alerter (#121). The ping
  **always rides Tor** (the shared bridge SOCKS) so the endpoint sees a Tor exit, not your host IP,
  so paste a Tor-reachable URL (hosted `hc-ping.com`, or a self-hosted onion/public instance). Fails
  silently when offline / Tor down. The URL is the on/off switch and is stored as a secret in the
  owner-only `.env`. See [`docs/monitoring.md`](docs/monitoring.md) (#79).
- **Telegram operator bot — push alerts + on-demand status** (#121, #45): the dashboard can push a
  high-value set of operational alerts to Telegram — a **🚀 "Pithead online"** heartbeat on start,
  **node down / recovered**, **worker offline / back online**, **new worker joined / left**, **sync
  finished**, **data disk filling up**, **dashboard DB write failing**, **no PPLNS share while
  donating to XvB** (raffle wins skipped), **XvB registration rejected / failing**, **hashrate too
  low for the chosen XvB tier**, **a node exposed on clearnet** during initial sync, and **a new
  release being available** — and answer status commands on demand: **`/status`**, **`/info`**
  (version + update availability, Monero DB mode, P2Pool sidechain, and Tor-only/clearnet privacy
  posture), **`/hashrate`**, **`/workers`**, **`/sync`**, **`/system`**, **`/pool`**, **`/xvb`**,
  **`/earnings`**, and **`/help`**. It also pushes a **📅 once-a-day retrospective** at a configurable local time
  (`telegram.daily_summary_time`, default **08:00**) — the last 24h across the fleet: an incident
  roll-up (what went wrong during the day, or an all-clear), 24h hashrate with the P2Pool/XvB split,
  shares found in the day, an estimated daily-earnings figure, and a per-machine 24h breakdown. The Telegram bot appears in the dashboard's
  **network-egress panel** (#170) as a Tor-routed path alongside Healthchecks/XvB/update-check. All
  traffic is **routed over Tor** (the same bridge SOCKS as Healthchecks/XvB), so the bot never
  exposes the host IP to Telegram. Off by default; enable it with a `telegram` block in `config.json` (`enabled`,
  `bot_token`, `chat_id`, per-event `events` toggles, and a `commands.enabled` switch for the
  interactive half). Every alert is **debounced** so a momentary blip won't ping you and you get one
  message per real transition — and each is built by *reusing* what the dashboard already computes:
  worker offline/joined/left keys off the same per-rig **DOWN** status the UI shows, and the disk /
  DB alerts cross the same thresholds as the dashboard's own low-disk and DB-health badges. Commands
  **long-poll** (`getUpdates`) so they need no inbound port and ride the same Tor egress as the
  alerts, are **read-only** (they never change the stack), and only the configured `chat_id` is
  answered — every other update is ignored. The `bot_token` is treated as a secret (owner-only
  `.env`, never logged), and both sends and polling **fail silently** on a Tor-only / offline host.
  Messages are prefixed with the dashboard hostname so multiple stacks can share one chat. Full
  walkthrough — creating a bot, finding your chat id, the command list, and the "one chat, two bots"
  pattern for sharing a chat with the Healthchecks.io monitor (#79) — in
  [`docs/telegram.md`](docs/telegram.md).
- **Host & performance warning badges + alerts** (#104): the top bar now surfaces the persistent
  host conditions `setup` warns about, derived from **live** metrics (so they self-correct): **⚠
  HugePages off** (RandomX capped until reserved), **⚠ Low RAM** (under 16 GB — Tari can OOM during
  sync), and **⚠ No AVX2** (slow RandomX). The first two also push a Telegram alert (`hugepages`,
  `low_ram`) the first time they're seen — unlike the transient edge alerts, a stable bad state
  fires on first detection, and HugePages clears with a recovery ping once a reboot applies them.
  AVX2 is **badge-only** by design: a fixed hardware fact with nothing to act on at runtime doesn't
  warrant a push. The bot's **`/status`** reply now ends with any active warning/error badges (the
  same catalog the top bar draws) or an explicit "✅ No warnings."
- **Hashrate-drop detector — chart markers + `hashrate_loss` alert** (#99): the dashboard now flags a
  **sustained, significant fall** in total fleet hashrate — a rig gone dark, a network cut, a stalled
  miner — separately from the existing "too low for your XvB tier" warning. It tracks a slow moving
  average as the "normal" level (frozen while degraded so an outage can't quietly redefine normal),
  and fires once the total stays below **`dashboard.hashrate_drop_threshold`** percent of that
  baseline for **`dashboard.hashrate_drop_minutes`** (defaults: **50%** for **10 min**), with a
  matching recovery edge. Each edge drops a **diamond marker on the hashrate chart** (amber for the
  drop, green for the recovery; hover for the size) that is **persisted**, so an overnight drop is
  still visible in the morning, and — when Telegram is on — pushes a **`hashrate_loss`** alert and
  counts toward the daily incident roll-up. Both knobs are documented in
  [`docs/configuration.md`](docs/configuration.md); the alert in [`docs/telegram.md`](docs/telegram.md).
- **Optional clearnet initial sync (#183).** A default-off, per-component opt-in
  (`monero.clearnet_initial_sync` / `tari.clearnet_initial_sync`) that lets a node do its **one-time
  initial block download over clearnet** — much faster than over bandwidth-capped Tor circuits, which
  can crawl at near-zero blocks/sec — then return to Tor for all ongoing operation. When on, Monero
  drops its Tor P2P `proxy=` (lowering `out-peers` 48 → 16) **but keeps `tx-proxy=tor`**, so
  transaction-origin privacy is preserved and wallets are never exposed; Tari switches its transport
  to TCP and re-enables the `seeds.tari.com` DNS seed (its onion `peer_seeds` are unreachable without
  Tor). The only exposure is **node-existence** — your host IP is visible to that chain's P2P network
  for the sync window. **Privacy-first by construction:** off by default, a `⚠` disruptive-change
  confirmation on `apply`, a persistent "CLEARNET INITIAL SYNC ACTIVE — node IP exposed" banner in
  `status`/`up`, a `doctor` warning (and a green "Tor-only" check when off), and a matching warning in
  the monerod container logs — so a node is never silently left on clearnet. Exposed in
  `config.advanced.example.json`; documented with a full threat model in `docs/privacy.md`, plus
  `docs/configuration.md`, `docs/getting-started.md`, and `docs/hardware.md`.

- **Automatic clearnet → Tor switch-back once synced (#234).** The clearnet initial sync (above) no
  longer needs a manual flip back. The dashboard watches each chain's sync state and, the first time
  a clearnet node reports fully synced, writes a persistent marker and restarts the daemon — which
  comes back up **Tor-only** and stays there across restarts, `apply`, and reboots (the marker, not
  the flag, is the source of truth, so a synced node can never be silently re-exposed). Monero and
  Tari transition independently. Fail-safe: the marker is persisted before the restart and a failed
  switch is retried, never leaving a node stranded on clearnet; the `status`/`up` banner and `doctor`
  warning clear themselves once a node is genuinely back on Tor. Re-arm a fresh clearnet sync by
  toggling the flag off and on. Mechanism: a shared `clearnet-state` dir (dashboard rw, monerod/tari
  ro) drives the daemon entrypoints' Tor-vs-clearnet decision; pithead always renders the canonical
  Tor config. Closes #234.

- **Dashboard "new release available" badge (#224).** The dashboard periodically checks GitHub for
  the latest Pithead release and, if it's newer than the running version, shows a header badge next to
  the version badge — **"New release vX.Y.Z available ↗"** — linking straight to the release page.
  **Notify-only:** it never updates anything; you upgrade with `./pithead upgrade` on your own terms
  (the one-click upgrade is the separate #59). **On by default** because the check is **routed over
  Tor** (the same bridge SOCKS as the XvB fetch, `socks5h` so the DNS lookup goes through Tor too) —
  GitHub sees a Tor exit, not your IP, so it leaks nothing about you; it's cached hourly and fails
  silently offline. Set `dashboard.check_for_updates: false` to opt out. Documented in
  `docs/configuration.md` + `docs/privacy.md`.

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
  (override via `PITHEAD_REGISTRY` / `PITHEAD_IMAGE_PREFIX`). **Release installs pull the published
  images — no local build:** each compose service carries an `image: …/pithead-<svc>:${STACK_VERSION}`
  ref alongside `build:`, and pithead auto-selects the mode — a source checkout (Dockerfiles present)
  builds locally and tags `:dev` (`--pull never`); a release bundle (no Dockerfiles, just
  `pithead`+`VERSION`+compose+`build/tari/`) resolves `STACK_VERSION` from `VERSION` and pulls
  `:vX.Y.Z` (`--pull missing`). So a release is `./pithead setup` with no compile wait.

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
- **"Raffle Eligible" indicator on the dashboard** (#158). A Hero-band + Simple-Overview box that
  answers "am I set up to both *win* and *collect* an XvB raffle payout?". It reads **Yes** only when
  XvB is on and **both** gates are met: you're donating at least the **donor tier** (XvB's *credited*
  1h **and** 24h averages have cleared the lowest threshold — the same figure as **Current Tier**)
  **and** you hold a P2Pool PPLNS share (XvB's "VIP" gate — without it a win is skipped, you take a
  fail, and you're dropped after the 3rd, regardless of tier). It reads **No** when donating but a gate
  is unmet, and **N/A (XvB off)** when XvB is disabled. A loud **"⚠ No PPLNS share — XvB wins skipped"**
  badge fires for the make-or-break case (donating with no share) so donations aren't wasted.
  Deliberately stricter than XvB's bare "VIP = just a share" so a green Yes is trustworthy; named
  "Raffle Eligible" rather than XvB's "VIP" to avoid colliding with the `vip` *donation tier*.
  Display/observability only — the donation controller already protects the share reserve; this
  surfaces it.
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
  `docs/dev/testing-strategy.md` with a full scenario catalog:
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
  - A generated **test inventory** (`docs/dev/test-inventory.md`, `make test-inventory`) listing
    every test/scenario across all suites, kept honest by a CI drift check.
  - A non-destructive **`--check`** mode for the live harness (assert the box's current state —
    no config change/apply/restore); the safe first run / ongoing health check. Validated with
    a 22/22 green run against a real synced, mining box, which calibrated the harness to trust
    monerod's own sync flag as the readiness gate, and `proxy_workers` for mining liveness
    (`stratum.conns` can read 0 while mining).
  - A developer testing guide (`docs/dev/testing-guide.md`): per-change recipes, conventions, and
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
    `docs/dev/release-server.md` guide (why end-to-end validation needs a dedicated server vs. what
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
  this changelog, and `docs/dev/releasing.md` documenting the release process. The
  GHCR publishing pipeline and `make release` / `pithead release` command are still
  to come (see `docs/dev/releasing.md`).
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

- **Release images are now built for `linux/amd64` (x86_64).** 1.0.0 was built on an Apple-Silicon host
  with a plain `docker build`, so its images were labelled `arm64` and would not run on x86_64 servers
  (`no matching manifest for linux/amd64`) — even though they contained x86_64 binaries. The stack is
  x86_64-only by nature (monero/p2pool/xmrig-proxy ship `linux-x64` binaries, and xmrig-proxy has no
  arm64 build at all), so the pipeline now builds with `buildx --platform linux/amd64` (forcing amd64
  even on an arm64 release host) and the smoke stage fails the release if a pushed image isn't amd64
  (#243, corrected from a multi-arch attempt).
- **The pinned install bundle now ships every config template the compose mounts.** 1.0.0's bundle was
  missing `build/monero/bitmonero.conf.template` — the monero image doesn't bake it in, so a bundle
  `./pithead setup` mounted an empty dir there and monerod couldn't start. `make_bundle` now derives the
  shipped paths from the compose file so no runtime mount can be omitted (#242).
- **Disconnected workers never fell off the "Workers Alive" table (#182 regression).** A worker that
  stopped mining was supposed to linger as **DOWN** for an hour and then drop off, but it never did:
  xmrig-proxy keeps a disconnected rig in its `/workers` list (with a frozen hashrate) for hours, and
  the dashboard's lifecycle dropped the aged-out worker from its internal state while the proxy still
  reported it — so the next poll recreated it with a fresh `last_active`, resetting the 1-hour clock.
  The ghost row flickered off for a single cycle each hour and came back as DOWN indefinitely. The
  lifecycle now keeps an aged-out worker in state as long as the proxy still reports it (preserving
  when it actually went offline), so it falls off once and **stays** off; a genuine reconnect still
  re-adds it fresh. Found during a release-gate coverage audit; covered by a new regression test.

- **Chart Avg windows other than 10m no longer flat-line at 0 on wide ranges (#168 regression).** The
  chart downsampler (used whenever a range has more points than the canvas tier — i.e. the **24h / 1w /
  1mo** ranges) bucket-averaged only the legacy `v` / `v_p2pool` / `v_xvb` columns and silently dropped
  the per-window columns added in #168. So selecting **1 Min / 1 Hr / 12 Hr / 24 Hr** as the **Avg**
  window on those ranges plotted a flat zero line (the y-axis then auto-scaling to the Shares markers),
  even though the underlying data was present — only the default **10 Min** window survived. The
  downsampler now carries **every** per-window hashrate column through, derived from the window map so
  future windows can't regress the same way. Display only.

- **`pithead upgrade` no longer marks an already-deployed stack as "not set up."** Each upgrade
  re-renders `.env`, and `render_env` writes `DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false}`.
  Because `load_preserved_state` doesn't carry that flag (unlike the Tor onions / RPC creds / proxy
  token it preserves), the shell variable was unset and every `upgrade` silently rewrote it to
  `false`. The next `require_deployed` command (`up`, `apply`, or another `upgrade`) then aborted with
  "The stack isn't fully set up yet — run setup first," and a bare `pithead` dropped into setup
  instead of help — forcing a needless, heavyweight `setup` (Tor re-provision, GRUB edit) before every
  upgrade. `upgrade` now re-asserts `DEPLOYMENT_COMPLETED=true` before the render, mirroring `apply`;
  it's only ever reached past `require_deployed`, so the stack is deployed by definition. A new
  black-box test pins the behavior (it fails on the old code).
- **Dashboard "Workers Alive" panel now has the standard gap beneath it.** Every dashboard section is
  a `.card` wrapped in a `.grid`, and `.grid` supplies the consistent 20px bottom margin between
  sections. The Workers Alive table was the one section rendered as a bare `.card` with no `.grid`
  wrapper, so the space between it and the cards below collapsed to zero — out of step with the rest
  of the layout. It's now wrapped in `.grid` like the chart above it, restoring even spacing.
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
  live validation; mining and worker-gating were unaffected — those use monerod's RPC flag
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

## [1.0.0] - 2026-06-13 — superseded

**Superseded by 1.0.1 — do not use.** The published images were `arm64`-only (built on an
Apple-Silicon host) and the install bundle was incomplete, so 1.0.0 never ran on x86_64. Its feature
set is unchanged and is documented under 1.0.1 above. The GitHub release is kept, flagged as
superseded, for transparency.
