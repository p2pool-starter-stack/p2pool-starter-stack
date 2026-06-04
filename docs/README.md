# Documentation

Everything you need to run, configure, and operate **Pithead**.

New here? Start with the [Getting Started](getting-started.md) guide — it takes you from a
fresh Ubuntu machine to a synced, mining stack in a handful of commands. The other guides go
deeper on individual topics once you're up and running.

## Guides

| Guide | What it covers |
|---|---|
| [Getting Started](getting-started.md) | Prerequisites, installation, first-run setup, and what to expect while the node syncs. |
| [Hardware Requirements](hardware.md) | Minimum vs. recommended specs for the **stack host** — CPU, RAM, disk, network, OS — plus lighter-footprint options. (Miner hardware lives in [RigForge](https://github.com/p2pool-starter-stack/rigforge).) |
| [Configuration](configuration.md) | Every `config.json` key and default, applying changes safely, **reusing an existing node via data directories**, and connecting to a **remote Monero node**. |
| [The Dashboard](dashboard.md) | **Sync Mode**, the live operational view, and how to read every panel. |
| [Telegram Alerts](telegram.md) | Push **operator alerts** (node down/recovered, worker offline/back, sync finished) to Telegram — creating a bot, finding your chat id, and per-event toggles. |
| [Connecting Miners](workers.md) | Pointing any existing rig at the stack, plus [RigForge](https://github.com/p2pool-starter-stack/rigforge) for setting up new miners. |
| [Architecture](architecture.md) | The nine services, how they fit together, the privacy model, and the algorithmic XvB switching engine. |
| [Operations & Maintenance](operations.md) | The full `pithead` command reference, upgrades, backups, and troubleshooting. |
| [Releasing](releasing.md) | How Pithead is versioned and released — one product, one version, the `VERSION` source of truth, and the GHCR stage→promote pipeline. |
| [FAQ](faq.md) | Common questions, plus why Pithead vs. doing it yourself or Gupax. |

## Quick links

- **Just want to start mining?** → [Getting Started](getting-started.md)
- **Will my machine handle it?** → [Hardware Requirements](hardware.md)
- **Change a setting?** → [Configuration › Changing settings later](configuration.md#changing-settings-later)
- **Already have a synced Monero node?** → [Configuration › Reusing an existing node](configuration.md#reusing-an-existing-node)
- **Something's not working?** → [Operations › Troubleshooting](operations.md#troubleshooting)
