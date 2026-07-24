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

### Phase 3 — first-boot provisioning

`pithead` unprovisioned mode. `config.json` pre-seed on the config partition first
(fleet-friendly); the #33 form as a first-boot web wizard second, reachable at
`http://pithead.local` (mDNS) / printed console URL, gated only-when-unprovisioned +
one-time console token; no plaintext wallets persisting on FAT32 after provisioning.
The setup window is hardened beyond the token gate: the wizard serves HTTPS with an
ephemeral self-signed certificate whose SHA-256 fingerprint is printed on the
physical console beside the one-time token (fingerprint display is already this
project's pattern — the stratum TLS pin), and no form field renders until the token
is entered — wallet addresses, view keys, and the dashboard password never cross the
LAN in cleartext or reach an unauthenticated browser.

The wizard keeps the existing clearnet-IBD question (`pithead:2315` —
"private over Tor (days) or faster over clearnet (hours)") — first-sync duration is
the single biggest first-day adoption factor and the option already exists. Lockout
insurance: physical console login always works (the appliance has no SSH by default;
SSH is a wizard opt-in) — a broken wizard must never brick the box.

### Phase 4 — release pipeline + channels

`release.sh` grows an `os-image` lane (Bakery build → full + delta bundles →
checksum + sign → GitHub Release) alongside the bundle lane the installer consumes.
Release channels: stable + beta (tag convention). Tier-4 validation: boot-test the
image per cut on the #54 matrix, same mandate as the targeted e2e.

## Support policy

- Appliance base: Debian 13 through its LTS window (mid-2030); rebase to Debian 14
  planned, not emergency.
- Minimum hardware spec, stated in `docs/appliance.md` and enforced by the installer:
  amd64 with AVX2 (hard-fail, not warn), RAM sized to the compose memory caps
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

## Risk register

1. **netavark egress-firewall port** (appliance only) — the technical unknown that
   gates the runtime decision; phase 0 item 1.
2. **Rugix bus factor** — accepted with mitigations (updater-agnostic recipe, RAUC
   escape hatch, talk to Silitics/Umbrel); re-evaluate at phase 0/2 boundary.
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
