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
- A one-way host-control boundary for dashboard config editing (`dashboard.control`, default
  off): the dashboard container can only *ask* — it writes typed JSON intents into a spool
  directory whose other legs (staged configs, results, the audit log) are host-owned and mounted
  read-only. A root systemd unit re-validates every intent with pithead's own config validation
  and dispatches exactly two fixed actions (`apply --dry-run`, `apply -y`); no string from the
  container is ever executed. Enabling the channel without a dashboard password is a validation
  error, on a published onion it additionally requires Tor client authorization, destructive edits
  (wallet, egress firewall, clearnet sync, auth) are refused from the dashboard and must be applied
  from the host CLI, and every mutation is audited host-side.

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
