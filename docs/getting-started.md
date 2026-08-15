# Getting Started

Install and first-run setup, from a fresh Ubuntu host to a synced, mining stack. The `pithead`
script drives every step.

This is the DIY path: your host, your OS. To dedicate a machine and skip the host management
entirely, write [the appliance image](appliance.md) to a USB stick instead — same stack, same
dashboard, no Linux to set up.

> **TL;DR**
>
> ```bash
> curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz
> cd pithead
> cp config.minimal.json config.json   # set your Monero + Tari payout addresses
> ./pithead setup
> ```
>
> Let it run, then open the dashboard at `https://<your-hostname>`.

---

## 1. Prerequisites

| Requirement | Recommendation |
|---|---|
| Operating system | Ubuntu Server 24.04 LTS is the supported platform. Other Linux distributions and macOS may work but aren't supported. |
| CPU | A processor with AVX2 support for RandomX performance. |
| RAM | 16 GB minimum with HugePages enabled (~6 GB is reserved for RandomX); 32 GB for a full node or long uptimes. |
| Disk | A pruned Monero node needs ~100 GB and a full one ~270 GB, plus ~150 GB for the Tari node (its chain is the biggest single consumer). Plan for ~300 GB (pruned) or ~500 GB (full) of SSD minimum. Both chains grow ~100+ GB/year, so a 2–4 TB drive is the set-and-forget choice. |
| Software | Docker Engine, Docker Compose V2, `jq`, and `openssl`. |

> 📐 Sizing guidance for the stack host — minimum vs. recommended specs, plus ways to run leaner —
> is in **[Hardware Requirements](hardware.md)**. Miner specs live in
> [RigForge](https://github.com/p2pool-starter-stack/rigforge).

> 🔎 `setup` checks this for you. Before it starts anything, `./pithead setup` runs a best-effort
> pre-flight on free disk and total RAM. If either is below the recommended minimums (~300 GB
> pruned / ~500 GB full disk, 16 GB RAM), it prints a warning. It never blocks setup, so you can
> proceed on a smaller host at your own risk. See **[Hardware Requirements](hardware.md)**.

You don't have to install the software dependencies yourself. `setup` checks for them and, on
Ubuntu, offers to install anything missing. To do it manually:

```bash
sudo apt update && sudo apt install -y jq docker.io docker-compose-v2 openssl
```

On an unsupported OS, or if dependency detection misfires on an unusual setup, run setup with
`--skip-deps` to bypass the check entirely.

---

## 2. Get the code

Download the latest release. This pulls the published, tested images (no local build), so the
dashboard shows the real version and the update-checker works:

```bash
curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz
cd pithead
cp config.minimal.json config.json   # then set your Monero + Tari payout addresses
```

`config.minimal.json` is minimal: just your two payout addresses. `setup` fills in defaults for
everything else. For the full set of knobs, copy `config.reference.json` instead. Have your
Monero and Tari payout addresses ready (Tari wallets are sometimes labeled Minotari, same thing).

### Alternative: build from source

To build the images locally instead of pulling the published ones, e.g. to develop or modify the
stack, clone the repo. pithead sees the `build/` context and builds locally, tagging the images `:dev`
(the dashboard badge then reads `dev · <branch> @ <commit>` instead of the release version):

```bash
git clone https://github.com/p2pool-starter-stack/pithead.git
cd pithead && chmod +x pithead
cp config.minimal.json config.json   # then set your payout addresses
```

> Changed your mind later? You can convert a clone to the published images in place. See
> [Switching a source checkout to release images](operations.md#switching-a-source-checkout-to-release-images).

---

## 3. Run setup

```bash
./pithead setup
```

Setup walks through five stages. It's interactive on the first run and safe to re-run later.

1. **Dependency check.** Verifies Docker, Docker Compose, `jq`, and `openssl` are present. On
   Ubuntu it offers to `apt install` anything missing; on other systems it tells you what to
   install. Skip with `--skip-deps`.

2. **Interactive configuration.** Asks only what only you can answer, in two short stages, then
   fills in the rest and writes a minimal `config.json`, locked down to owner-only (`chmod 600`).
   - **Required:** your Monero and Tari wallet addresses; whether you're running a local Monero
     node (the default — the stack runs its own) or connecting to a remote one, with a local
     node's RPC credentials auto-generated; and your P2Pool pool tier (`main`/`mini`/`nano` —
     pick low if you're not sure, a high-hashrate default silently starves a small rig of
     shares). An optional dashboard login, Enter to skip.
   - **A few more, Enter for the default:** a faster clearnet initial sync instead of the private
     Tor default; reaching the dashboard from outside your LAN over Tor; Telegram alerts.
   - Everything else — ports, XvB tuning, energy pricing, per-worker overrides, and more — keeps
     its documented default; the wizard prints a pointer to `config.json` and
     [Configuration](configuration.md) at the end for anyone who wants it.

3. **Tor provisioning.** Brings up the Tor service and waits for the hidden-service (onion)
   addresses to be generated for Monero, Tari, and P2Pool.

4. **Kernel optimization (Linux only).** Configures HugePages for RandomX performance. Making
   HugePages persistent edits GRUB and requires a reboot. You're prompted before any GRUB change,
   and you can skip this whole stage with `--skip-optimize`.

5. **Start.** Once everything is provisioned, setup offers to start the stack.

> If you enabled persistent HugePages, reboot before mining. After the reboot, start the stack
> with `./pithead up`.

### Setup flags

| Flag | Effect |
|---|---|
| `--skip-optimize` | Skip the kernel/GRUB HugePages tuning (useful on non-Linux hosts or when you tune the kernel yourself). |
| `--skip-deps` | Skip dependency detection and installation. |

---

## 4. First boot: the node syncs

The first time the stack starts, your Monero and Tari nodes download and verify the blockchain
from the network. Until both are fully synced, the dashboard shows a dedicated Sync Mode screen
with live progress for each chain, and no hashrate is routed yet. When the stack first comes up,
`pithead` prints a short "what happens next" note saying the miner is held until both chains sync,
then starts automatically — it shows once, not on every restart.

This can take anywhere from a few hours to a day or more depending on your hardware, disk, and
network. Watch progress on the dashboard, with `./pithead status` (it prints each chain's percent
and blocks remaining while syncing), or in the logs:

```bash
./pithead logs monerod
./pithead logs tari
```

Once both chains report fully synced, the dashboard switches from Sync Mode to the full
operational view and the stack begins mining. See [The Dashboard](dashboard.md) for a tour of
both states.

> Already have a synced Monero node? You can skip most of the initial sync by pointing the stack
> at your existing blockchain data, or by connecting to a remote node. See
> [Reusing an existing node](configuration.md#reusing-an-existing-node).

> Sync crawling over Tor? The default routes the first sync over Tor for privacy, which is slow.
> You can opt into a faster clearnet initial sync for Monero and/or Tari; each node switches back
> to Tor automatically once it's synced. It's default-off and privacy-relevant, so read the
> trade-off first:
> [Optional clearnet initial sync](privacy.md#optional-clearnet-initial-sync-off-by-default).

---

## 5. Open the dashboard

The dashboard is served over HTTPS by Caddy:

```
https://<your-hostname>
```

`<your-hostname>` is the host you set during setup (the script prints the exact URL when it
starts the stack). Caddy uses a self-signed certificate (`tls internal`), so the first time you
visit, your browser shows a one-time "your connection is not private" / untrusted-certificate
warning. Accept it to continue. Prefer plain HTTP on your LAN? Set `dashboard.secure: false` in
`config.json` and run `./pithead apply`.

---

## 6. Connect your miners

Point your XMRig miners at the stack machine on port `3333`. That's the single endpoint for all
your rigs. Do not put your wallet address in the miner config; the stack handles payouts
centrally.

See [Connecting Miners](workers.md) to point an existing rig at the stack, or use
[RigForge](https://github.com/p2pool-starter-stack/rigforge) to provision a tuned miner from scratch
in one command.

---

## Next steps

- [Configuration](configuration.md) — fine-tune the stack, reuse an existing node, or switch
  P2Pool sidechains.
- [The Dashboard](dashboard.md) — understand Sync Mode and every panel of the live view.
- [Operations & Maintenance](operations.md) — upgrades, backups, and troubleshooting.
