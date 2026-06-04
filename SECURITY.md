# Security Policy

Pithead runs a Monero full node, P2Pool, Tari merge mining, and a dashboard on your
hardware, and it handles wallet payout addresses. We take security seriously and
appreciate reports that help keep operators safe.

## Supported versions

Security fixes land on the latest `main`. There are no long-lived release branches —
please make sure you're running an up-to-date checkout before reporting an issue.

| Version       | Supported          |
|---------------|--------------------|
| latest `main` | ✅                 |
| anything older| ❌ (please update) |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private vulnerability reporting instead: go to the **Security** tab and
click **"Report a vulnerability"**. This opens a private advisory visible only to the
maintainers, where we can triage and coordinate a fix and disclosure with you.

When you report, it helps to include:

- A description of the issue and its impact.
- Steps to reproduce, and the affected component (node, P2Pool, proxy, dashboard, Tor,
  `pithead` script, etc.).
- Any relevant logs or configuration (redact wallet addresses and secrets).

We aim to acknowledge reports promptly and will keep you posted as we work on a fix.

## Security posture

The stack is hardened by default: least-privilege containers (leaf services run with
`no-new-privileges` and — except the dashboard, which writes its history DB as root into a
user-owned volume — drop all Linux capabilities; the internet-facing and Docker-socket-facing
ones also use a read-only root filesystem), SHA256-verified and version-pinned binaries,
localhost-only RPC, a LAN-scoped (and narrowable) stratum port, scoped Docker socket proxies,
and Tor for all node networking. If you find a gap in any of these, that's exactly the kind of
report we want.
