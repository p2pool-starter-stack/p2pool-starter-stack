# Test / build server architecture & recreation

How the Pithead reference test server (the reference box) is structured, and how to recreate it on
another box. The synced chains are the slow-to-acquire asset (days to sync); everything else is
reproducible in minutes from the repo.

See also [Releasing](releasing.md) and [Release / Validation Server](release-server.md).

## What this server is

A single box that runs the live Pithead stack against real, synced chains and serves three jobs:

1. Tier-4 release gate: the integration harness ([integration-testing](integration-testing.md))
   validates a release end-to-end here before it ships.
2. Developer + AI-agent test bench: a consistent place to reproduce, test, and debug stack
   behavior against real daemons.
3. Reference deployment: a known-good, documented install other boxes can be cloned from.

It is not a production miner. Downtime is fine; tear-down/redeploy is fine. The one rule: don't
lose the synced chains (reuse them, don't re-sync).

## Hardware & storage policy

```
NVMe SSD (fast, PRIMARY)               HDD (slow, SPARING)
  /boot, /boot/efi                      /home   ← cold backups / archives only
  / (root, LVM ext4)
    ├─ /var/lib/docker        (images)
    ├─ /srv/code/pithead      (CHECKOUT, = ~/code/pithead)
    └─ /srv/code/pithead-data (CHAINS)  ← the asset, on fast storage
```

Policy, the single most important hardware rule: the chains monerod/Tari actively run against
live on the SSD/NVMe. monerod is random-I/O heavy; a chain on a spinning HDD makes every test
crawl. The HDD is for cold things only (backup tarballs, archived snapshots). Check `lsblk -d
-o NAME,ROTA` before placing any chain: `ROTA=0` is SSD/NVMe, `ROTA=1` is HDD.

Sizing (a pruned-Monero test bench fits in ~1 TB):

| Component | Size |
|---|---|
| Pruned Monero (compacted) | ~95 GB |
| Tari (archival/full) | ~132 GB |
| Docker images + cache | ~20 GB |
| OS + working headroom | ~30 GB |
| **Total** | **~280 GB** |
| *+ optional full Monero node* | *+250 GB* |
| *+ a few full chain copies* | *95–250 GB each* |

A 1 TB NVMe holds the pruned bench with ~650 GB to spare, room for a full node and copies too.

> NOTE: verify the disk is actually fast. "SSD" in the model name is not enough; check the bus.
> A drive sold as an "SSD" can enumerate on SATA rather than NVMe, on a link that negotiates down
> to a slow speed, and benchmark at ~37–98 MB/s, HDD-class. That single fact bottlenecks monerod,
> builds, and makes LMDB compaction (heavy random I/O) impractical (~16 h instead of ~10 min).
> Confirm the bus before relying on a drive:
>
> ```bash
> lsblk -d -o NAME,TRAN,ROTA,MODEL   # want TRAN=nvme, not sata
> ls /dev/nvme*                       # an NVMe drive appears as a /dev/nvme* node
> # quick reality check on random read (what monerod does):
> dd if=/path/to/data.mdb of=/dev/null bs=4k count=200000 skip=10000000   # want >>100 MB/s
> ```
>
> The fix is to put the chains on a fast NVMe SSD. Add an m.2 PCIe NVMe and migrate the chains
> onto it; mount the data dir by UUID via fstab (ext4, `noatime`, `nofail`) and keep the OS on a
> separate disk. monerod then opens the ~266 GB pruned LMDB in seconds and the full integration
> matrix runs green. Compaction to ~95 GB uses
> [`compact-chain.sh`](../tests/integration/compact-chain.sh)
> (`monero-blockchain-prune --copy-pruned-database`) — the chain is correctly pruned; the extra
> size is reclaimable free-page bloat, not a full chain. Stock `mdb_copy -c` does not work: Monero
> ships a patched LMDB and stock `mdb_copy` rejects the format (`MDB_VERSION_MISMATCH`). CoW
> snapshots need btrfs/zfs on the NVMe (if it's ext4); see below.

A second m.2 NVMe (PCIe) with btrfs/zfs additionally enables copy-on-write snapshots: instant,
near-free chain clones for isolated/parallel test runs.

## Directory layout

| Path | Disk | What | Lose it? |
|---|---|---|---|
| `~/code/pithead/` (`/srv/code/pithead`) | SSD | stack checkout (`docker-compose.yml`, the `pithead` CLI), `config.json`, `.env` | reproducible (clone) |
| `/srv/code/pithead-data/{monero,tari,p2pool,dashboard,tor}/` | NVMe | the chains + Tor onion keys, the asset (mounted by UUID, ext4) | **don't** (days to re-sync) |
| `/var/lib/docker/` | SSD | images / build cache | reproducible (rebuild) |
| `~/pithead-testbench/` | HDD | build-server docs + ops tools (see its `README.md`) | reproducible (repo) |
| `/home` … `/mnt/chains` | HDD | cold backups / archives | — |

The chains live outside the checkout (`/srv/...`, absolute paths in `config.json`), so the stack
can be refreshed/redeployed without ever touching them.

## Recreate on another box

Goal: stand up an equivalent server. Minutes of work + one chain transfer (vs days of re-sync).

**1. Prereqs.** Ubuntu LTS, Docker (Compose v2), `git jq curl tar`, and your user in the `docker`
   group. Put the chains' target on the SSD.

**2. Clone + configure:**

```bash
git clone https://github.com/p2pool-starter-stack/pithead.git ~/pithead && cd ~/pithead
cp /path/to/your/config.json .         # your wallets/settings — or run `./pithead setup` to make one
# point data dirs at fast storage (checkout-independent):
jq '.monero.data_dir="/srv/<you>/pithead/data/monero"
  | .tari.data_dir="/srv/<you>/pithead/data/tari"
  | .p2pool.data_dir="/srv/<you>/pithead/data/p2pool"
  | .dashboard.data_dir="/srv/<you>/pithead/data/dashboard"
  | .tor.data_dir="/srv/<you>/pithead/data/tor"' config.json | sponge config.json
```

**3. Bring the chains (reuse, don't re-sync).** Stop the stack on the source box (`./pithead down`)
   so the LMDBs are consistent, then copy `/srv/.../pithead/data/` to the new box's SSD, over the
   network or a fast external drive:

```bash
# from the new box, pulling from the old one (chains are ~230 GB; hours over GbE, faster over USB3/10G):
rsync -aP --info=progress2 olduser@oldbox:/srv/code/pithead-data/ /srv/<you>/pithead/data/
```

The Tor onion keys travel in `data/tor`, so the box keeps its onion identity. (No old box yet? Omit
this and let monerod/Tari sync from scratch; days, but hands-off.)

**4. Deploy + verify:**

```bash
cd ~/pithead && ./pithead setup        # deps, .env, Tor, Caddy; then `up`
./pithead status                        # all healthy; monerod just catches up the gap
```

**5. Test-bench tooling:**

```bash
mkdir -p ~/pithead-testbench/bin
cp ~/pithead/tests/integration/{build-pruned-chain,compact-chain,system-info}.sh ~/pithead-testbench/
cp ~/pithead/tests/integration/testbench-README.md ~/pithead-testbench/README.md
# fetch monero-blockchain-prune at the running monerod's version (see build/monero/Dockerfile pins):
~/pithead-testbench/system-info.sh > ~/pithead-testbench/system-info.md
```

**6. Validate it's release-fit:**

```bash
tests/integration/run.sh --host you@newbox --dir pithead --readiness
```

## Migrating the test bench → a bigger box later

Same as above, steps 3–6: `rsync` the chains + `config.json` over, `pithead setup`, redeploy,
copy the test-bench tooling, regenerate `system-info.md`. Because the chains are decoupled and the
config is captured, the move is a transfer + a redeploy. No reconfiguration, no re-sync. Put the
chains on the bigger box's fastest disk; if it has spare NVMe, that's the place for a btrfs/zfs CoW
volume to get cheap test-chain snapshots.
