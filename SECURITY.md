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

Report any gap in these.

## The host-mutation channel (#33)

The [config editor](docs/dashboard.md#the-config-editor) (`dashboard.control.enabled`, default off)
is the one path where the dashboard changes the host — it can rewrite `config.json` and run
`pithead apply`, which can move your payout wallet. It is built as a one-way trust boundary: the
container asks, the host decides.

- **The container only asks.** The dashboard writes a typed JSON intent into a spool directory. A
  root systemd runner on the host (`pithead control-run-pending`) claims it, re-validates it against
  pithead's own `parse_and_validate_config`, and runs `pithead apply`. The dashboard never runs
  anything on the host itself.
- **No arbitrary execution.** The runner does exactly `pithead apply --dry-run` (preview) or
  `pithead apply -y` (commit) — never a general command. Intents are structured JSON only; no shell
  string ever crosses the boundary, and the request id is validated as a uuid4 before it is used as
  a filename.
- **The container cannot forge trust.** The spool splits by writability: `requests/` is the only
  container-writable directory; `staged/`, `results/`, and `audit/` are host-owned and mounted
  read-only. So a compromised dashboard can queue a request but cannot forge a result, rewrite the
  audit log, or alter a change the host has already staged and shown you.
- **Fail-closed and audited.** pithead refuses to enable the channel without a dashboard login.
  Every commit is written to a host-side audit log (timestamp, request id, the Caddy-authenticated
  actor, outcome) the container cannot rewrite. A failed apply keeps the previous config as
  `config.json.bak-control`.
- **Per-change confirmation.** Every apply is previewed and requires an explicit confirm in the UI;
  disruptive changes (payout wallet, sidechain switch, prune toggle, node local↔remote) are flagged.
  The commit passes a single approval hook (`control_approval_gate`); today the UI confirm is the
  gate, with room for an out-of-band approval to plug in later.

Turn it off (`dashboard.control.enabled: false`, then `./pithead apply`) and the runner units are
removed and the channel is inert.
