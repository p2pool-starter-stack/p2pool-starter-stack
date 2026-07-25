# Dual-distribution plan: one immutable stack, runtime per channel

The architecture decision record for #77 (appliance) and #78 (runtime): how Pithead
ships as a curl-installed Compose stack, a flashable immutable appliance image, and a
git clone — from one release manifest. Ratified 2026-07-22 after four revisions; the
reversal history and evidence are kept in the appendix so future maintainers can see
why bootc, Podman-everywhere, and an apt channel were rejected. Sequencing lives in
the #394 tracker; decision comments are on #77 and #78.

## Decisions

| Question | Decision |
|---|---|
| Appliance foundation | **Debian 13 + Rugix A/B images** (v2 decision, stands). Peer-proven pattern: umbrelOS (Debian + Rugix, crypto-node appliance), HAOS (Buildroot + RAUC). bootc + CentOS Stream rejected — no third-party shipping appliance found on it, rolling base, manual rollback + greenboot bolt-on; full evidence table in the v2 section below. |
| Container runtime | **Quadlet on the appliance, Compose on the DIY channel — #78 outcome (A)** (operator decision, v4; supersedes v3's Podman-everywhere). Appliance: daemonless, each container a systemd service supervised and restarted independently — the idiomatic fit where we own the OS (Debian 13, Podman 5.4.2). DIY: Compose stays — the reach argument is concrete: Quadlet's `Notify=healthy` needs Podman ≥ 5.0, and Ubuntu 24.04 LTS ships 4.9, so Podman-everywhere would exclude the largest current LTS until 2029. Compose runs wherever Docker runs; existing deployments (gouda, prod) never migrate. Cost accepted: two runtime renders, mitigated by generation + parity (below). |
| Runtime definitions | `docker-compose.yml` stays the maintained reference (as today, `.env`-rendered by `pithead`). The appliance adds `pithead render-quadlet`: units generated from `config.json`, never hand-maintained. A parity test derives expectations from the compose file itself and **fails on any compose key it does not recognize** — new compose features cannot silently skip the appliance. |
| Distribution channels | **(1) curl installer (Docker/Compose), (2) flashable appliance image (Podman/Quadlet), (3) git clone (developers).** Package-manager/apt-repo channel dropped. |
| Explicitly rejected (from external review, 2026-07-22) | Kubernetes/Helm/Nomad render backends (speculative; #17 closed as not-planned; TrueNAS publicly retreated from single-node k8s). Repo split into installer/os/core packages (one repo + `os/` dir suffices). Cluster/fleet layer for stack hosts (fleet = RigForge + control channel, already shipped). Config format rename to YAML (`config.json` is already the single declarative source). |
| Rootful vs rootless | **Rootful** (unchanged from v1): `network_mode: host` equivalents, static IPs on `172.28.0.0/24`, loopback-published proxies. Hardening stays at the container level (read_only, cap_drop ALL, no-new-privileges, uid 1000) — transfers as-is. |

## Delivery channels

Positioning: DIY stays the reference implementation ("Docker Compose made easy");
Pithead OS is the appliance product — the TrueNAS/Talos posture for Monero+Tari
infrastructure.

| Channel | Artifact | Runtime | Audience |
|---|---|---|---|
| **curl installer** | `curl -fsSL <url>/install.sh \| bash` — installs/uses Docker CE, fetches the signed release bundle, runs `pithead setup` | Docker Compose (today's stack, unchanged) | homelabs, VPS, existing Docker users |
| **Appliance image** | `pithead-os-vX.Y.Z.img` + Rugix delta update bundles | Podman/Quadlet | zero-Linux-setup users, fleets |
| **git clone** | the repo | Docker Compose | developers, contributors |

Flash target: the image is written to the machine's **internal SSD/NVMe** — running
the stack host from a USB stick is not supported (250+ GB chain, constant writes;
USB flash is too slow and wears out). Two supported paths: write the raw image
directly to the target disk, or boot a USB installer that copies it to an internal
disk after an explicit, destructive disk-selection confirmation (the installer flow is
our tooling — Rugix produces the raw image only). Raw writes are for factory-new
drives only and the docs say so loudly: `dd` replaces the partition table and
destroys an existing `/data` (250+ GB of synced chain). Reinstall on an existing box
goes through the installer, which detects the labeled `/data` partition, preserves
it, and re-mounts it. The miner image (rigforge#1, Alpine
diskless — genuinely stateless, USB-resident is fine there) is out of scope for this
plan and stays in the RigForge repo.

All channels consume the same release manifest: five digest-pinned GHCR images +
`pithead` + rendered Quadlet units + config schema. The appliance embeds the same
digests the installer pulls. Image ownership is per-service, not structural: the
manifest already pins the Tari node from a registry we do not own
(`quay.io/tarilabs`) — a service image moving to another repo or registry changes a
digest line, nothing else.

curl-pipe trust mitigations: the script lives in the repo (reviewable), is served over
HTTPS with a published checksum, and does nothing but verify + delegate to the signed
bundle — the logic stays in `pithead`.

## Runtime architecture

The declarative layer already exists: `config.json` is the single source, `pithead`
renders `.env` + service configs from it. The appliance adds a second render target;
the DIY channel changes nothing.

- **DIY channel: today's stack, byte-identical.** `docker-compose.yml` (env-rendered),
  the `DOCKER-USER` egress firewall, socket proxies, hardening — untouched. gouda and
  prod never migrate.
- **Appliance**: `pithead render-quadlet` writes `.container`/`.network` units from
  `config.json` into `/etc/containers/systemd/` — same pattern as the `.env` render.
  Disabled profiles (local_node, payout_confirm, tari_payout_confirm) get no units.
  The renderer is an internal step, not a user-facing verb: appliance users run the
  same `pithead setup` / config-apply flow as every other channel, and the runtime
  stays invisible.
- Appliance-only systemd needs (watchdog wiring, boot ordering against OS units,
  update hooks) live as static units in `os/overlay/`, not in the compose file — the
  runtime definition maps container semantics only. If a single container ever needs
  a systemd-only knob, the escape hatch is a native drop-in
  (`<service>.container.d/override.conf`) beside the generated unit — no
  service-model abstraction layer until a second real divergence exists.
- Compose-semantics mapping — **spike-proven rules** (each bought with an actual
  failure; evidence on #78, fixtures in `os/quadlet/`):
  1. `depends_on: service_healthy` → `Notify=healthy` + `After=` + `Requires=` +
     `TimeoutStartSec=infinity`. A finite start timeout KILLS a not-yet-healthy
     service and restarts it — compose's `start_period` never kills; p2pool's first
     sidechain sync hit exactly that kill/restart loop.
  2. Plain `depends_on` → `After=` + `Wants=`, never `Requires=` — differential
     proven: after `systemctl stop p2pool`, xmrig-proxy stays running (compose
     parity); `Requires=` would stop-couple them.
  3. Compose tmpfs `uid=`/`gid=` options are rejected by podman's `Tmpfs=` —
     map to `mode=1777` (or `Mount=` with chown).
  4. Healthchecks → `HealthCmd=`/`HealthInterval=`/`HealthRetries=`/
     `HealthStartPeriod=`; `--remove-orphans` → obsolete, systemd owns lifecycle.
  5. Tooling uses stop-then-start: `systemctl restart` racing an in-flight start job
     fails spuriously.
- Docker-API consumers (dashboard start/stop/logs via the two socket proxies) point at
  Podman's Docker-compat socket on the appliance; the four endpoints used
  (`GET containers/json`, `GET logs`, `POST start`, `POST stop`) are spike-verified.
- The egress firewall exists in two runtime variants: `DOCKER-USER` (DIY, exists) and
  a netavark equivalent (appliance, the largest port item — spike item 1). Both stay
  covered by the same stack-tier tests.
- Deliberately NOT generating `docker-compose.yml` from config (the "generate both
  backends" advice): the compose file stays the maintained reference — full generation
  is a large refactor whose only payoff is hypothetical third backends (k8s/Helm),
  which this plan rejects. The parity test is the drift lock instead.

## Runtime port surface

Container-engine independence here means a short, mapped port list — not an
abstraction layer (see the rejected service-model row above). Three contracts carry
all application logic, and all three are engine-neutral:

1. **OCI images**, pulled by digest from the release manifest — first-party or
   upstream alike (the Tari node already ships from a foreign registry).
2. **Four endpoints of the standard container API**, reached only through the
   allowlisted socket proxies: `GET /containers/{name}/json`,
   `GET /containers/{id}/logs`, `POST .../start`, `POST .../stop`. The dashboard uses
   no engine SDK — raw HTTP against the proxy socket.
3. **`config.json` renders every runtime file** (`.env` + compose on DIY, Quadlet
   units on the appliance). No hand-edited runtime artifact exists.

The engine-specific residue — the entire cost of supporting a runtime — is four
items: the egress-firewall implementation, `doctor`'s host checks, the render
target, and the socket the proxies mount. Supporting engine N+1 is a bounded port of
that list; nothing else in the stack knows which engine is underneath.

Guardrails that keep the surface from growing silently, all structural: a new API
endpoint requires a visible change to the socket-proxy allowlist (a compose diff);
the parity test fails on unrecognized compose keys; config rendering is the only
path to runtime files. Review rule: a PR that grows the port surface updates this
section in the same change.

## Testing plan

No new model — every dual-distribution behaviour slots into the existing four-tier
map ([`testing-strategy.md`](testing-strategy.md)), each tested once at the lowest
tier that proves it honestly. The scenario catalog grows two sections (renderer,
appliance) when the code lands.

**The parity test (tier 1, every PR, docker-free).** Text-to-text: parse
`docker-compose.yml` (the reference), derive per-service expectations — image,
mounts, env keys, healthcheck command/interval, `cap_drop`/`read_only`/
`no-new-privileges`, static IP, tmpfs, memory limits, profile membership — and
assert the rendered `.container`/`.network` units carry the same values. The phase 0
hand-written units are the first fixtures. The lock is the closed set: a compose key
the deriver does not recognize fails the test, so a new compose feature cannot ship
without a decision about its Quadlet mapping. What parity cannot prove is
*behavioural* equivalence — `Notify=healthy` ordering vs `depends_on:
service_healthy` — which belongs to tiers 3 and 4, not to text comparison.

**Tier 1 (unit) additions:** `render-quadlet` output shapes; profile gating (a
disabled profile renders no units); `install.sh` distro/version-floor refusal
(stubbed); `uninstall`'s kept-vs-removed listing; `doctor --json` schema, identical
key set on both engines; the migration-deadlock decision (`data_migration` flag →
chain units withheld pre-commit).

**Tier 3 (mini-stack), Podman flavour:** the existing control-plane suite — real
dashboard + socket proxies moving real containers — runs a second lane against
rootful Podman's compat socket on Debian 13. This is where the four API endpoints
and proxy allowlists stay proven permanently after the spike proves them once. Same
tests, second engine; no duplicated logic.

**Tier 4 (live matrix), appliance additions:** boot the flashed image on a #54 bench
box; a good A/B update commits (gate consumes `doctor --json`); a deliberately
broken update falls back; a `data_migration`-flagged update provably withholds chain
services until commit; netavark egress verification mirrors the existing Tor-leak
checks; first-boot pre-seed consumed and wizard gate honoured (token before any
form); config-reset and factory-reset tiers; the 7-day unattended soak (the phase 2
exit bar). Installer smoke: `install.sh` on clean Debian 13 and Ubuntu 26.04 VMs
joins the release-smoke checklist.

**Release gate:** the existing mandate (targeted e2e with a borrowed rig before
every cut) extends, not changes — the `os-image` lane adds the bench boot-test per
cut, and the installer smoke rides the same checklist.

## Appliance architecture (unchanged from v2, runtime swapped)

- Minimal Debian 13, read-only root, overlay discarded each boot.
- Rugix A/B slots; new slot boots provisionally; **the commit gate is `pithead
  doctor --json`** — it already exits non-zero only on critical failures and checks
  containers, Tor, NTP sync, disk, hugepages (`pithead:1010`). One rule
  the gate must hold: commit on "services up and progressing", never "chain synced" —
  initial sync takes days, and the #718 scan-grace lesson (healthy-during-long-scan
  markers) applies to the commit window too. No commit or failed boot → automatic
  fallback.
- **Migration-deadlock rule** (closes a flaw in earlier drafts: if forward-only DB
  migrations ran before the commit decision, a failed doctor check would leave the
  box unable to commit *or* fall back). Releases carry a `data_migration` manifest
  flag; on flagged updates the chain services (monerod/tari — the only holders of
  irreversible lmdb migrations) **start only after the slot commits**. The gate
  judges everything else — OS, Tor, dashboard, networking. Fallback therefore only
  ever happens before any migration ran; a post-commit migration failure is fixed
  forward on a known-good OS. The last-committed OS version is stored on `/data`
  beside the chain data it matches.
- **Updates fetch over Tor**, like the stack's existing release checks already do
  (`pithead:5581` uses `--socks5-hostname`; the dashboard's GitHub
  client rides the same proxy) — the appliance must not leak "this IP runs pithead"
  to the ISP on every update poll. Clearnet fallback is a manual flag, same posture
  as `clearnet_initial_sync`. Delta updates over HTTP range requests — GitHub
  Releases hosts them, no update server. Tor circuits churn on long transfers (our
  own e2e history shows Tor-timing flakes), so the update client must resume
  partial downloads and back off with retries — chunked range requests make this
  natural; a failed poll or download delays the update and changes nothing else.
- **Time sync ships enabled** (systemd-timesyncd active in the image, not just
  `doctor`'s warn-if-unsynced): Tor refuses to bootstrap on a skewed clock and the
  appliance has no operator to fix it. First boot on an RTC-less/dead-CMOS box must
  sync time *before* starting Tor — a hard ordering dependency in the firstboot
  units — with an htpdate-style HTTP-header fallback for networks that block
  NTP/UDP 123: a box that thinks it is 1970 can neither build Tor circuits nor
  validate TLS, so the time step must succeed by some path before anything else.
- **Persistent journald on `/data`** with a size cap: read-only root defaults journald
  to volatile, which would lose every OS-level log on reboot — unacceptable for
  debugging a headless box. Container logs already rotate (json-file, 10m×3,
  `docker-compose.yml:7`) and live on `/data` with the rest of
  the container state.
- Data partition found by label, everything stateful under `/data`, with
  `/var/lib/containers` bind-mounted onto it behind a systemd mount guard (Podman
  must not start if the mount is absent — the Umbrel disk-fill field failure, adapted).
- On OS version change: stop/remove containers before handoff (engine-version skew
  against shared state); images kept, units re-rendered.
- **Two-tier reset**, because a full wipe costs days of chain resync: (1) config
  reset — delete `config.json` + secrets, re-enter the first-boot wizard, chain data
  kept; (2) factory reset — `rugix-ctrl state reset`, everything wiped. Reflash keeps
  data; the wizard offers tier 1 before tier 2.
- Hugepage reservation baked in at boot — **load-bearing, not perf polish** (spike
  finding): the RandomX dataset (~2.1 GiB) lives in hugetlbfs outside the memory
  cgroup only when pages are reserved; unreserved, it falls to anon memory and
  p2pool OOM-loops at any cap ≤ 2g ("Dataset init invoked oom-killer"). Every memory
  cap in the stack assumes the reservation, so the image reserves before containers
  start, and `doctor`'s hugepages check is a hard prerequisite on the appliance.
  Plus CPU governor, sysctls; hardware + systemd watchdog.
- Rugix bus-factor-1 risk stands, with the v2 mitigations: updater-agnostic rootfs
  recipe (Docker-exported tarball) keeping RAUC as escape hatch; ask Silitics/Umbrel
  before phase 2 investment.

## Phases

### Phase 0 — runtime spike (#78, the gate)

On a Debian 13 box (podman 5.4.2), hand-write Quadlet units for the full stack and
bring it up rootful. Verify, in order of risk:

1. netavark egress-firewall port (prototype the `DOCKER-USER` equivalent)
2. socket proxies + the four dashboard endpoints against the compat socket
3. `Notify=healthy` startup ordering vs today's compose behavior, service by service
4. static IPs, host-network dashboard/caddy, loopback-published proxies

The hand-written units become the fixtures `pithead`'s renderer must reproduce.
Exit: #78 closed with outcome (A) + spike notes, with binding go/no-go consequences:

| Spike result | Consequence |
|---|---|
| netavark firewall port fails (no fail-closed equivalent) | appliance channel blocked — redesign or stop; DIY unaffected |
| `Notify=healthy` ordering diverges in a way that breaks the dashboard | redesign the mapping before phase 1; no renderer until resolved |
| socket-proxy endpoint gaps | each gap documented as a degraded appliance feature — accepted explicitly or fixed, never discovered later |
| all four verified | proceed to phase 1 |

**Outcome (2026-07-24): all four verified — #78 closed as (A).** The firewall port is
an independent `inet pithead_egress` nftables table at forward priority −5 (no chain
ownership shared with netavark; survives its reprogramming). The unmodified tecnativa
proxies serve all four endpoints from the Podman compat socket, and the read proxy
still refuses writes (403). The ordering matrix confirmed `tor < p2pool <
xmrig-proxy` on `ActiveEnterTimestampMonotonic` with each edge gated on health. The
full seven-unit stack ran end-to-end against remote nodes, including the dashboard's
sync-gate driving containers through the control proxy. The degraded-features list is
empty. Fixtures: `os/quadlet/`; evidence trail: the three verdict comments on #78.

### Phase 1 — curl installer + Quadlet renderer

- `install.sh`: distro check → Docker CE install (or use existing) → fetch + verify
  signed bundle → `pithead setup`. Replaces the tarball-by-hand DIY instructions;
  today's stack, nothing else changes.
- `pithead uninstall` (DIY channel only — on the appliance the equivalent is the
  reset tiers): stop + remove containers, images, rendered files; print what is kept
  (data dirs, config) and how to delete it. No such command exists today — `down`
  only stops containers — and a clean exit path is an adoption factor: people
  install what they know they can remove.
- `pithead support-bundle` + `pithead doctor --json` land here, not phase 2: most
  support is log-collection, and the bundle is cheap — doctor output, journald
  excerpt, container logs, and config redacted through the control channel's existing
  masking machinery (`/control/masked`). `doctor --json` doubles as the
  machine-readable input the appliance commit gate consumes in phase 2; durations and
  restart counts ride the #196 telemetry tables that already exist — no new metrics
  system.
- `pithead render-quadlet` (mirrors the `.env` render path); output matches the
  phase 0 fixtures; parity test fails on unrecognized compose keys.
- cosign signing becomes mandatory in `release.sh`; every channel verifies on consume.

### Phase 2 — appliance productionization

**Minimum shippable appliance — the scope guard**: boots, updates atomically, rolls
back on failure, runs the stack reliably. "Reliably" is measured, not felt: a 7-day
unattended soak on a #54 bench box with zero manual interventions, plus the
fault-injection rollback demo below. That is the phase 2 exit bar; everything else
in this phase can slip a release without slipping the milestone.

Rugix Bakery project (x86_64 EFI, rootfs from a Docker-exported tarball), data
partition + labeled mounts + mount guards, `pithead` ↔ `rugix-ctrl` commit glue
(consuming `doctor --json`), clean-state-on-version-change, factory reset, watchdog.
A/B + rollback demo proven on a #54 bench box: apply a good update (commits), apply a
deliberately broken one (falls back).

`doctor` grows engine-aware host checks here, before it becomes the commit gate.
Three of its checks are Docker-shaped — daemon reachable, `docker` group
membership, `docker.service`/`docker.socket` boot persistence — and all three
misreport under Podman/systemd. The appliance variants (engine reachable via its
socket-activated API, Quadlet unit state, `podman.socket` enabled) land behind the
same check names and the same `--json` shape, so the commit gate and support bundle
read identically on both channels.

The release manifest grows machine-readable compatibility fields —
`minimum_os_version`, `db_schema`, `data_migration` — the contract between channels.
Together with the last-committed version stored on `/data`, these drive the
migration-deadlock rule above: fallback is always safe because flagged chain
services never start pre-commit — the same minimum-version pattern the
worker-upgrade contract already uses (rig gate ≥ v1.11.2).

**DIY → appliance migration is a supported, documented path**: `pithead backup` on
the old box → flash the appliance → restore in the wizard. Chains are excluded by
default and resync (or are copied manually, best-effort documented) — the backup
already covers exactly the right set. Auto-update policy: default-on with
commit-or-revert protection, maintenance-window setting, and `pithead backup` run
before apply. **Backup/restore is not new work**: `pithead backup`/`restore` already
exist — encrypted by default (AES-256 + PBKDF2), covering config.json, .env,
Caddyfile, Tor onion keys, and the dashboard database, with chains excluded unless
`--with-chains` (`pithead:1149`). The appliance surfaces the existing
commands as dashboard buttons (export to a download / restore from an upload), so
"fresh flash → restore → done" is a supported recovery path with one backup format
across all channels.

### Phase 3 — the pre-sync setup wizard (both channels)

Revised 2026-07-24 (operator decisions): the wizard is not appliance-only — it is the
**default setup experience for both channels**, and it runs on **plain HTTP :80 with a
one-time token**, not self-signed TLS. Nobody is forced through a CLI.

One implementation, `pithead firstboot-wizard`, same trust shape as the #33 control
channel — the container asks, the host applies:

- **DIY**: `install.sh` → host gates → extract → wizard container starts on :80, the
  terminal prints the URL + token → browser configures → the host runs
  `pithead setup` → handoff to the real stack. The CLI wizard stays via `--cli`, and
  a pre-seeded `config.json` skips the wizard entirely (headless, fleets).
- **Appliance**: the firstboot systemd unit runs the same command; the console prints
  the same URL + token. `config.json` on the config partition pre-seeds and skips.

The flashed-image user's path: flash → plug in ethernet → power on → browse to
`http://pithead.local` (mDNS; the console and the router's device list carry the IP
as fallbacks) → type the token → the #33 config form in core-keys mode (wallets,
node local/remote, pool, and the existing clearnet-IBD question — "private over Tor
(days) or faster over clearnet (hours)", the biggest first-day adoption factor) →
progress screen while the host applies → auto-redirect to the dashboard, now behind
caddy + auth, watching the sync it just chose. Configured before the first block
syncs.

**Security posture (decided, plain HTTP + token):** TLS-warning friction repels
exactly the audience the wizard exists for, so the window relies on secret
minimization instead:

- Only-when-unprovisioned, and the window closes permanently at handoff.
- The token is **short and human-typable** — 6 characters from an unambiguous
  alphabet (no 0/O/1/l), e.g. `pit-X7KM2Q`, printed on the console/terminal. It is
  used once to reach the form; attempts are throttled and N failures mint a fresh
  token. No form field renders before it.
- The wizard collects wallet **addresses** and shape choices only. The dashboard
  password is generated host-side and **displayed once** at handoff; view keys and
  other secrets are day-2 entries through the authenticated HTTPS dashboard.
- Residual, stated plainly: for the wizard's minutes-long window, a device already
  sniffing the LAN could read the submitted addresses and the displayed password —
  the same trusted-LAN model the node feeds document. Fleets and the cautious
  pre-seed `config.json` and never open the window.

The wizard is cheap by construction: the form is `configlogic.mjs` +
`config.core-keys.json` (both exist, both already drive the dashboard's config
view), the apply path is the existing `ensure_config_exists` + `setup`, the wizard
container is the dashboard image in a flag mode, and the host-side wait-then-apply
loop lives in `pithead`. `install.sh`'s last step becomes the wizard handoff instead
of `exec ./pithead setup`.

Lockout insurance: physical console login always works (the appliance has no SSH by
default; SSH is a wizard opt-in) — a broken wizard must never brick the box.

### Phase 4 — release pipeline + channels

`release.sh` grows an `os-image` lane (Bakery build → full + delta bundles →
checksum + sign → GitHub Release) alongside the bundle lane the installer consumes.
Release channels: stable + beta (tag convention). Tier-4 validation: boot-test the
image per cut on the #54 matrix, same mandate as the targeted e2e.

## Support policy

- Appliance base: Debian 13 through its LTS window (mid-2030); rebase to Debian 14
  planned, not emergency.
- Minimum hardware spec, stated in `docs/appliance.md` and enforced by the installer:
  amd64 (hard-fail — no arm64 xmrig-proxy build); AVX2 **warned, never required** —
  RandomX runs without it and `doctor` says so, and a hard gate would turn away the
  repurposed hardware this stack is often deployed on (the project's own release box
  is a pre-AVX Westmere Xeon that mines fine). RAM sized to the compose memory caps
  (monerod 6g + Tari 7.5g + the rest — publish the sum per mode), internal SSD/NVMe
  with headroom over current chain size. `pithead doctor` already checks AVX2,
  hugepages, and free disk; the installer runs the same checks before writing
  anything, and the booted image repeats the AVX2 check with a clear console error —
  never a silent crash on unsupported hardware.
- DIY: any amd64 distro Docker CE supports (Ubuntu 24.04 included — no Podman floor
  on this channel).
- Upgrade path: N→N+1 always; skip-version best-effort.
- Two channels (stable/beta); appliance supported on the #54-validated matrix,
  best-effort elsewhere.

## Repo outline (target state)

```
pithead/
├── pithead                     # brain for all channels
│                               #   + render-quadlet (phase 1)
│                               #   + unprovisioned mode (phase 3)
│                               #   + support-bundle, rugix commit glue (phase 2)
├── docker-compose.yml          # DIY runtime definition + the parity reference (stays)
├── build/                      # service images — unchanged
│   └── dashboard/              #   + first-boot wizard mode for the #33 form (phase 3)
├── install.sh                  # NEW — the curl channel (phase 1)
├── os/                         # NEW — the appliance (phases 0, 2, 3)
│   ├── bakery/                 # Rugix Bakery project: layers, recipes, x86 EFI target
│   ├── rootfs/                 # Dockerfile assembling the OS rootfs tarball
│   │                           #   (updater-agnostic — the RAUC escape hatch)
│   ├── quadlet/                # phase 0 hand-written reference units → renderer fixtures
│   ├── overlay/                # fstab, mount guards, watchdog, firstboot units
│   └── README.md
├── scripts/
│   └── release.sh              # + os-image lane, cosign mandatory
├── docs/
│   ├── install.md              # curl-install instructions (user doc)
│   ├── appliance.md            # flash, provision, update, rollback, factory reset
│   └── dev/                    # this plan (dual-distribution-plan.md)
└── tests/
    └── os/                     # boot/update/rollback harness on the #54 matrix
```

## Base distribution — evaluated 2026-07-24, Debian 13 confirmed

Re-opened deliberately (the earlier choice arrived by peer-group convergence, which is
weak evidence on its own). One correction first: the v2 review rejected **CentOS
Stream** for being a rolling upstream whose mirrors are deleted at EOL. That does not
transfer to Rocky/AlmaLinux, which are stable point-release rebuilds — they deserved
their own look.

**The finding that decides it, measured rather than argued:** `rockylinux:10` refuses
to start on this project's own release box —
`Fatal glibc error: CPU does not support x86-64-v3`. RHEL 10 raised the
microarchitecture baseline to v3 (Haswell, 2013+). Gouda is a Xeon X5690 with no AVX
at all, and it mines today. A stack routinely deployed on repurposed hardware cannot
adopt a base that excludes that hardware at the libc level.

| Base | Active support | Security tail | CPU floor | Verdict |
|---|---|---|---|---|
| **Debian 13** | Aug 2028 | LTS Jun 2030 (+ELTS) | baseline amd64 | **chosen** |
| Rocky 10 | May 2030 | May 2035 | x86-64-v3 | disqualified — excludes target hardware |
| Rocky 9 | May 2027 | May 2032 | x86-64-v2 | viable fallback, *shorter active support than Debian 13* |
| Ubuntu 26.04 LTS | 2031 | 2036 (Pro) | baseline | no advantage over Debian; adds a vendor dependency |
| Alpine | — | — | — | out: no systemd, so Quadlet cannot exist |
| Buildroot | n/a | n/a | baseline | HAOS's path; we would own the whole userland with a two-person team |

Rocky's headline ten-year window exists only on Rocky 10, which we cannot use; Rocky 9
avoids the CPU floor but expires sooner than Debian 13. Recorded in Rocky's favour, so
the fallback is honest: Rocky 9 ships podman 5.8.2 against Debian 13's 5.4.2, Quadlet
is Red Hat's own technology tested there first, and SELinux + Podman is the
reference-grade hardening pairing. If Quadlet ever misbehaves in a way Debian's
packaging causes, Rocky 9 is the escape hatch.

**openSUSE MicroOS** is deliberately *not* in this table: it replaces the update
architecture (btrfs snapshots + `transactional-update` instead of A/B slots), so it
belongs in the bake-off below as a candidate, not in the base-distro comparison.

## How an update actually works, per option — and what the operator sees

The mechanics differ far less than the arguments about them suggest: every A/B option
gives the operator the same shape — one click, a download, a reboot, and an automatic
return to the working system if the new one misbehaves. What genuinely differs is
**download size**, **who owns the boot-path code**, and **who patches the userland**.

One correction that keeps recurring: **"Yocto + Debian" is not an option.** Yocto
compiles its own distribution from source recipes; it replaces Debian rather than
building it. The real third option is Yocto + `meta-rauc` *instead of* Debian.

### The options

**A. Rugix + Debian** *(built, boots, wizard serves 3/3)*
`rugix-ctrl update install` writes the spare slot, reboots into it provisionally, and
`pithead doctor --json` gates `rugix-ctrl system commit`. No commit, or a failed boot,
and the box returns to the old slot by itself. Delta updates ride plain HTTP range
requests — no update server, GitHub Releases is enough.

**B. RAUC + Debian** *(built, boots; the current recommendation)*
`rauc install` writes the whole slot image and arms a GRUB try-counter; the new system
boots, and `rauc status mark-good` commits. If it never marks itself good, GRUB's
counter expires and the previous slot boots. Bundles must be X.509-signed — RAUC
refuses unsigned ones, which suits our mandatory-signing posture.

**C. Yocto + meta-rauc** *(not built)*
Runtime behaviour is identical to B, because it *is* RAUC. Everything that differs is
on our side of the fence: `meta-rauc` maintains the bootloader integration we would
otherwise own, at the price of owning the entire userland instead.

**D. systemd-sysupdate + Debian** *(not built)*
`systemd-sysupdate` fetches a versioned partition image from a plain HTTP directory
and writes the spare partition; `systemd-boot` counts boot attempts and
`systemd-bless-boot` commits. Best bus factor of any option — it is systemd itself —
but it means dropping GRUB, and full-root A/B is less field-proven here than RAUC.

**E. openSUSE MicroOS / `transactional-update`** *(not built)*
Snapshots rather than slots: update inside a new btrfs snapshot, reboot into it, roll
back by booting the previous one. Downloads are small because it updates *packages*.
That is also its disqualifier for an appliance: the box assembles its own state from a
package archive, so we no longer ship exactly what we tested.

**F. The DIY channel today** *(shipping)*
`pithead upgrade` pulls new container images and restarts them. No reboot, no OS
rollback — the operator owns the host. This stays as-is; the appliance exists precisely
because not everyone wants that job.

### What the operator actually experiences

| | Download | Downtime | On failure | Bandwidth over Tor |
|---|---|---|---|---|
| A. Rugix | delta, tens of MB | one reboot (~1–2 min) + sidechain resync | automatic fallback, old version keeps running | minutes |
| B. RAUC | **full slot image, ~700 MB–1 GB** unless adaptive updates are implemented | same | same (GRUB try-counter) | **tens of minutes** |
| C. Yocto + RAUC | full image, but a minimal userland — a few hundred MB | same | same | shorter than B |
| D. sysupdate | full partition image | same | same (boot counting) | as B |
| E. MicroOS | package deltas, small | same | boot previous snapshot | minutes |
| F. DIY | container layers | no reboot; containers restart | none for the OS | minutes |

**The one user-visible difference that matters between the live candidates is download
size.** Updates are fetched over Tor by default, so Rugix's block-level deltas (tens of
MB) versus RAUC's full slot image (most of a gigabyte) is the difference between a
few minutes and most of an hour on a home connection. RAUC has an equivalent —
"adaptive updates", which fetch only the blocks that differ — but it is extra work we
have not done. **If RAUC is adopted, implementing adaptive updates is not optional
polish; it is what keeps the update experience acceptable over Tor.**

Everything else the operator sees is the same across A–D: the dashboard offers the
update, the box reboots once, mining resumes, and a bad release un-installs itself
without anyone driving to the machine.

## The updater bake-off — decision procedure

The A/B updater is the one component whose failures land in the field, unattended, on
someone's income. It is therefore chosen by **measurement against a shared rootfs**,
not by argument. Rugix booting first is an accident of order, not a decision: it earns
no default status, and no further updater-specific work lands until this runs.

**Why a bake-off is affordable at all:** the rootfs is updater-agnostic by design
(`os/rootfs/Containerfile` contains zero updater knowledge), so each candidate consumes
the *same* exported tarball. The candidate-specific surface is small — Rugix is ~150
lines of TOML in `os/bakery/` plus ~30 lines of harness commands.

**Candidates** (each builds a bootable image from the shared tarball):

| | Updater | Image assembly | Notes |
|---|---|---|---|
| A | Rugix Ctrl | Rugix Bakery | integrated state/persist, factory reset, delta-over-HTTP |
| B | RAUC | ours (script: GPT + mkfs + populate + GRUB boot-counting env) | mature, but updater only — we own assembly, persist, reset |
| C | systemd-sysupdate | ours + `systemd-boot` boot counting | no third-party updater; needs moving off GRUB |
| D | openSUSE MicroOS `transactional-update` | the distro's own | snapshots instead of A/B slots — changes the base too, so it competes on both axes |

**Packaging couples the updater to the base, and the bake-off must price that:** Rugix
ships `rugix-ctrl` as `.deb` and `.apk` only (our build installs
`rugix-ctrl-gnu_1.0.0_amd64.deb`), so candidate A is Debian/Alpine-shaped and would
need a hand-rolled binary install on an RPM base. RAUC is packaged for Debian but
built from source on RHEL-family. Only sysupdate is base-neutral. A candidate that
wins on reliability but forces a base we rejected has not actually won — score it
with that cost included.

**The battery — identical for every candidate**, run by `tests/os/run.sh`:

1. Cold boot to multi-user on the #54 bench VM.
2. Install a v2 bundle → boots the spare slot.
3. Reboot **without** commit → must fall back to v1.
4. Install + commit → must persist across reboot.
5. **Fault injection:** `virsh destroy` mid-write and mid-commit, ×3 each → must land
   on a bootable slot every time, never a brick. This is the field-critical case and
   the one the maturity argument is really about.
6. Factory reset and config-only reset behave as specified.
7. Recorded numbers: update bundle size, delta size on a one-file change, apply
   duration, image build duration.

**Scoring — weights fixed here, before any results, so the outcome cannot be
rationalised afterwards:**

| Criterion | Weight | How it is judged |
|---|---|---|
| Field reliability | 40% | battery items 3–5; any brick in fault injection is disqualifying, not deducted |
| Longevity / bus factor | 25% | maintainers, release cadence, independent production users, doc + community depth |
| Integration surface we own | 20% | lines and concepts we maintain ourselves; every line we own is a line we must debug at 3am |
| Operational ergonomics | 15% | delta size, apply time, clarity of failure messages, factory-reset support |

**Exit:** a written verdict in this document naming the winner, its score against each
criterion, and what would reverse it. Ties go to the candidate with the smaller surface
we own. Only then does updater-specific work resume.

**What is already known, entered as evidence rather than conclusion:** Rugix completed
bootstrapping and booted to multi-user on generic x86 EFI (2026-07-24). Of the 13 build
iterations that took, ~7 were our own bugs, ~3 generic image-building reality, and ~3
Rugix documentation gaps that required reading umbrelOS's source — the last group is
the honest maturity signal. RAUC and sysupdate have not yet been built once, so they
carry an unknown integration cost that only the bake-off can price.

### Verdict (2026-07-25): RAUC, on stability grounds — conditional on fault injection

Both candidates were built against the same rootfs tarball and booted on the bench.
The operator's stated goal is platform stability above all else, and that is what the
evidence below is weighed against.

**Why RAUC wins the criterion that matters most.** Its test suite targets precisely the
failure that bricks an unattended miner — `bootchooser.c`, `boot_switch.c`,
`boot_raw_fallback.c`, plus AddressSanitizer suppressions — and ten years of field
exposure means the ugly cases (power cut mid-write, corrupted bootloader env) have
already been hit by other people's fleets. Bus factor is the decisive structural fact:
**396 of Rugix's 400 recent commits come from one person** (two addresses, same human),
against 102 contributors for RAUC whose top two are employed to maintain it. RAUC is
also packaged in Debian, so it inherits distro security updates rather than our
vendoring. Finally, Rugix repartitions *at first boot on the customer's device* — which
panicked on this bench when the disk was too small — while the RAUC image is
partitioned at build time, where failures land at our desk instead.

**What this costs us, recorded so it is not forgotten.** Rugix is 62 lines of config;
the RAUC candidate is 154 lines we own, and it still lacks factory reset and
grow-to-disk. Worse for stability specifically: **the rollback logic moves into our own
46-line GRUB script** (`_OK`/`_TRY` counters), where Rugix kept it inside a tested
binary. Switching therefore *raises* our risk in exactly the place that matters, which
is why the decision is conditional: **RAUC is adopted only once it passes the
fault-injection battery** (destroy mid-write and mid-commit, ×3 each). The Rugix
candidate stays in-tree until then — it costs 62 lines and is currently the only one
demonstrably reaching a working appliance.

**On RAUC's own advice to use Yocto, Buildroot or PTXdist — we decline, deliberately.**
That guidance targets classic embedded: fixed hardware, a minimal from-source userland,
no package manager. Our context is generic x86-64 PCs running containers, maintained by
two people. Two facts decide it: **Buildroot has no `podman` package** (it ships
`docker`, `conmon`, `crun`), so the appliance's chosen runtime would become ours to
package and maintain; and a from-source userland makes **us** the security team for
every CVE in systemd, openssl and podman, where Debian gives us one for free. For an
appliance meant to run unattended for years, outsourcing CVE maintenance is a stability
feature, not a convenience. If the hand-rolled assembly later proves fiddly, the
Debian-native path is **mkosi** (systemd project, builds Debian disk images via
systemd-repart) — a maintained builder rather than a whole embedded build system.

Corrections this research forced on earlier claims in this document: RAUC *does* have
delta-style updates ("adaptive updates"), it *does* document persistence patterns
(shared/redundant data partitions), and an earlier "246 vs 2 test files" reading was
wrong — Rugix is Rust with inline tests (183 `#[test]` functions), on core sizes that
are near-identical (33.6k C vs 34.8k Rust).

### OTA findings so far (candidate A, and mostly base-independent)

Facts the first working image produced. The first four apply to *any* A/B updater on a
docker-exported rootfs, so they are prerequisites for every candidate, not Rugix quirks:

1. **First boot repartitions, so the disk must be big enough for the whole layout** —
   256M EFI + 2×512M boot + 2×8 GiB system + data ≈ 18 GiB minimum. Below it,
   bootstrapping aborts (`insufficient space, cannot add partition 5`) and the box
   panics rather than degrading. This is the appliance's real minimum-disk figure and
   belongs in `docs/appliance.md`; the installer should check it before writing.
2. **The rootfs must carry the partitioning userland it shells out to** — `e2fsprogs`,
   `dosfstools`, `fdisk`, `parted`. `debian-slim` ships none of them, and the updater
   runs as init before any of our services exist, so a missing `mkfs.ext4` is a panic,
   not an error message.
3. **`/.dockerenv` must be removed** or systemd refuses to run as PID 1 (it believes it
   is in a container). Every docker-export base hits this.
4. **The pseudo-filesystem mount points must be recreated** after extracting the
   exported tarball — `docker export` omits `/dev`, `/proc`, `/sys`, `/run`, `/tmp`.
5. **Debugging rule, worth more than any single fix:** `/dev/console` is whichever
   `console=` came **last** on the kernel cmdline, and `loglevel=3` suppresses the
   kernel banner from it entirely. Kernel messages reaching a serial capture prove
   nothing about whether userspace output does. Eleven rebuilds looked identical and
   silent for this reason alone; swapping the order made the updater state its exact
   error on the first try. Any candidate that appears to fail silently gets this check
   before anything else.

Consequences already applied: the wizard announces its URL and token on *every* console
device rather than `/dev/console` alone, and the tier-4 harness resizes the scratch
disk before first boot with the reason recorded beside it.

## Risk register

1. **netavark egress-firewall port** (appliance only) — the technical unknown that
   gates the runtime decision; phase 0 item 1.
2. **Rugix bus factor / long-term support** — one maintainer at one small company
   (1112 commits vs 4 for the next contributor), 1.0 five months old, and umbrelOS —
   its flagship user — still pins Bakery v0.9.1. RAUC is the mature alternative
   (2015, two Pengutronix maintainers, Home Assistant OS's x86-64 fleet), but it is
   *only* an updater: no image builder, no state/persist model, no factory reset, no
   delta-over-HTTP. Choosing it means hand-building the image assembly Bakery does
   for us. **Neither is chosen yet** — the updater bake-off above settles it by
   measurement, and no further updater-specific work lands until it has run.
3. **Dual-render drift** — two runtime definitions (compose reference + generated
   Quadlet). Locks: units are generated, never hand-edited; the parity test derives
   from the compose file and fails on any compose key it does not recognize, so new
   compose features cannot silently skip the appliance.
4. **No shipping Podman-appliance precedent** — we are first on that axis; the
   blast radius is contained to the appliance channel — DIY is unaffected.
5. **`Notify=healthy` fidelity** — close to but not identical with compose's
   `service_healthy`; verified service-by-service in phase 0 before the renderer exists.
6. **OS rollback ≠ data rollback** — monerod/Tari DB migrations are forward-only.
   Resolved by the migration-deadlock rule (chain services on `data_migration`
   releases start only post-commit), so fallback is always pre-migration; the
   residual risk is a post-commit migration failure, fixed forward on a known-good
   OS.
7. **Secure Boot and at-rest `/data` encryption — decided: out of scope for v1**,
   stated plainly in the appliance docs. Secure Boot: thin/unverified in Rugix, and
   the home-appliance threat model does not justify the key-management complexity
   yet. Disk encryption: a headless auto-booting appliance needs TPM2-bound automatic decryption to
   be usable; until then a stolen disk exposes view keys, onion keys, and dashboard
   credentials — documented, with the encrypted `pithead backup` as the mitigation.
   Both revisit together in a later cycle.
8. **curl-pipe trust** — script is thin, in-repo, checksummed; all real logic in the
   signed bundle.
9. **Signing-key custody** — mandatory cosign + Rugix bundle signing means the
   release keys become the single point of compromise for every channel. The
   mechanism is settled: the existing cosign keypair (`cosign.pub` is already
   committed; signing already wired as opt-in in `release.sh`) — keyless/OIDC does
   not fit a release flow that cuts on gouda, a self-hosted release server, not CI.
   The open decision is custody hardening (offline copy, hardware token), made
   before phase 1 flips signing to mandatory; one key discipline for stack bundles
   and OS images.
10. **Update-availability coupling** — updates come from GitHub Releases over Tor;
    a GitHub outage or Tor block delays updates but breaks nothing (A/B means the
    running system never depends on the update path). Accepted; the manual clearnet
    fallback flag covers the Tor-blocked case.
11. **Scope creep** — the plan spans installer, appliance, updater, renderer,
    first-boot, backup UI, and pipeline work: several substantial projects for a
    small team. Guard: the phase 2 minimum-shippable bar is the milestone; polish
    items (wizard refinement, dashboard buttons, channel tooling) mature after the
    appliance boots, updates, and rolls back — never as blockers to it.

---

## Appendix — v2 adversarial record (kept as the ADR trail)

The evidence that fixed the appliance foundation, retained verbatim so the reversal
history survives:

| Evidence | Source |
|---|---|
| No third-party server/edge appliance shipping on bootc was found; bootc reached CNCF Sandbox Jan 2025. | [CNCF](https://www.cncf.io/projects/bootc/) |
| Peer group converged on Debian/Buildroot + dedicated A/B updater + containers: HAOS (Buildroot+RAUC), umbrelOS (Debian+Rugix, crypto-node appliance, x86), TrueNAS (Debian + ZFS boot environments). | [HAOS update system](https://developers.home-assistant.io/docs/operating-system/update-system/), [umbrel build.sh](https://github.com/getumbrel/umbrel/blob/master/packages/os/build.sh) |
| TrueNAS dropped k3s for Docker Compose in 24.10 (3× faster deploys, lower idle CPU) — validates the no-k8s and no-Talos-cluster decisions. | [Electric Eel](https://www.truenas.com/blog/truenas-electric-eel-nightly/) |
| bootc auto-rollback is manual + greenboot bolt-on (mid-rewrite), with open rollback bugs; Rugix commit-or-revert is built in. | [bootc upgrades](https://bootc.dev/bootc/upgrades.html), [bootc #946](https://github.com/bootc-dev/bootc/issues/946) |
| CentOS Stream: rolling composes, no point-in-time reproducibility; Stream 8 mirror content deleted the day after EOL. Debian 13: LTS to mid-2030, ELTS beyond. | [EOL thread](https://lists.centos.org/hyperkitty/list/devel@lists.centos.org/thread/BQBYHVY55IIJCI2L6JIUQYMJ5BLLJOGE/), [endoflife.date/debian](https://endoflife.date/debian) |
| Rugix: bus-factor-1 (1112 vs 4 commits), Umbrel its only major user (pins Bakery v0.9.1); design strengths are integrated state management, factory reset, delta-over-HTTP. RAUC (2015, Pengutronix, HAOS-proven) is the conservative escape hatch; Umbrel proved updater migration in the field (Mender→Rugix). | [rugix/rugix](https://github.com/rugix/rugix) |
| Podman versions: Quadlet `Notify=healthy` requires ≥ 5.0 ([Podman 5.0 release notes](https://raw.githubusercontent.com/containers/podman/main/RELEASE_NOTES.md)); Debian 13 ships 5.4.2 ([packages.debian.org](https://packages.debian.org/trixie/podman)); Ubuntu 26.04 LTS ships 5.7.0, Ubuntu 24.04 ships 4.9 ([Launchpad](https://launchpad.net/ubuntu/+source/podman)). | — |
