# Security Policy

The security policy for Pithead: supported versions, how to report a vulnerability,
and the stack's default security posture.

Pithead runs a Monero full node, P2Pool, Tari merge-mining, and a dashboard on your
hardware, and it handles wallet payout addresses.

## Supported versions

Security fixes land on the latest `main`. There are no long-lived release branches.
Make sure you're running an up-to-date checkout before reporting an issue.

| Version       | Supported          |
|---------------|--------------------|
| latest `main` | ✅                 |
| anything older| ❌ (please update) |

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

- Least-privilege containers: every service runs as a non-root user (not uid 0); leaf services
  run with `no-new-privileges` and drop all Linux capabilities; internet-facing and
  Docker-socket-facing services also use a read-only root filesystem.
- SHA256-verified, version-pinned binaries.
- Localhost-only RPC.
- LAN-scoped (and narrowable) stratum port.
- Scoped Docker socket proxies.
- Tor for all node networking.
- A one-way host-control boundary for dashboard config editing and upgrades (`dashboard.control`,
  default off): the dashboard container can only *ask* — it writes typed JSON intents into a spool
  directory whose other legs (staged configs, results, the audit log) are host-owned and mounted
  read-only. A root systemd unit re-validates every intent with pithead's own config validation
  and dispatches exactly three fixed actions (`apply --dry-run`, `apply -y`, and a release
  upgrade); no string from the container is ever executed. The upgrade intent carries only the
  version the operator confirmed: the runner re-derives the target itself from the GitHub release
  API (over the stack's Tor SOCKS), refuses any mismatch or non-release tag, and limits attempts
  to one per 10 minutes — the container cannot choose an image, tag, or registry. Enabling the
  channel without a dashboard password is a validation error, on a published onion it additionally
  requires Tor client authorization, and every mutation is audited host-side. Commits are default-denied against an explicit allowlist of
  operational settings: a commit that changes any env key off that list — in every direction
  (enabling, changing, or disabling) — is refused, as is anything the change preview flags
  destructive. Wallets, dashboard auth and onion exposure, the control channel itself, the Tor
  egress firewall, clearnet toggles, node endpoints, binds, and every credential are off the
  list, and a key added in the future stays un-committable until deliberately listed. Those
  edits must be applied from the host CLI; out-of-band approval is tracked in
  [#338](https://github.com/p2pool-starter-stack/pithead/issues/338).
- Attack visibility (#349): Caddy writes a JSON access log for every dashboard vhost (LAN and
  onion), and the control channel's host-side audit log records who changed what (setting names
  only, never values). The dashboard surfaces both read-only — a burst of 401s is the
  rotate-the-password signal — and treats every logged field as hostile input: strings are
  whitelisted to a safe character set before display, because the access log echoes
  attacker-chosen bytes (request paths, attempted usernames) and rendering them raw would hand an
  anonymous prober stored XSS against the operator. Both logs are size-bounded (Caddy's native
  rolling; a trim-before-append cap in the audit writer). Neither ever records a secret: Caddy
  redacts credential headers by default, and the audit writer logs key names only.

### Secret trust boundary for dashboard config editing

When `dashboard.control` is on, the dashboard reads `config.json` through a **read-only bind
mount** to prefill the editor form. The API masks every secret leaf before serving it to the
browser — but that masking protects the *browser*, not the container. The bind mount itself is the
real secret boundary: a backend compromise of the dashboard container can read the plaintext
`config.json` (including the dashboard login and stratum passwords) directly off the mount,
regardless of the API masking. Treat the dashboard container as semi-trusted, keep the onion behind
Tor client authorization, and do not co-host untrusted workloads in that container. Host-side
staged copies that carry merged secrets are written mode 600.

Report any gap in these.
