# Security Policy

The security policy for Pithead: supported versions, how to report a vulnerability,
and the stack's default security posture.

Pithead runs a Monero full node, P2Pool, Tari merge-mining, and a dashboard on your
hardware, and it handles wallet payout addresses.

## Supported versions

Security fixes land in the latest release. There are no long-lived release branches.
Run `./pithead version` and report what it prints; upgrade before reporting, in case the issue is
already fixed — `./pithead upgrade` on a Compose install, `./pithead os-update` on the appliance.

| Version                              | Supported          |
|--------------------------------------|--------------------|
| latest release (`./pithead version`) | ✅                 |
| anything older                       | ❌ (please update) |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private vulnerability reporting instead: go to the **Security** tab and
click **Report a vulnerability**. This opens a private advisory visible only to the
maintainers, for triage and coordinated disclosure.

Include:

- A description of the issue and its impact.
- Steps to reproduce, and the affected component (node, P2Pool, proxy, dashboard, Tor,
  `pithead` script, etc.).
- Any relevant logs or configuration (redact wallet addresses and secrets).

## Security posture

The stack's defaults:

- Least-privilege containers: every daemon that touches the network or the chains — `monerod`,
  P2Pool, the Tari node, `xmrig-proxy`, the dashboard, Tor — runs as a non-root user. Caddy and the
  two Docker socket proxies run as uid 0 inside their containers, which is why they hold no chain
  data, drop every Linux capability, and sit on host-loopback-only ports. Leaf services run with
  `no-new-privileges` and drop all capabilities; internet-facing and Docker-socket-facing services
  also use a read-only root filesystem.
- SHA256-verified, version-pinned binaries.
- Digest-pinned **and signed** images
  ([#376](https://github.com/p2pool-starter-stack/pithead/issues/376)): the release bundle pins
  every first-party image to an immutable `@sha256` digest, so a tampered registry can't swap what
  gets pulled, and the bundle itself is fetched over TLS from GitHub Releases. `cosign.pub` is
  committed at the repo root and ships inside the bundle, so a release install has the verifier
  without a git checkout. `scripts/release.sh` signs each promoted digest and the install bundle
  whenever the signing key is present on the release box; it warns and ships unsigned if the key is
  missing, so check a release's signature rather than assuming it. Releases before v1.18.1 are
  unsigned. Limits: a compromise of the release box itself, which holds the signing key, is outside
  what a signature can prove. See
  [Releasing › Signed releases](docs/dev/releasing.md#signed-releases) for the verification mechanics.
- Localhost-only RPC.
- LAN-scoped (and narrowable) stratum port.
- Scoped Docker socket proxies.
- Tor for all node networking with the bundled nodes, enforced fail-closed by a host firewall
  (`network.tor_egress_firewall`, default on). Two opt-ins leave that path: the clearnet initial
  sync (`monero.clearnet_initial_sync` / `tari.clearnet_initial_sync`, default off), and remote-node
  mode (`monero.mode` / `tari.mode: remote`), where the node legs are direct connections to the
  machine you named. The firewall still confines those to private ranges. See
  [Privacy & Network Egress](docs/privacy.md).
- A one-way host-control boundary for dashboard config editing and upgrades (`dashboard.control`,
  default off): the dashboard container can only *ask* — it writes typed JSON intents into a spool
  directory whose other legs (staged configs, results, the audit log) are host-owned and mounted
  read-only. A root systemd unit re-validates every intent with pithead's own config validation
  and dispatches a fixed, small set of actions (`apply --dry-run` for a preview, `apply -y` for a
  config commit, a release upgrade, the appliance's staged OS-update steps, and — for the
  Telegram control commands (#338) — a stack `restart` and a config re-`apply`); no string from
  the container is ever executed. The upgrade intent carries only the
  version the operator confirmed: the runner re-derives the target itself from the GitHub release
  API (over the stack's Tor SOCKS), refuses any mismatch or non-release tag, and limits attempts
  to one per 10 minutes — the container cannot choose an image, tag, or registry. The appliance's
  OS-update verbs hold the same line, one step per intent (check, download, verify, install, and
  a separate reboot): the host re-derives the release target, downloads the signed OS bundle to
  `/data` itself, and judges the local file (RAUC signature against the baked keyring, machine
  `compatible`, the downgrade/`/data`-migration floor and a same-version reinstall — the
  dashboard door only ever moves forward — build-variant posture) before any slot is
  written — a refused bundle is deleted with no override, and every verb refuses outright on a
  non-appliance host. The reboot intent is refused unless an install completed within the last
  24 hours. That gate proves *an installed update is waiting*, not *the operator asked now*:
  inside the window, a compromised container that can write the spool can time the reboot
  itself — the TTL bounds that exposure rather than removing it. Enabling the
  channel without a dashboard password is a validation error, on a published onion it additionally
  requires Tor client authorization, and every mutation is audited host-side. Commits are default-denied against an explicit allowlist. Low-risk
  operational settings commit directly; a small set of operationally-disruptive ones — data-directory
  moves, the stratum port, enabling clearnet initial sync, and enabling pruning — commit only behind
  a typed confirmation in the dashboard, and only in that direction. A dashboard-confirmed
  data-directory move is further held to an **allowlist** (#728): the new location must sit under the
  stack's own data root (the install dir's `data/`) or a parent the stack already keeps data in;
  a move to any other absolute path is refused even with the typed confirmation and stays host-CLI
  only. The host CLI keeps its wider blocklist check — a shell operator already has filesystem-wide
  reach. Everything else is refused in
  every direction, as is anything the change preview flags destructive (including the heavy direction
  of a confirm-gated key, e.g. disabling pruning, which forces a full re-sync). The security
  perimeter — wallets and view keys, dashboard auth and onion exposure, the control channel itself,
  the Tor egress firewall, node endpoints, binds, every credential, and the per-rig hosts and tokens —
  is never dashboard-committable, with or without the typed confirmation. A key added in the
  future stays un-committable until deliberately listed. Those edits must be applied from the host CLI.
- Attack visibility (#349): Caddy writes a JSON access log for every dashboard vhost (LAN and
  onion), and the control channel's host-side audit log records who changed what (setting names
  only, never values). The dashboard surfaces both read-only — a burst of 401s is the
  rotate-the-password signal — and treats every logged field as hostile input: strings are
  whitelisted to a safe character set before display, because the access log echoes
  attacker-chosen bytes (request paths, attempted usernames) and rendering them raw would hand an
  anonymous prober stored XSS against the operator. Both logs are size-bounded (Caddy's native
  rolling; a trim-before-append cap in the audit writer). Neither ever records a secret: Caddy
  redacts credential headers by default, and the audit writer logs key names only.
- Out-of-band change detection (#530, #1551): the audit trail above only sees requests the
  dashboard itself handled. Its poll loop separately watches for a `config.json` change with no
  matching control-channel commit, a worker control-API report for a change the dashboard never
  sent, and a rig whose own config revision moved with no new change id beside it — the edit made
  underneath RigForge, which reports nothing to notice. All three — `host-edit` / `rig-edit` /
  `rig-drift` — append to the same trail, keys or worker names only. The persisted trail (mirrored
  `control.log` rows plus these three out-of-band kinds) lives in the dashboard's own database, not
  just the log tail, so the Security panel's range presets, date fields and search cover more than
  `control.log`'s own trimmed window. The `rig-edit` and `rig-drift` sources both read off the
  unauthenticated worker feed, so they SHARE one rate cap per worker (#724): a rig reporting
  distinct change_ids — or a fresh revision — on every poll can add at most a bounded number of
  rows per hour between them before the rest are dropped behind a single `rate-limited` marker that
  names which of the two tipped it, so one LAN device can't grow the database without limit. One
  budget rather than one each, because two would double what that device can make permanent. Values
  from that feed are also validated to a short opaque token before they reach the store, so a rig
  cannot choose an audit row's own identifier. The `host-edit` and mirrored `control.log` rows are
  not attacker-controllable and are not capped.

### Telegram control commands (#338)

The Telegram bot can accept two **control** commands, `/restart` and `/apply`, gated behind
`telegram.control` (default off). This is a remotely-reachable control surface — a Telegram message
is untrusted pre-auth input — so it fails closed at every step and adds **no new privileged path**:
it is a thin client of the host-control channel above.

- **Allow-list, not the chat.** A control command is honoured only from the numeric Telegram **user
  ids** in `telegram.control.allowed_ids`; being in the configured chat is not enough, and the bot
  token being known is not authorization. Any other sender is refused, logged, and dropped silently
  (no reply — no oracle for who is authorised), and never earns a write into the host spool. An
  empty allow-list disables the feature.
- **Per-action confirmation, deny-on-timeout.** Each command requires an explicit in-chat
  confirmation (an inline button carrying a one-time token) from the same operator that issued it,
  within a timeout — transaction-signing semantics, so even a fully compromised dashboard session
  cannot restart or re-apply without a human approving the exact action. An unconfirmed command is
  **denied**, never queued; prompts are rate-limited so a compromised host can't fatigue the
  operator into tapping approve.
- **Bounded verbs, shared channel.** A message only selects one of two fixed verbs — there is no
  arbitrary execution. Confirmed, the verb rides the same request spool the config editor uses; the
  root runner validates and runs it and records the actor (`tg-<user-id>`) and outcome in the
  host-side audit log. `telegram.control` therefore requires `dashboard.control` (the spool + runner)
  and the read-only command bot; `apply` refuses to enable it otherwise. A **config-changing** apply
  is deliberately not a Telegram command — config edits still go through the editor's default-deny
  allowlist; `/apply` only re-applies the config already on the host.

### Secret trust boundary for dashboard config editing

The dashboard container never mounts the raw `config.json` (#440). When `dashboard.control` is
on, the host renders a **pre-masked copy** of the config into the control spool — every set
secret leaf (node credentials, the stratum and dashboard passwords, the Telegram token, the
Healthchecks ping URL) already replaced by a sentinel — and the editor form prefills from that
copy, mounted read-only. An untouched secret rides back to the host as the same sentinel, and the
host swaps it for the live value when it stages the intent, so the container never holds a secret
the operator didn't just type into the form. A full backend compromise of the dashboard container
can therefore read masked config, results, and the audit log, and *ask* to change an allowlisted
key — nothing else. Host-side staged copies, which do carry the merged secrets, live outside
every mount and are written mode 600. Still treat the container as semi-trusted and keep the
onion behind Tor client authorization: the request spool remains a mutation-request surface.

Report any gap in these.
