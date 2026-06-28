# Configuration

`config.json` is the **single source of truth** for the entire stack. The interactive `setup`
writes a minimal one for you; from then on you change the stack by editing `config.json` and
running `./pithead apply`.

## The minimal config

Only your two **wallet addresses** are required. **Every other key is optional and falls back to
a sensible default** — the node runs locally, on the `main` pool, with a secure dashboard, and the
local node's RPC credentials are **auto-generated** for you — so leave a key out unless you want to
change it.

A fresh `config.json` is just this (see [`config.json.template`](../config.json.template)):

```json
{
    "monero": {
        "wallet_address": "your_monero_wallet_address"
    },
    "tari": {
        "wallet_address": "your_tari_wallet_address"
    }
}
```

For the complete shape with **every** key and its default, see
[`config.advanced.example.json`](../config.advanced.example.json) and copy in only the keys you
want to override.

> The string `"auto"` anywhere means **"let the stack pick the default"** — a default path, the
> machine's hostname, a derived donor id, and so on.

---

## Changing settings later

1. Edit `config.json`.
2. Run `./pithead apply`.

`apply` is designed to be safe to run anytime:

- It **previews exactly what will change**, diffing your edited `config.json` against the running
  configuration.
- It **warns before anything disruptive** — switching the Monero node local↔remote, toggling
  pruning, changing a payout address, exposing the RPC to your LAN, or moving a data directory all
  trigger a confirmation prompt.
- It then regenerates the `.env`, Caddy, and Tari configs and recreates **only** the containers
  that actually need it.
- It does **not** re-provision Tor, touch GRUB, or rotate the proxy token. If nothing changed, it
  does nothing.

```bash
# edit config.json, then:
./pithead apply        # shows the changes and asks before disruptive ones
./pithead apply -y     # skip the confirmation prompt (for scripting)
```

For example, to switch P2Pool from `main` to `mini`, or to flip the dashboard from HTTPS to
plain HTTP, edit `config.json` and run `./pithead apply`.

---

## Configuration reference

> **Only `monero.wallet_address` and `tari.wallet_address` are required.** Everything below is
> optional and has a sensible default — add a key only when you want to change its behavior.

| Key | Default | Description |
|---|---|---|
| `monero.mode` | `local` | `local` runs the bundled Monero node; `remote` connects to an external node (see `monero.remote`). |
| `monero.wallet_address` | _required_ | Your Monero payout address — must be a **primary/standard** address (starts with `4`, 95 chars). **Subaddresses (`8…`) and integrated addresses are _not_ supported**: p2pool pays via coinbase, which can't send to them, and XvB credits by this address — a wrong type mines but is never paid. `setup`/`apply` reject the wrong type, and `doctor` flags it. |
| `monero.node_username` / `node_password` | _auto (local)_ | Credentials for the local node's RPC, used only inside the stack (monerod, p2pool, and the dashboard, which reads the node's `get_info` for sync status). **Leave them blank** — on `setup` and on every `apply`, the stack fills in anything missing (username `admin`, a random alphanumeric password) and writes the values back into `config.json`, so they stay stable and you can see what was set. Set these yourself only for a **remote** node that requires RPC auth. |
| `monero.prune` | `true` | Prune the Monero blockchain to save disk space. The dashboard's Monero panel shows the resulting **Pruned**/**Full** mode and the node's on-disk DB size, so you can spot a config-vs-data mismatch when reusing a chain. |
| `monero.clearnet_initial_sync` | `false` | **Privacy-relevant, default off.** `true` makes monerod do its **initial block download over clearnet** (much faster than Tor) by dropping the Tor P2P `proxy=` and lowering `out-peers` to 16; transaction broadcast **stays on Tor** and wallets are never exposed. Your node's **IP becomes visible** to the Monero P2P network while it's on, and `pithead` warns loudly (apply/status/doctor/up) the whole time. **The dashboard switches monerod back to Tor automatically once the chain is synced** (#234) and keeps it there — you can leave this `true`. Full threat model: [Privacy › Optional clearnet initial sync](privacy.md#optional-clearnet-initial-sync-off-by-default). |
| `monero.prep_blocks_threads` | `auto` | Block-verification threads during sync. `auto` = host cores − 2, clamped to 4–8. |
| `monero.rpc_lan_access` | `false` | `true` publishes the node's RPC on the LAN (`0.0.0.0`) for wallets on other machines; default is localhost-only. |
| `monero.remote.host` / `rpc_port` / `zmq_port` | — / `18081` / `18083` | Remote node connection details (used when `mode` is `remote`). |
| `monero.data_dir` | `auto` | Where the Monero blockchain lives on the host. `auto` = `./data/monero`. Point this at an existing `.bitmonero` directory to reuse a synced node — see [Reusing an existing node](#reusing-an-existing-node). |
| `monero.mem_limit` | `auto` | Upper limit on the monerod container's memory, so a leak/runaway OOM-restarts monerod alone instead of the host's OOM-killer picking a victim. `auto` is a generous ceiling (**6 GB**) that won't trip during normal operation **or initial sync** — monerod's OOM-triggering memory is small (~0.1 GiB at rest, ~1–3 GiB during sync) while its multi-GB blockchain DB is reclaimable, memory-mapped page cache that the kernel evicts under pressure rather than OOM-killing. Lower it only to free RAM; **raise it** for a **full (unpruned) node** doing a heavy initial sync on a fast disk, or if a low-RAM host ever OOMs monerod during IBD (it restarts and resumes — the on-disk chain is transactional, no data loss). Accepts any Docker memory value, e.g. `"8g"`. (Tari has its own `tari.mem_limit`; the dashboard, P2Pool, Tor, and the proxies are small and carry fixed conservative ceilings in `docker-compose.yml`.) |
| `tari.wallet_address` | _required_ | Your Tari (Minotari) payout address. |
| `tari.clearnet_initial_sync` | `false` | **Privacy-relevant, default off.** `true` makes the Tari base node sync over **clearnet** instead of Tor — it switches the P2P transport to TCP, re-enables the `seeds.tari.com` DNS seed (the bundled onion `peer_seeds` are unreachable without Tor), and stops advertising its onion. Your node's **IP becomes visible** to the Tari P2P network while it's on, plus one DNS lookup of `seeds.tari.com`. `pithead` warns loudly (apply/status/doctor/up). **The dashboard switches Tari back to Tor automatically once it's synced** (#234) — you can leave this `true`. Full threat model: [Privacy › Optional clearnet initial sync](privacy.md#optional-clearnet-initial-sync-off-by-default). |
| `tari.data_dir` | `auto` | Where the Tari node data lives on the host. `auto` = `./data/tari`. |
| `tari.mem_limit` | `auto` | Upper limit on the Tari container's memory, so a runaway Tari restarts cleanly on its own instead of dragging down the whole host. `auto` picks a safe size for your machine — leave it unless you want to give Tari less RAM (to free it for other apps) or more (if it ever restarts too often). Accepts any Docker memory value, e.g. `"8g"`. |
| `p2pool.pool` | `main` | Which P2Pool sidechain to mine: `main`, `mini`, or `nano`. **Lower hashrate? Pick `mini` (or `nano`).** They have a lower share difficulty, so you find shares far more often — smoother, more frequent PPLNS payouts instead of long dry spells. `main` suits high hashrate; `mini`/`nano` suit typical home rigs. |
| `p2pool.stratum_bind` | `0.0.0.0` | Host **bind address** for the stratum port (`3333`) your rigs connect to — a single IPv4 address (maps to Docker's port-publish host IP), **not** a subnet/CIDR. Default `0.0.0.0` reaches the whole LAN out of the box; set a specific LAN IP (e.g. `192.168.1.10`) to limit it to one interface, or `127.0.0.1` to disable LAN access entirely. To restrict _which source subnet_ may connect, use a firewall — see [Connecting Miners › Firewall](workers.md#firewall). |
| `p2pool.stratum_password` | `""` _(off)_ | Optional **password every rig must send** to mine through the proxy — turns the otherwise-open `3333` port into authenticated stratum. `""` (default) = no password, any rig may connect. `"auto"` = generate a random secret once and keep it stable (shown after `setup`/`apply` and stored in `.env`); set it as each rig's stratum `pass`. Any literal string = use exactly that password. Only devices that know the secret can mine — which also shrinks the worker-name [SSRF](workers.md#authentication) surface. The password is sent **in cleartext** over stratum, so this is access control ("who may mine"), **not** encryption — pair it with `stratum_bind`/a firewall. See [Connecting Miners › Authentication](workers.md#authentication). |
| `p2pool.clearnet` | `false` | **Privacy-relevant, default off (Tor).** P2Pool's `--onion-address` only advertises an onion for _inbound_ peers; its _outbound_ sidechain dials need a SOCKS proxy or they go over **clearnet, exposing your home IP**. Default (`false`) routes those dials through the bundled Tor proxy (`--socks5 <tor>:9050 --socks5-proxy-type tor`). Set `true` to dial peers **directly over clearnet** for maximum yield — Tor latency raises the stale/uncle-share rate and onion-only shrinks the peer set, both worse on `--mini`/`--nano`, so a high-variance small rig may prefer clearnet (at the cost of IP exposure). Full threat model: [Privacy › P2Pool outbound peers](privacy.md#p2pool-outbound-peers-165--tor-by-default). |
| `p2pool.data_dir` | `auto` | Where P2Pool data lives on the host. `auto` = `./data/p2pool`. |
| `proxy.donate_level` | `0` | xmrig-proxy's built-in **dev-fee donation** to the xmrig developers, as a percentage of submitted hashrate. Defaults to **`0` — no donation** (xmrig-proxy's own compiled-in default, which the stack now renders explicitly so it's visible rather than invisible). Set an integer `1`–`99` to donate that share to the xmrig devs if you want to support them. **This is not the XvB donation** — that's the separate `xvb.*` mechanism the optimizer steers, never this dev fee. |
| `xvb.enabled` | `true` | Enable XMRvsBeast bonus-round hashrate switching. |
| `xvb.url` | `na.xmrvsbeast.com:4247` | XMRvsBeast pool endpoint. |
| `xvb.donor_id` | `auto` | XvB donor id. `auto` = the first 8 characters of your Monero address. |
| `xvb.donation_level` | `auto` | Donation tier to target: `auto` (the highest tier your hashrate can sustain) or a specific tier — **`donor` (1 kH/s) / `vip` (10 kH/s) / `whale` (100 kH/s) / `mega` (1 MH/s)** — where the figure is the donation hashrate you must hold on both your 1h and 24h averages. A specific tier is honored even if your hashrate can't hold it — the dashboard shows a warning badge in that case. (The `vip` tier is a donation level, not the dashboard's separate **Raffle Eligible** status; see [Architecture › Algorithmic switching](architecture.md#algorithmic-switching).) |
| `xvb.tor` | `true` | **Privacy-relevant, default on (Tor).** While donating, the proxy connects to `na.xmrvsbeast.com` — which would otherwise **expose your home IP** to XvB. Default (`true`) routes that connection through the bundled Tor proxy (a per-pool `socks5` on the XvB pool; DNS resolved proxy-side). Set `false` to dial **direct over clearnet** for maximum yield — stratum-over-Tor adds latency that can raise rejected shares (scales with hashrate). Only the XvB pool is affected; your local p2pool stratum is unaffected. Full threat model: [Privacy › XvB donation mining](privacy.md#xvb-donation-mining-166--tor-by-default). |
| `tor.data_dir` | `auto` | Where Tor's state (including onion keys) lives. `auto` = `./data/tor`. |
| `dashboard.secure` | `true` | `true` serves the dashboard over HTTPS (Caddy `tls internal`); `false` uses plain HTTP. |
| `dashboard.host` | `auto` | Hostname you use to reach the dashboard. `auto` = this machine's hostname. |
| `dashboard.auth.username` | `admin` | Login name for the dashboard when a password is set (see below). Letters, digits, and `. _ @ -`, 1–64 chars. Ignored while `dashboard.auth.password` is empty. |
| `dashboard.auth.password` | `""` _(off)_ | Optional **password to open the dashboard** — turns on a Caddy [HTTP basic-auth](https://caddyserver.com/docs/caddyfile/directives/basic_auth) prompt in front of every page. `""` (default) = **no login**, anyone who can reach the dashboard sees it (fine for a private LAN appliance). Any 8–128-character string (no double-quotes) turns the prompt on. The plaintext lives **only in your owner-only `config.json`**; pithead bcrypt-hashes it with the pinned Caddy image and stores **only the hash** in `.env`, so the password itself is never persisted in rendered state. Basic-auth credentials travel in cleartext over HTTP, so keep `dashboard.secure: true` (the default) — pithead warns if you set a password with `secure: false`. See [Exposing the dashboard safely](#exposing-the-dashboard-safely). |
| `dashboard.timezone` | `auto` | Timezone for the dashboard's timestamps and charts. `auto` = **the host machine's timezone** (auto-detected, falling back to `Etc/UTC`); set an IANA name (e.g. `America/Chicago`) to override. |
| `dashboard.data_dir` | `auto` | Where the dashboard's database lives. `auto` = `./data/dashboard`. |
| `dashboard.check_for_updates` | `true` _(on)_ | The dashboard periodically asks GitHub whether a **newer Pithead release** exists and, if so, shows a header badge linking to it (e.g. "New release v1.4.0 available"). **Notify-only** — it never updates anything; you upgrade with `./pithead upgrade` on your own terms. **On by default** because the check is **routed over Tor** (the same bridge SOCKS as the XvB fetch, `socks5h` so the DNS lookup goes through Tor too) — GitHub sees a Tor exit, not your IP, so it's a privacy-safe default. It's cached (hourly) and fails silently offline. Set to `false` to opt out entirely. See [Privacy › Runtime egress](privacy.md#runtime-egress). |
| `dashboard.tari_required` | `true` | How much a Tari problem holds up the rest of the stack. Monero is **required** to mine, so its behavior isn't configurable: a monerod outage always rejects workers (stops `xmrig-proxy` so miners **fail over to their backup pools**), and the miner is always held until monerod finishes syncing. Tari is **only needed for merge mining**, so this one flag decides how much it blocks. **`true` (default):** a Tari outage also rejects workers, the miner waits for Tari's initial sync too, and a Tari-only (re)sync shows the full-screen Sync view. **`false` (non-blocking):** keep mining Monero through a Tari outage, start mining as soon as Monero is synced (Tari finishes in the background), and keep the normal dashboard — with a `Tari syncing` indicator — instead of the takeover screen. |
| `network.subnet` | `172.28.0.0/24` | The private Docker bridge the stack's containers run on. Change it **only** if install fails with `Pool overlaps with other one on this address space` — i.e. your host already uses `172.28.0.0/24` for another Docker network or interface. Must be a free **`X.Y.Z.0/24`** block (e.g. `"172.30.0.0/24"`); the services keep their fixed host octets (`.25`–`.31`) within it, so the structured addressing the dashboard and the worker SSRF guard rely on is preserved. |
| `network.tor_egress_firewall` | `true` _(on)_ | **Privacy-relevant, default on.** Enforces "behind Tor" **fail-closed**: at `up`/`apply`, `pithead` installs host firewall rules (Docker's `DOCKER-USER` chain) that **drop any direct clearnet dial** from the mining containers (monerod/p2pool/tari/xmrig-proxy) — only the Tor container reaches the internet, so a misconfigured or buggy daemon can't leak your IP. Needs root (like the GRUB/HugePages steps); removed at `down`. Set `false` to skip it and rely on per-app Tor config only (e.g. a host where you manage egress yourself, or where `iptables` isn't available). Full detail: [Privacy › Enforced fail-closed](privacy.md#enforced-fail-closed-not-just-configured-270). |
| `workers.api_auth` | `none` | **How the dashboard reads each worker's xmrig API.** Beyond what the proxy reports, the dashboard probes every connected miner's own xmrig HTTP API (`/1/summary`) for uptime and per-miner hashrate — **one** configured way, no auto-detection. `none` (default) expects an **open, read-only** API (xmrig `http.restricted` with no `access-token`), which is what a stock RigForge worker exposes. `name` sends the worker's **stratum name** as the Bearer token (for miners whose `access-token` equals their name). `token` sends a single shared `workers.api_token` for every worker. A worker whose probe fails isn't dropped — it keeps its proxy-reported hashrate and is flagged **`api ⚠`** on the dashboard, with one log line explaining why (so a misconfigured API is distinct from an offline miner). **Upgrading from a build whose miners set an `access-token`?** Set this to `name` (or reprovision the miners to drop the token), otherwise the default no-auth probe `401`s and every worker shows `api ⚠`. |
| `workers.api_token` | `""` | The single shared Bearer token used when `workers.api_auth` is `token`. Ignored otherwise. |
| `workers.api_port` | `8080` | TCP port the worker xmrig API listens on. Change only if your miners expose the API on a non-standard port. |

---

### XvB raffle auto-registration (`XVB_SUBMIT_URL`)

When XvB is enabled, the stack **auto-registers your wallet in the XMRvsBeast raffle** once you have a P2Pool PPLNS share — no manual signup ([FAQ](faq.md#do-i-have-to-sign-up-for-the-xvb-raffle)). The registration call carries your **full** wallet address and is routed over Tor like the XvB stats fetch, so it never exposes your IP ([Privacy › Runtime egress](privacy.md#runtime-egress)).

The registration endpoint is **deliberately unpublished** by the XvB operator, so it is **not** a `config.json` key and ships **empty** — registration is supplied out-of-band via the `XVB_SUBMIT_URL` environment variable (set it in the dashboard service's env / `.env`). It re-registers on a daily cadence and is idempotent. The dashboard surfaces the result as a header badge:

- **`XvB raffle ✓`** — registered.
- **`⚠ XvB raffle not configured`** — XvB is on but `XVB_SUBMIT_URL` is unset, so the stack mines/donates but never enters the raffle (also logged once at WARNING).
- **`⚠ XvB registration failing`** — the endpoint is configured but keeps refusing despite a PPLNS share.

Leave `XVB_SUBMIT_URL` unset to disable auto-registration entirely (everything else still works); set `xvb.enabled: false` to stop all XvB activity.

## Data directories

Every stateful service stores its data in a host directory that you can place anywhere. By
default each one lives under `./data/<service>` inside the repo:

| Service | Config key | Default path | Mounted in container at |
|---|---|---|---|
| Monero | `monero.data_dir` | `./data/monero` | `/root/.bitmonero` |
| Tari | `tari.data_dir` | `./data/tari` | `/var/tari/node` |
| P2Pool | `p2pool.data_dir` | `./data/p2pool` | `/root` |
| Tor | `tor.data_dir` | `./data/tor` | `/var/lib/tor` |
| Dashboard | `dashboard.data_dir` | `./data/dashboard` | `/data` |

Set any `data_dir` to an absolute path to move that service's storage — for example, to put the
Monero blockchain on a dedicated SSD:

```json
{
    "monero": {
        "mode": "local",
        "wallet_address": "...",
        "data_dir": "/mnt/ssd/monero"
    }
}
```

Then run `./pithead apply`. Moving a data directory is treated as a disruptive change, so
`apply` confirms before recreating the affected container. `apply` creates any missing directory
and sets ownership automatically (Monero/Tari/P2Pool to your user, Tor to the container's user).

> **Note:** `apply` does **not** copy your existing data into a new location — it only points the
> container at the new path. If you're relocating data you already have, move the files yourself
> first (with the stack stopped), then update `data_dir` and run `apply`.

---

## Exposing the dashboard safely

The dashboard is designed for a **trusted private network** — the home or office LAN the appliance
sits on. By default it has no login: anyone who can reach the host can open it. That's the right
trade-off for a single-user box behind your router, and it stays the default.

You should add a login (and keep HTTPS on) whenever the dashboard is reachable by anyone you don't
fully trust — for example:

- the machine is **shared** (a co-hosted home server other people use), or
- you've **port-forwarded / reverse-proxied** the dashboard so it's reachable from outside the LAN, or
- you simply want a second layer in front of it.

Turn it on by setting a password in `config.json` and running `./pithead apply`:

```json
{
    "dashboard": {
        "secure": true,
        "auth": { "username": "admin", "password": "a-long-passphrase" }
    }
}
```

How it works and what to keep in mind:

- **The password is bcrypt-hashed, never stored in cleartext.** pithead hashes it with the **same
  pinned Caddy image** the stack already runs (`caddy hash-password`) and writes **only the hash** to
  `.env`. The plaintext exists only in your owner-only `config.json` — treat that file like any other
  secret (it's already git-ignored). The hash is stable across `apply` runs and only re-computed when
  you actually change the password, so the Caddyfile doesn't churn.
- **Keep `dashboard.secure: true`.** Basic-auth sends the credentials with every request; over plain
  HTTP (`secure: false`) they'd travel in cleartext. pithead **warns** if you set a password without
  HTTPS, but won't stop you. With the default `tls internal`, Caddy serves a locally-trusted
  certificate — your browser will warn the first time unless you trust Caddy's local CA.
- **A login is access control for the _dashboard_, not the miner.** It gates the web UI only. The
  stratum port miners connect to is a separate surface — gate that with
  [`p2pool.stratum_password`](#configuration-reference) and `p2pool.stratum_bind`.
- **Exposing to the public internet is still discouraged.** A password plus HTTPS is the right
  baseline, but the safest remote-access path remains a VPN / SSH tunnel / Tailscale back to the LAN
  rather than a forwarded port. Basic-auth has no rate-limiting or lockout on its own.

To remove the login again, clear the password (`"password": ""`) and `apply` — pithead drops the
`basic_auth` block and the dashboard is open on the LAN as before.

---

## Reusing an existing node

If you already run a synced Monero node, you can skip most — or all — of the initial blockchain
sync. There are two ways to do it.

> **No existing node, but the over-Tor first sync is too slow?** You don't have to reuse a chain —
> you can sync the bundled nodes over **clearnet** for the one-time initial download, then switch back
> to Tor. It's a default-off, privacy-relevant opt-in: see
> [`monero.clearnet_initial_sync` / `tari.clearnet_initial_sync`](#configuration-reference) and the
> full [threat model in Privacy](privacy.md#optional-clearnet-initial-sync-off-by-default).

### Option A — Point the bundled node at your existing blockchain

The Monero data directory mounts to `/root/.bitmonero` inside the container, the same layout a
standard `monerod` uses. To have the bundled node adopt a blockchain you've already downloaded,
point `monero.data_dir` at your existing `.bitmonero` directory:

```json
{
    "monero": {
        "mode": "local",
        "wallet_address": "...",
        "data_dir": "/home/me/.bitmonero"
    }
}
```

Then run `./pithead apply`. The bundled `monerod` reuses the blockchain in place — no re-sync
from genesis, just a quick catch-up of any blocks produced since your node last ran.

A few things to keep in mind:

- **Stop your other node first.** Two `monerod` processes must never use the same data directory
  at the same time, or they'll corrupt the database.
- **Match the prune setting.** A pruned blockchain needs `monero.prune: true` (the default); an
  unpruned (full) blockchain needs `monero.prune: false`. They're not interchangeable.
- **Ownership.** The host directory must be readable/writable by the user that runs the stack.
  `apply` sets ownership on directories it creates, but won't change an existing tree out from
  under you.

### Option B — Connect to a remote node

If your existing Monero node runs on another machine — or you want to use a node you don't host —
switch to **remote mode** and the stack won't run its own `monerod` at all. See
[Connecting to a remote Monero node](#connecting-to-a-remote-monero-node) below.

> **Tari** uses the same mechanism: point `tari.data_dir` at an existing Minotari node directory
> (mounted at `/var/tari/node`) to reuse its synced chain.

---

## Connecting to a remote Monero node

To connect to an external Monero node instead of running one locally, set `monero.mode` to
`remote` and fill in `monero.remote`:

```json
{
    "monero": {
        "mode": "remote",
        "wallet_address": "...",
        "remote": {
            "host": "node.example.com",
            "rpc_port": 18081,
            "zmq_port": 18083
        }
    }
}
```

- The bundled `monerod` container is not started in remote mode.
- The remote node must be set up for **P2Pool mining** — with **ZMQ publishing enabled**
  (`zmq-pub`, port `18083` by default) and its RPC reachable by P2Pool. In practice that means a
  node **you run and control**; general-purpose public "open node" endpoints do **not** work,
  since they don't expose ZMQ.
- If the remote node requires RPC authentication, set `monero.node_username` / `node_password`
  to match it; otherwise leave them out.

Switching between `local` and `remote` is a disruptive change, so `apply` will confirm before
applying it.

---

## See also

- [Operations & Maintenance](operations.md) — the full `pithead` command reference and
  troubleshooting.
- [Architecture](architecture.md) — how the services use these settings, and the XvB switching
  engine behind `xvb.*`.
