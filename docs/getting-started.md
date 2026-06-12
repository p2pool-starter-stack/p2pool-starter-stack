# Getting Started

This guide takes you from a fresh machine to a synced, mining stack. The whole process is
driven by a single script — `pithead` — and most of it is automated.

> **TL;DR**
> ```bash
> git clone https://github.com/p2pool-starter-stack/pithead.git
> cd pithead
> chmod +x pithead
> ./pithead setup
> ```
> Answer a few prompts, let it run, and open the dashboard at `https://<your-hostname>`.

---

## 1. Prerequisites

| Requirement | Recommendation |
|---|---|
| **Operating system** | Ubuntu Server **24.04 LTS** is the officially supported platform. Other Linux distributions and macOS may work but aren't officially supported. |
| **CPU** | A processor with **AVX2** support is highly recommended for RandomX performance. |
| **RAM** | **16 GB** minimum with HugePages enabled (~6 GB is reserved for RandomX); **32 GB** recommended for a full node or long uptimes. |
| **Disk** | A **pruned** Monero node needs ~**80–100 GB** and a **full** one **200 GB+**, plus ~**50 GB** for the Tari node — so plan for ~**150 GB** (pruned) or ~**300 GB** (full) of **SSD**, with room to grow. |
| **Software** | Docker Engine, Docker Compose V2, `jq`, and `openssl`. |

> 📐 **Full sizing guidance** for the stack host — minimum vs. recommended specs, plus ways to run
> leaner — is in **[Hardware Requirements](hardware.md)**. Miner specs live in
> [RigForge](https://github.com/p2pool-starter-stack/rigforge).

> 🔎 **`setup` checks this for you.** Before it starts anything, `pithead setup` runs a best-effort
> pre-flight on free disk and total RAM. If either is below the recommended minimums (~150 GB
> pruned / ~300 GB full disk, 16 GB RAM), it prints a **warning** — but it never blocks setup, so
> you can proceed on a smaller host at your own risk. See **[Hardware Requirements](hardware.md)**.

You don't have to install the software dependencies yourself. `setup` checks for them and, **on
Ubuntu, offers to install anything that's missing**. If you'd rather do it manually:

```bash
sudo apt update && sudo apt install -y jq docker.io docker-compose-v2 openssl
```

On an unsupported OS — or if dependency detection misfires on an unusual setup — run setup with
`--skip-deps` to bypass the check entirely.

---

## 2. Get the code

```bash
git clone https://github.com/p2pool-starter-stack/pithead.git
cd pithead
chmod +x pithead
```

You'll need your **Monero** payout address and your **Tari** payout address ready before you start
setup. (Tari wallets are sometimes labeled **Minotari** — same thing.)

---

## 3. Run setup

```bash
./pithead setup
```

Setup walks through five stages. It's interactive on the first run and safe to re-run later.

1. **Dependency check.** Verifies Docker, Docker Compose, `jq`, and `openssl` are present. On
   Ubuntu it offers to `apt install` anything missing; on other systems it tells you exactly
   what to install. Skip with `--skip-deps`.

2. **Interactive configuration.** Asks for your Monero and Tari wallet addresses and whether
   you're running a **local** Monero node (the default — the stack runs its own) or connecting
   to a **remote** one. For a local node it **auto-generates** the internal RPC credentials for
   you. It then writes a minimal `config.json` and locks it down to owner-only (`chmod 600`).

3. **Tor provisioning.** Brings up the Tor service and waits for the hidden-service (onion)
   addresses to be generated for Monero, Tari, and P2Pool.

4. **Kernel optimization (Linux only).** Configures **HugePages** for RandomX performance.
   Making HugePages *persistent* edits GRUB and requires a **reboot** — you'll be prompted
   before any GRUB change, and you can skip this whole stage with `--skip-optimize`.

5. **Start.** Once everything is provisioned, setup offers to start the stack for you.

> **If you enabled persistent HugePages, reboot before mining.** After the reboot, start the
> stack with `./pithead up`.

### Setup flags

| Flag | Effect |
|---|---|
| `--skip-optimize` | Skip the kernel/GRUB HugePages tuning (useful on non-Linux hosts or when you tune the kernel yourself). |
| `--skip-deps` | Skip dependency detection and installation. |

---

## 4. First boot: the node syncs

The first time the stack starts, your Monero and Tari nodes have to **download and verify the
blockchain from the network**. Until both are fully synced, the dashboard shows a dedicated
**Sync Mode** screen with live progress for each chain — and no hashrate is routed yet.

This is normal and can take anywhere from a few hours to a day or more depending on your
hardware, disk, and network. You can watch progress on the dashboard or in the logs:

```bash
./pithead logs monerod
./pithead logs tari
```

Once both chains report fully synced, the dashboard automatically switches from Sync Mode to
the full operational view and the stack begins mining. See [The Dashboard](dashboard.md) for a
tour of both states.

> **Already have a synced Monero node?** You can skip most of the initial sync by pointing the
> stack at your existing blockchain data, or by connecting to a remote node. See
> [Reusing an existing node](configuration.md#reusing-an-existing-node).

---

## 5. Open the dashboard

The dashboard is served over HTTPS by Caddy:

```
https://<your-hostname>
```

`<your-hostname>` is the host you set during setup (the script prints the exact URL when it
starts the stack). Caddy uses a self-signed certificate (`tls internal`), so the **first** time
you visit, your browser shows a one-time "your connection is not private" / untrusted-certificate
warning — accept it to continue. Prefer plain HTTP on your LAN? Set `dashboard.secure: false` in
`config.json` and run `./pithead apply`.

---

## 6. Connect your miners

Point your XMRig miners at the stack machine on port **3333** — that's the single endpoint for all
your rigs. You do **not** put your wallet address in the miner config; the stack handles payouts
centrally.

See [Connecting Miners](workers.md) to point an **existing** rig at the stack, or use
[RigForge](https://github.com/p2pool-starter-stack/rigforge) to provision a tuned miner from scratch
in one command.

---

## Next steps

- [Configuration](configuration.md) — fine-tune the stack, reuse an existing node, or switch
  P2Pool sidechains.
- [The Dashboard](dashboard.md) — understand Sync Mode and every panel of the live view.
- [Operations & Maintenance](operations.md) — upgrades, backups, and troubleshooting.
