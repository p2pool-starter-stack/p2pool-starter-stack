# Documentation

Guides for running, configuring, and operating Pithead.

Start with [Getting Started](getting-started.md): it takes a fresh Ubuntu host to a synced, mining
stack. The other guides cover individual topics once you're running.

## Guides

| Guide | What it covers |
|---|---|
| [Getting Started](getting-started.md) | Prerequisites, installation, first-run setup, and what to expect while the node syncs. |
| [Pithead OS (appliance)](appliance.md) | The flashable appliance image: write it to USB, install it to a disk from your browser, configure by paste, and how A/B updates and rollback behave. |
| [Hardware Requirements](hardware.md) | Minimum vs. recommended specs for the stack host (CPU, RAM, disk, network, OS), plus lighter-footprint options. (Miner hardware lives in [RigForge](https://github.com/p2pool-starter-stack/rigforge).) |
| [Configuration](configuration.md) | Every `config.json` key and default, applying changes safely, reusing an existing node via data directories, and connecting to a remote Monero node. |
| [The Dashboard](dashboard.md) | Sync Mode, the live operational view and how to read every panel, plus the opt-in control channel: editing `config.json`, one-click upgrades, and the access + config-change audit logs, all from the browser. |
| [Monitoring & Alerting](monitoring.md) | Optional Healthchecks.io dead-man's switch — get alerted when your host goes down (power loss, crash), even when it can't tell you itself — plus the Prometheus `/metrics` endpoint for Grafana or any scraper. |
| [Telegram Bot](telegram.md) | Push operator alerts (node down/recovered, worker offline/back, sync finished) to Telegram and query stack status on demand (`/status`, `/hashrate`, `/workers`, `/sync`) — creating a bot, finding your chat id, per-event toggles, and the command list. |
| [Connecting Miners](workers.md) | Pointing any existing rig at the stack, plus [RigForge](https://github.com/p2pool-starter-stack/rigforge) for setting up new miners. |
| [Architecture](architecture.md) | The nine services, how they fit together, the privacy model, and the algorithmic XvB switching engine. |
| [Privacy & Network Egress](privacy.md) | Every connection the stack makes off-box: what's Tor-routed, what's clearnet today, and how to harden each path. |
| [Operations & Maintenance](operations.md) | The full `pithead` command reference (including command chaining and tab-completion), upgrades, encrypted backups, rotating the internal secrets, watching for intruders, and troubleshooting. |
| [FAQ](faq.md) | Common questions, plus why Pithead vs. doing it yourself or Gupax. |

## Developer docs

Docs for working on Pithead itself live in [`dev/`](dev/). Operators don't need them.

| Doc | What it covers |
|---|---|
| [Style Guide](dev/STYLE.md) | The house documentation voice; the banned-word list is enforced by `make lint-docs-voice`. |
| [Appliance Release](dev/appliance-release.md) | Building, testing and releasing the Pithead OS image: the KVM battery, the manual hardware battery, and the bad-release runbook. |
| [Testing Strategy](dev/testing-strategy.md) | The four test tiers (unit → contract → fake-daemon mini-stack → live matrix), the full scenario catalog, and which tier proves each situation. |
| [Testing Guide](dev/testing-guide.md) | How to write and run tests, per-change recipes, conventions, and real-hardware gotchas. |
| Test Inventory | An exhaustive list of every test/scenario across all suites — generated on demand by `make test-inventory` (not committed). |
| [Integration Testing](dev/integration-testing.md) | The end-to-end config-matrix suite that validates the stack against real Monero + Tari nodes: the blocking pre-release gate. |
| [Releasing](dev/releasing.md) | How Pithead is versioned and released: one product, one version, the `VERSION` source of truth, and the GHCR stage→promote pipeline. |
| [Release / Validation Server](dev/release-server.md) | Why end-to-end validation needs a dedicated server (and what GitHub Actions does free on every PR), how to provision and harden it, and the safe self-hosted-runner setup. |
| [Test Server Architecture](dev/test-server-architecture.md) | How the reference test/build box is structured and how to recreate it. |

## Quick links

- **Just want to start mining?** → [Getting Started](getting-started.md)
- **Will my machine handle it?** → [Hardware Requirements](hardware.md)
- **Change a setting?** → [Configuration › Changing settings later](configuration.md#changing-settings-later)
- **Edit config or upgrade from the browser?** → [Dashboard › Configuration view](dashboard.md#configuration-view)
- **Watching for break-in attempts?** → [Operations › Watching for intruders](operations.md#watching-for-intruders)
- **Already have a synced Monero node?** → [Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node)
- **Want proof a payout landed in your wallet?** → [Dashboard › Payout confirmation](dashboard.md#payout-confirmation)
- **Want to be alerted if the host dies?** → [Monitoring & Alerting](monitoring.md)
- **Worried about your IP / what leaves the box?** → [Privacy & Network Egress](privacy.md)
- **Something's not working?** → [Operations › Troubleshooting](operations.md#troubleshooting)
