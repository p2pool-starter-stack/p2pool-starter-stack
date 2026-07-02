# Security Policy

The security policy for Pithead: supported versions, how to report a vulnerability,
and the stack's default security posture.

Pithead runs a Monero full node, P2Pool, Tari merge mining, and a dashboard on your
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

Report any gap in these.
