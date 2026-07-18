# Configuration

`config.json` is the stack's only config file. `./pithead setup` writes a minimal one, asking only
for what only you can answer plus a few high-level shape questions — see
[Getting Started › Run setup](getting-started.md#3-run-setup) for the exact list. Everything else
keeps its default below; edit `config.json` directly for anything the wizard doesn't ask. To change
the stack afterward, edit `config.json` and run `./pithead apply`.

## The minimal config

The two wallet addresses are the only required keys. Every other key is optional and falls back to a
default: the node runs locally, on the `mini` pool, with a secure dashboard, and the local node's RPC
credentials are auto-generated. Omit a key to keep its default.

A fresh `config.json` is this (see [`config.minimal.json`](../config.minimal.json)):

```json
{
    "monero": {
        "wallet_address": "your_monero_wallet_address"
    },
    "tari": {
        "wallet_address": "your_tari_wallet_address"
    },
    "p2pool": {
        "stratum_password": "auto"
    }
}
```

The `stratum_password` line turns on [stratum authentication](workers.md#authentication) for new
installs (#208): the stack generates a stable secret, prints it after `setup`/`apply`, and rigs
connect with it as their stratum `pass` (RigForge's setup prompts for it). It is explicit here —
not a hidden default — so an install that predates it keeps its open-`:3333` behavior on upgrade;
delete the line (or set `""`) to run unauthenticated on a trusted LAN.

For every key and its default, see [`config.reference.json`](../config.reference.json) and copy in
only the keys you want to override.

> The string `"auto"` means "let the stack pick the default": a default path, the machine's
> hostname, a derived donor id, and so on.

---

## Changing settings later

1. Edit `config.json`.
2. Run `./pithead apply`.

`apply` is safe to run anytime:

- It previews what will change, diffing your edited `config.json` against the running configuration.
- It prompts to confirm before anything disruptive: switching the Monero node local↔remote, toggling
  pruning, changing a payout address, exposing the RPC to your LAN, or moving a data directory.
- It regenerates the `.env`, Caddy, and Tari configs and recreates only the containers that need it.
- It does not re-provision Tor, touch GRUB, or rotate the proxy token. If nothing changed, it does
  nothing.

```bash
# edit config.json, then:
./pithead apply        # shows the changes and asks before disruptive ones
./pithead apply -y     # skip the confirmation prompt (for scripting)
```

For example, to switch P2Pool from `main` to `mini`, or to flip the dashboard from HTTPS to
plain HTTP, edit `config.json` and run `./pithead apply`.

---

## Configuration reference

> Only `monero.wallet_address` and `tari.wallet_address` are required. Everything below is optional
> and has a default. Add a key only when you want to change its behavior.

The table below has ~94 keys across 13 sections — most of it you'll never touch. A handful of keys
are **core**: wallet addresses, `monero.mode`, `p2pool.pool`, the dashboard login and host, and
`workers.list` — the ones `./pithead setup` asks about (see
[Getting Started › Run setup](getting-started.md#3-run-setup)) and, if `dashboard.control.enabled`
is on, the group the dashboard's [Configuration view](dashboard.md#configuration-view) pins at the
top of its form. Both read the exact same list, [`config.core-keys.json`](../config.core-keys.json)
— there's only ever one shortlist to keep in sync with this table, not two.

Below the core group, the Configuration view groups the rest of this table into **logical
sections** an operator recognizes (Wallets & payout, Monero node, Mining, Workers, Dashboard &
access, Notifications, Energy, Alerts & thresholds, System / advanced), each collapsed by default
— not one section per top-level key like this table's own layout, so a key like `dashboard.energy`
lands in "Energy" and `dashboard.auth` lands in "Dashboard & access" rather than sharing a section
just because they share a JSON prefix. It also greys out any key the dashboard's control channel
can't actually commit — most of them, including every credential and every setting listed as
"Security-relevant" or requiring `./pithead apply` below — instead of letting you edit it and
finding out only when Save is rejected. Both are display-only: `config.json` itself, and what the
control channel will commit, are unaffected either way.

| Key | Default | Description |
|---|---|---|
| `monero.mode` | `local` | `local` runs the bundled Monero node; `remote` connects to an external node (see `monero.remote`). |
| `monero.wallet_address` | _required_ | Your Monero payout address. Must be a primary/standard address (starts with `4`, 95 chars). Subaddresses (`8…`) and integrated addresses are not supported: p2pool pays via coinbase, which can't send to them, and XvB credits by this address. A wrong type mines but is never paid. `setup`/`apply` reject the wrong type, and `doctor` flags it. |
| `monero.node_username` / `node_password` | _auto (local)_ | Credentials for the local node's RPC, used only inside the stack (monerod, p2pool, and the dashboard, which reads the node's `get_info` for sync status). Leave them blank. On `setup` and on every `apply`, the stack fills in anything missing (username `admin`, a random alphanumeric password) and writes the values back into `config.json`, so they stay stable and you can see what was set. Set these yourself only for a remote node that requires RPC auth. |
| `monero.view_key` | _empty_ | The private **view** key for `monero.wallet_address`, to confirm payouts on-chain. When set, the stack runs a view-only `monero-wallet-rpc` against your local node and the dashboard shows confirmed payouts beside the earnings estimate (see [Dashboard › Payout confirmation](dashboard.md#payout-confirmation)). **Security:** a view key can scan but never spend — yet it reveals every incoming amount and its timing to anyone who can read `config.json`/`.env`, so it is handled like `node_password` (never logged or echoed, kept in the owner-only `.env`). Local node only: setting it with `mode: remote` is rejected. Empty (the default) leaves the feature off — nothing new runs. To rotate, replace it with a fresh view key. |
| `monero.payout_scan_height` | `auto` | Block height the view-only wallet starts scanning from on first creation (#381). `auto` = the node's current height when the wallet is first made, so it tracks payouts forward without rescanning years of chain. Set an earlier height to backfill older payouts (slower first scan). Only affects the first wallet creation; ignored once the wallet file exists. |
| `monero.prune` | `true` | Prune the Monero blockchain to save disk space. The dashboard's Monero panel shows the resulting Pruned/Full mode and the node's on-disk DB size, so you can spot a config-vs-data mismatch when reusing a chain. A pruned node still confirms payouts — coinbase outputs are never pruned. |
| `monero.clearnet_initial_sync` | `false` | Privacy-relevant, default off. `true` makes monerod do its initial block download over clearnet (much faster than Tor) by dropping the Tor P2P `proxy=` and lowering `out-peers` to 32. Transaction broadcast stays on Tor and wallets are never exposed. Your node's IP becomes visible to the Monero P2P network while it's on, and `pithead` warns loudly (apply/status/doctor/up) the whole time. The dashboard switches monerod back to Tor automatically once the chain is synced (#234) and keeps it there, so you can leave this `true`. Full threat model: [Privacy › Optional clearnet initial sync](privacy.md#optional-clearnet-initial-sync-off-by-default). |
| `monero.prep_blocks_threads` | `auto` | Block-verification threads during sync. `auto` = host cores − 2, clamped to 4–8. |
| `monero.out_peers` | `48` | monerod's outbound peer target (8–1024). Over Tor each outbound peer is roughly one long-lived circuit, so this is the main steady-state lever on Tor's CPU (#595). Keep the default while syncing (more peers = more download bandwidth over Tor); once synced, `32` — the count P2Pool recommends for clearnet — cuts monerod's circuit maintenance by a third. |
| `monero.rpc_lan_access` | `false` | `true` publishes the node's RPC on the LAN (`0.0.0.0`) for wallets on other machines; default is localhost-only. |
| `monero.remote.host` / `rpc_port` / `zmq_port` | — / `18081` / `18083` | Remote node connection details (used when `mode` is `remote`). |
| `monero.data_dir` | `auto` | Where the Monero blockchain lives on the host. `auto` = `./data/monero`. Point this at an existing `.bitmonero` directory to reuse a synced node. See [Reusing an existing node](#reusing-an-existing-node). |
| `monero.mem_limit` | `auto` | Upper limit on the monerod container's memory, so a leak/runaway OOM-restarts monerod alone instead of the host's OOM-killer picking a victim. `auto` is a generous ceiling (6 GB) that won't trip during normal operation or initial sync. monerod's OOM-triggering memory is small (~0.1 GiB at rest, ~1–3 GiB during sync) while its multi-GB blockchain DB is reclaimable, memory-mapped page cache that the kernel evicts under pressure rather than OOM-killing. Lower it only to free RAM. Raise it for a full (unpruned) node doing a heavy initial sync on a fast disk, or if a low-RAM host ever OOMs monerod during IBD (it restarts and resumes; the on-disk chain is transactional, no data loss). Accepts any Docker memory value, e.g. `"8g"`. (Tari has its own `tari.mem_limit`; the dashboard, P2Pool, Tor, and the proxies are small and carry fixed conservative ceilings in `docker-compose.yml`.) |
| `tari.wallet_address` | _required_ | Your Tari (Minotari) payout address. |
| `tari.view_key` | _empty_ | The private **view** key for the Tari payout address, to confirm merge-mine payouts on-chain (#462, the Tari sibling of `monero.view_key`). When set, the stack runs a view-only `minotari_console_wallet` against your local Tari node and the dashboard shows confirmed Tari payouts beside the time-to-block estimate (see [Dashboard › Payout confirmation](dashboard.md#payout-confirmation)). Requires `tari.spend_public_key` too. **Security:** a view key can scan but never spend — yet it reveals every incoming amount and its timing to anyone who can read `config.json`/`.env`, so it is handled like `node_password` (never logged or echoed, kept in the owner-only `.env`, and delivered to the container via a tmpfs secret, never `docker inspect`). Local Tari node only. Empty (the default) leaves the feature off. |
| `tari.spend_public_key` | _empty_ | The **public** spend key for the Tari payout address, exported alongside the view key (`minotari_console_wallet ... export-view-key-and-spend-key`; see [Dashboard › Exporting your keys](dashboard.md#exporting-your-keys)). Required whenever `tari.view_key` is set — a view-only Tari wallet is built from the private view key plus this public spend key. Public, not a secret. |
| `tari.payout_scan_birthday` | `auto` | Where the view-only Tari wallet starts scanning on first creation (#462). Unlike Monero's block-height restore point, a Tari birthday is **days since the Unix epoch** (a u16, 0–65535). `auto` = today when the wallet is first made, so it tracks payouts forward without rescanning from genesis. Set an earlier day to backfill older payouts (slower first scan). Only affects the first wallet creation; ignored once the wallet exists. |
| `tari.clearnet_initial_sync` | `false` | Privacy-relevant, default off. `true` makes the Tari base node sync over clearnet instead of Tor: it switches the P2P transport to TCP, re-enables the `seeds.tari.com` DNS seed (the bundled onion `peer_seeds` are unreachable without Tor), and stops advertising its onion. Your node's IP becomes visible to the Tari P2P network while it's on, plus one DNS lookup of `seeds.tari.com`. `pithead` warns loudly (apply/status/doctor/up). The dashboard switches Tari back to Tor automatically once it's synced (#234), so you can leave this `true`. Full threat model: [Privacy › Optional clearnet initial sync](privacy.md#optional-clearnet-initial-sync-off-by-default). |
| `tari.data_dir` | `auto` | Where the Tari node data lives on the host. `auto` = `./data/tari`. |
| `tari.mem_limit` | `auto` | Upper limit on the Tari container's memory, so a runaway Tari restarts cleanly on its own instead of dragging down the whole host. `auto` picks a safe size for your machine. Leave it unless you want to give Tari less RAM (to free it for other apps) or more (if it ever restarts too often). Accepts any Docker memory value, e.g. `"8g"`. |
| `p2pool.pool` | `mini` | Which P2Pool sidechain to mine: `main`, `mini`, or `nano`. `mini` (the default) has a lower share difficulty than `main`, so a typical home rig finds shares far more often: smoother, more frequent PPLNS payouts instead of long dry spells. Raise to `main` for high hashrate (large farms); drop to `nano` for a single low-power rig. |
| `p2pool.stratum_bind` | `0.0.0.0` | Host bind address for the stratum port (`3333`) your rigs connect to. A single IPv4 address (maps to Docker's port-publish host IP), not a subnet/CIDR. Default `0.0.0.0` reaches the whole LAN with no setup; set a specific LAN IP (e.g. `192.168.1.10`) to limit it to one interface, or `127.0.0.1` to disable LAN access entirely. To restrict which source subnet may connect, use a firewall. See [Connecting Miners › Firewall](workers.md#firewall). |
| `p2pool.stratum_port` | `3333` | TCP port the stratum endpoint your rigs connect to is published on. Default `3333` is the standard path — leave it unless another service already holds the port on the host. Change it and **every rig must repoint** at the new port (RigForge: `pool.port`); `apply` flags the change as destructive because rigs on the old port can't connect until updated. Only the operator-facing published port moves; p2pool's container-internal stratum stays fixed at `3333` (nothing outside the stack touches it). See [Connecting Miners › Non-standard port](workers.md#non-standard-stratum-port). |
| `p2pool.stratum_password` | `""` _(off; new installs get `"auto"`)_ | Password every rig must send to mine through the proxy. Turns the otherwise-open `3333` port into authenticated stratum. `""` (the fallback for an absent key, which is what pre-#208 installs have) = no password, any rig may connect. `"auto"` = generate a random secret once and keep it stable (shown after `setup`/`apply` and stored in `.env`); set it as each rig's stratum `pass` — the wizard and `config.minimal.json` write this for every new install. Any literal string = use exactly that password. Only devices that know the secret can mine, which also shrinks the worker-name [SSRF](workers.md#authentication) surface. The password is sent in cleartext over stratum, so this is access control ("who may mine"), not encryption. Pair it with `stratum_bind`/a firewall. See [Connecting Miners › Authentication](workers.md#authentication). |
| `p2pool.stratum_tls` | `false` | Serve TLS on the stratum port (#261). Same port, per-connection detection: cleartext rigs keep mining while rigs opt in one at a time (`pools[].tls: true` + pinning the certificate's SHA-256 fingerprint, printed after `apply` and by `status`). The self-signed cert lives under the data root and keeps its fingerprint across upgrades; regenerating it (delete + `apply`) is the rotation. Confidentiality only — pair with `stratum_password` for access control. See [Connecting Miners › Stratum over TLS](workers.md#stratum-over-tls). |
| `p2pool.clearnet` | `false` | Privacy-relevant, default off (Tor). P2Pool's `--onion-address` only advertises an onion for inbound peers; its outbound sidechain dials need a SOCKS proxy or they go over clearnet, exposing your home IP. Default (`false`) routes those dials through the bundled Tor proxy (`--socks5 <tor>:9050 --socks5-proxy-type tor`). Set `true` to dial peers directly over clearnet for maximum yield: Tor latency raises the stale/uncle-share rate and onion-only shrinks the peer set, both worse on `--mini`/`--nano`, so a high-variance small rig may prefer clearnet (at the cost of IP exposure). Full threat model: [Privacy › P2Pool outbound peers](privacy.md#p2pool-outbound-peers-165---tor-by-default). |
| `p2pool.data_dir` | `auto` | Where P2Pool data lives on the host. `auto` = `./data/p2pool`. |
| `proxy.donate_level` | `0` | xmrig-proxy's built-in dev-fee donation to the xmrig developers, as a percentage of submitted hashrate. Defaults to `0`, no donation (xmrig-proxy's own compiled-in default, which the stack now renders explicitly so it's visible rather than invisible). Set an integer `1`–`99` to donate that share to the xmrig devs if you want to support them. This is not the XvB donation; that's the separate `xvb.*` mechanism the optimizer steers, never this dev fee. |
| `xvb.enabled` | `true` | Enable XMRvsBeast bonus-round hashrate switching. |
| `xvb.url` | `na.xmrvsbeast.com:4247` | XMRvsBeast pool endpoint. |
| `xvb.donor_id` | `auto` | XvB donor id. `auto` = the first 8 characters of your Monero address. |
| `xvb.donation_level` | `auto` | Donation tier to target: `auto` (the highest tier your hashrate can sustain) or a specific tier: `donor` (1 kH/s) / `vip` (10 kH/s) / `whale` (100 kH/s) / `mega` (1 MH/s), where the figure is the donation hashrate you must hold on both your 1h and 24h averages. A specific tier is honored even if your hashrate can't hold it; the dashboard shows a warning badge in that case. (The `vip` tier is a donation level, not the dashboard's separate Raffle Eligible status; see [Architecture › Algorithmic switching](architecture.md#algorithmic-switching).) |
| `xvb.tor` | `true` | Privacy-relevant, default on (Tor). While donating, the proxy connects to `na.xmrvsbeast.com`, which would otherwise expose your home IP to XvB. Default (`true`) routes that connection through the bundled Tor proxy (a per-pool `socks5` on the XvB pool; DNS resolved proxy-side). Set `false` to dial direct over clearnet for maximum yield: stratum-over-Tor adds latency that can raise rejected shares (scales with hashrate). Only the XvB pool is affected; your local p2pool stratum is unaffected. Full threat model: [Privacy › XvB donation mining](privacy.md#xvb-donation-mining-166---tor-by-default). |
| `tor.data_dir` | `auto` | Where Tor's state (including onion keys) lives. `auto` = `./data/tor`. |
| `tor.auto_heal` | `false` _(off)_ | Privacy-relevant, default off. Tor can bootstrap fully and then sit on a **failing guard**: circuits time out, so everything that exits Tor to the clearnet (Healthchecks pings, the Telegram bot, XvB stats) breaks at once while mining keeps working (#424). `true` lets the dashboard probe Tor clearnet egress every 5 minutes and restart the tor container once egress has been broken for 15 minutes, so Tor reselects guards — bounded to 3 restarts per outage, 30 minutes apart, each logged; if egress stays broken (Tor network overload) it stops restarting and keeps warning. Off by default because each restart drops **every** Tor circuit, mining onions included (they rebuild in minutes). The manual equivalent is `./pithead restart tor`. See [Operations › Troubleshooting](operations.md#troubleshooting). |
| `dashboard.secure` | `true` | `true` serves the dashboard over HTTPS (Caddy `tls internal`); `false` uses plain HTTP. |
| `dashboard.host` | `auto` | Hostname you use to reach the dashboard. `auto` = this machine's hostname. |
| `dashboard.auth.username` | `admin` | Login name for the dashboard when a password is set (see below). Letters, digits, and `. _ @ -`, 1–64 chars. Ignored while `dashboard.auth.password` is empty. |
| `dashboard.auth.password` | `""` _(off)_ | Optional password to open the dashboard. Turns on a Caddy [HTTP basic-auth](https://caddyserver.com/docs/caddyfile/directives/basic_auth) prompt in front of every page. `""` (default) = no login, anyone who can reach the dashboard sees it (fine for a private LAN appliance). Any 8–128-character string (no double-quotes) turns the prompt on. The plaintext lives only in your owner-only `config.json`; pithead bcrypt-hashes it with the pinned Caddy image and stores only the hash in `.env`, so the password itself is never persisted in rendered state. Basic-auth credentials travel in cleartext over HTTP, so keep `dashboard.secure: true` (the default); pithead warns if you set a password with `secure: false`. See [Exposing the dashboard safely](#exposing-the-dashboard-safely). |
| `dashboard.onion.enabled` | `false` _(off)_ | Privacy-relevant, default off. `true` publishes the dashboard as a Tor v3 onion service so you can reach it remotely over Tor — no port-forward, no VPN, no public IP. It fronts the authenticated Caddy login on the internal bridge, never the LAN. pithead **fails closed**: if no `dashboard.auth.password` is set it generates a strong one (saved to `config.json`, login `admin`); a password you set yourself must be at least 16 characters. See [Remote access over Tor](#remote-access-over-tor-onion-service). |
| `dashboard.onion.client_auth` | `true` _(on)_ | Only applies when `dashboard.onion.enabled` is `true`. Keeps Tor v3 **client authorization** on: the onion does not respond at all without your client key, so the address can't be scanned or brute-forced — the password becomes a second factor behind it. pithead generates the keypair and prints the client line via `./pithead onion-client-key`. Set to `false` for a deliberately password-only onion. |
| `dashboard.control.enabled` | `false` _(off)_ | Security-relevant, default off. `true` turns on the dashboard's **Configuration view**: edit `config.json` from the browser, preview the changes, and apply them. The dashboard container never runs `pithead` itself — it writes a typed change request into a spool directory and a root systemd unit on the host (`pithead-control`) validates and applies it (see [Dashboard › Configuration view](dashboard.md#configuration-view)). Fails closed: enabling it without a `dashboard.auth.password` is a validation error, because this channel can change the payout wallet. |
| `dashboard.timezone` | `auto` | Timezone for the dashboard's timestamps and charts. `auto` = the host machine's timezone (auto-detected, falling back to `Etc/UTC`); set an IANA name (e.g. `America/Chicago`) to override. |
| `dashboard.data_dir` | `auto` | Where the dashboard's database lives. `auto` = `./data/dashboard`, unless the four other `*.data_dir` all point under one parent directory — then the dashboard joins them at `<that parent>/dashboard`, and the first `upgrade`/`apply` moves data from the old default there automatically (see [Data directories](#data-directories)). |
| `dashboard.check_for_updates` | `true` _(on)_ | The dashboard periodically asks GitHub whether a newer Pithead release exists and, if so, shows a header badge linking to it (e.g. "New release v1.4.0 available"). Notify-only: it never updates anything; you upgrade with `./pithead upgrade` on your own terms. On by default because the check is routed over Tor (the same bridge SOCKS as the XvB fetch, `socks5h` so the DNS lookup goes through Tor too), so GitHub sees a Tor exit, not your IP. It's cached (hourly) and fails silently offline. Set to `false` to opt out entirely. See [Privacy › Runtime egress](privacy.md#runtime-egress). |
| `dashboard.hashrate_drop_threshold` | `50` | Percent below the recent normal that counts as a hashrate drop for the `hashrate_loss` alert and its chart marker. `50` = fire when total fleet hashrate falls to half its baseline. Raise it to catch smaller dips, lower it to only flag near-total outages. |
| `dashboard.hashrate_drop_minutes` | `10` | How many minutes the hashrate must stay below the threshold before the drop is reported — the debounce that keeps a brief blip from pinging you. |
| `dashboard.tari_required` | `true` | How much a Tari problem holds up the rest of the stack. Monero is required to mine, so its behavior isn't configurable: a monerod outage always rejects workers (stops `xmrig-proxy` so miners fail over to their backup pools), and the miner is always held until monerod finishes syncing. Tari is only needed for merge-mining, so this one flag decides how much it blocks. `true` (default): a Tari outage also rejects workers, the miner waits for Tari's initial sync too, and a Tari-only (re)sync shows the full-screen Sync view. `false` (non-blocking): keep mining Monero through a Tari outage, start mining as soon as Monero is synced (Tari finishes in the background), and keep the normal dashboard, with a `Tari syncing` indicator, instead of the takeover screen. |
| `network.subnet` | `172.28.0.0/24` | The private Docker bridge the stack's containers run on. Change it only if install fails with `Pool overlaps with other one on this address space`, i.e. your host already uses `172.28.0.0/24` for another Docker network or interface. Must be a free `X.Y.Z.0/24` block (e.g. `"172.30.0.0/24"`); the services keep their fixed host octets (`.25`–`.31`) within it, so the structured addressing the dashboard and the worker SSRF guard rely on is preserved. |
| `network.tor_egress_firewall` | `true` _(on)_ | Privacy-relevant, default on. Enforces "behind Tor" fail-closed: at `up`/`apply`, `pithead` installs host firewall rules (Docker's `DOCKER-USER` chain) that drop any direct clearnet dial from the mining containers (monerod/p2pool/tari/xmrig-proxy). Only the Tor container reaches the internet, so a misconfigured or buggy daemon can't leak your IP. Needs root (like the GRUB/HugePages steps); removed at `down`. Set `false` to skip it and rely on per-app Tor config only (e.g. a host where you manage egress yourself, or where `iptables` isn't available). Full detail: [Privacy › Enforced fail-closed](privacy.md#enforced-fail-closed-not-just-configured-270). |
| `workers.api_auth` | `none` | How the dashboard reads each worker's xmrig API. Beyond what the proxy reports, the dashboard probes every connected miner's own xmrig HTTP API (`/1/summary`) for uptime and per-miner hashrate, one configured way, no auto-detection. `none` (default) expects an open, read-only API (xmrig `http.restricted` with no `access-token`), which is what a stock RigForge worker exposes. `name` sends the worker's stratum name as the Bearer token (for miners whose `access-token` equals their name). `token` sends a single shared `workers.api_token` for every worker. A worker whose probe fails isn't dropped: it keeps its proxy-reported hashrate and is flagged `api ⚠` on the dashboard, with one log line explaining why (so a misconfigured API is distinct from an offline miner). Upgrading from a build whose miners set an `access-token`? Set this to `name` (or reprovision the miners to drop the token), otherwise the default no-auth probe `401`s and every worker shows `api ⚠`. |
| `workers.api_token` | `""` | The single shared Bearer token used when `workers.api_auth` is `token`. Ignored otherwise. |
| `workers.api_port` | `8080` | TCP port the worker xmrig API listens on. Change only if your miners expose the API on a non-standard port. |
| `workers.list` | `[]` | Per-worker overrides for the worker-API probe, a list of `{name, host?, port?, token?, watts?, control_port?}` objects. Only needed when one rig doesn't match the fleet defaults above — a different API port, an API on another interface (NAT / multi-homed), or its own token. Each field is optional bar `name` (the rig's stratum name). **Merge rule:** a per-worker field beats the fleet default (`workers.api_port`, `workers.api_auth`/`workers.api_token`), which beats the built-in default; unlisted rigs inherit the fleet defaults untouched. A per-worker `token` forces token-auth for that one rig, whatever the fleet `api_auth` mode. `watts` is a manual power-draw estimate for the [energy calculator](dashboard.md#energy--profit), used only for a rig whose enriched feed reports no measured watts. `control_port` (default `8082`) is the rig's writable control API port, used by [Worker Inspect](dashboard.md#worker-inspect) to push config changes — set it alongside `host` + `token` to make a rig editable. Matched by `name` first, then by connecting IP against an operator-set `host`; duplicate names → first-declared wins, so a renamed rig needs its entry updated. `host` **must** be operator-set here and is never derived from a miner-advertised value: the dashboard never sends a configured token to a miner-controlled host ([SSRF guard](workers.md#per-worker-overrides)). The standard fleet needs no entries. See [Connecting Miners › Per-worker overrides](workers.md#per-worker-overrides). `dashboard.workers` is a deprecated alias for this key (#506): still read if `workers.list` is unset, but setting both is refused at apply, and the old location is removed in v1.9. |
| `dashboard.energy.cost_per_kwh` | `0` _(off)_ | Your electricity price per kWh, for the dashboard's [energy & profit](dashboard.md#energy--profit) tab. `0` or unset shows fleet power draw and efficiency but hides the cost and profit math. Any positive number adds power cost per day/month/year; combine with `xmr_price` for net profit. In the `currency` label below. |
| `dashboard.energy.xmr_price` | `0` _(off)_ | The fiat price of 1 XMR, in your `currency`, for the net-profit figure (`P2Pool XMR earnings × this − power cost`). `0` or unset hides net profit (energy cost still shows if `cost_per_kwh` is set). **No price feed ships** — fetching an exchange rate is a clearnet request this stack avoids ([Privacy › Runtime egress](privacy.md#runtime-egress)) — so you supply the price yourself. This is the base gate for net profit: it's P2Pool XMR only unless `tari_price` is also set (#520). XvB (raffle status, not a per-day income estimate) is always excluded. |
| `dashboard.energy.tari_price` | `0` _(off)_ | The fiat price of 1 XTM, in your `currency` (#520). Once both this and `xmr_price` are set, net profit folds in the estimated Tari merge-mining revenue (same what-if Tari/day estimate the Tari tab shows) — the card's heading and Net/day tooltip say "P2Pool + Tari" so the figure is never silently P2Pool-only. `0` or unset (or Tari not currently merge-mining) keeps net profit P2Pool XMR only. Same no-price-feed reasoning as `xmr_price` — you supply it yourself. |
| `dashboard.energy.currency` | `USD` | Display label for `cost_per_kwh`, `xmr_price` and `tari_price` (e.g. `USD`, `EUR`). A label only — no conversion happens, so set all prices in the same currency. |
| `healthchecks.ping_url` | _(blank)_ | The full ping URL from Healthchecks.io (e.g. `https://hc-ping.com/<uuid>`) — the optional [dead-man's switch](monitoring.md) that alerts you when your host stops responding. **Setting it turns the monitor on; blank keeps it off.** Always pinged over Tor (every 60s), so it must be Tor-reachable (see [Monitoring › Privacy note](monitoring.md#privacy-note)). Treated as a secret — stored in the owner-only `.env`. |
| `telegram.enabled` | `false` | Push operational alerts (node down/recovered, worker offline/back, sync finished) to Telegram. Off by default. Requires `bot_token` + `chat_id` to actually send. Full walkthrough: [Telegram Bot](telegram.md). |
| `telegram.bot_token` | `""` | Your BotFather bot token. A secret — stored owner-only in `.env`, git-ignored, and never logged. Get one from [@BotFather](https://t.me/BotFather). |
| `telegram.chat_id` | `""` | Where alerts are sent and the only chat the command interface answers. A Telegram group id (negative, e.g. `-1001234567890`) or a personal chat id. See [how to find it](telegram.md#3-find-your-chat-id). |
| `telegram.events.*` | all `true` | Per-event toggles: `stack_online`, `node_down`, `node_recovered`, `worker_offline`, `worker_recovered`, `worker_joined`, `worker_left`, `sync_finished`, `disk_space`, `db_unhealthy`, `db_reset`, `xvb_no_share`, `xvb_registration`, `clearnet_exposed`, `new_release`, `daily_summary`, `hashrate_low`, `hashrate_loss`, `hugepages`, `low_ram`, `wallet_changed`, `high_reject_rate`, `block_found`, `payout_found`, `payout_confirmed`, `container_unhealthy`. Each defaults to on once Telegram is enabled; set one `false` to silence just that alert. Full list: [Telegram Bot](telegram.md#choosing-which-alerts-you-get). |
| `telegram.daily_summary_time` | `08:00` | Local time (24-hour `HH:MM`) to push the once-a-day status digest, when the `daily_summary` event is on. Uses the dashboard's timezone (`dashboard.timezone`). A malformed value disables the digest. |
| `telegram.commands.enabled` | `false` | Turn on the interactive command interface — the bot answers read-only status queries (`/status`, `/hashrate`, `/workers`, `/luck`, `/earnings`, and more) from the configured `chat_id` (every other chat is ignored). Off by default; alerts work without it. Long-polls over Tor, so it needs no inbound port. Full command list: [Telegram › Commands](telegram.md#commands). |
| `notifications.webhooks` | `[]` | Generic JSON webhook alert sinks (#380): every alert the stack produces is POSTed to each listed URL as `{"event", "text", "ts"}` — for Gotify, Home Assistant, or any endpoint that accepts a POST. Empty list keeps it off. The URLs are secrets (query strings often carry tokens): owner-only `.env`, never logged or printed. Sinks carry every event; `telegram.events` gates Telegram only. See [Telegram › Webhook and ntfy sinks](telegram.md#webhook-and-ntfy-sinks). |
| `notifications.ntfy.url` | `""` | An [ntfy](https://ntfy.sh) topic URL (`https://server/topic`, self-hosted servers included); each alert's text is POSTed as the message body. Blank keeps it off. Treated as a secret like the webhook URLs. Step-by-step setup: [Telegram › Setting up ntfy](telegram.md#setting-up-ntfy-step-by-step). |
| `notifications.ntfy.token` | `""` | Optional ntfy access token for a protected topic, sent as an `Authorization: Bearer` header. A secret — owner-only `.env`, never logged. |
| `notifications.tor` | `true` _(on)_ | Privacy-relevant, default on. Routes every webhook/ntfy POST over the bundled Tor SOCKS proxy, so the endpoint sees a **Tor exit, not your host IP** — the same egress rule as Telegram. Set `false` only for endpoints on your own network (Tor exits can't reach private addresses); a clearnet endpoint then sees your host IP on every alert. |

---

### XvB raffle auto-registration (`XVB_SUBMIT_URL`)

When XvB is enabled, the stack auto-registers your wallet in the XMRvsBeast raffle once you have a P2Pool PPLNS share, no manual signup ([FAQ](faq.md#do-i-have-to-sign-up-for-the-xvb-raffle)). The registration call carries your full wallet address and is always routed over Tor like the XvB stats fetch (it is not subject to the `xvb.tor` donation opt-out), so it never exposes your IP ([Privacy › Runtime egress](privacy.md#runtime-egress)). It re-registers on a daily cadence and is idempotent (re-running an already-entered wallet is a no-op).

The endpoint ships as the working default, so it is not a `config.json` key. Two `XVB_SUBMIT_URL` environment overrides exist for operators who need them:

- Set it to a URL to point registration at a different endpoint (e.g. a test server).
- Set it to a disable sentinel (`off` / `none` / `false` / `disabled` / `0`) to turn auto-registration off while keeping the rest of XvB running. (`xvb.enabled: false` stops _all_ XvB activity instead.)

The dashboard surfaces the result as a header badge:

- `XvB raffle ✓`: registered (or already entered).
- `⚠ XvB wallet rejected`: the endpoint rejected your wallet as invalid; the raffle needs a standard primary Monero address (`4…`). Check `monero.wallet_address`.
- `⚠ XvB registration failing`: the endpoint is unreachable or erroring despite a PPLNS share (transient; retried automatically).

## Data directories

Every stateful service stores its data in a host directory that you can place anywhere. By
default each one lives under `./data/<service>` inside the repo:

| Service | Config key | Default path | Mounted in container at |
|---|---|---|---|
| Monero | `monero.data_dir` | `./data/monero` | `/home/ubuntu/.bitmonero` |
| Tari | `tari.data_dir` | `./data/tari` | `/var/tari/node` |
| P2Pool | `p2pool.data_dir` | `./data/p2pool` | `/home/ubuntu` |
| Tor | `tor.data_dir` | `./data/tor` | `/var/lib/tor` |
| Dashboard | `dashboard.data_dir` | `./data/dashboard` * | `/data` |

\* The dashboard default follows the other four: when `monero`/`tari`/`p2pool`/`tor` all point
under one parent directory, the dashboard database defaults to `<that parent>/dashboard` instead
of `./data/dashboard`, so it lives beside the chain data rather than inside the install directory
(see [Operations › The deploy-box layout](operations.md#the-deploy-box-layout)).

Set any `data_dir` to an absolute path to move that service's storage. For example, to put the
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

> NOTE: `apply` does not copy your existing data into a new location; it only points the
> container at the new path. If you're relocating data you already have, move the files yourself
> first (with the stack stopped), then update `data_dir` and run `apply`.

---

## Exposing the dashboard safely

The dashboard targets a trusted private network: the home or office LAN the appliance sits on. By
default it has no login; anyone who can reach the host can open it. That is the default for a
single-user box behind your router.

Add a login (and keep HTTPS on) whenever the dashboard is reachable by anyone you don't fully trust.
For example:

- the machine is shared (a co-hosted home server other people use), or
- you've port-forwarded / reverse-proxied the dashboard so it's reachable from outside the LAN, or
- you want a second layer in front of it.

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

- The password is bcrypt-hashed, never stored in cleartext. pithead hashes it with the same pinned
  Caddy image the stack already runs (`caddy hash-password`) and writes only the hash to `.env`. The
  plaintext exists only in your owner-only `config.json`; treat that file like any other secret (it's
  already git-ignored). The hash is stable across `apply` runs and only re-computed when you change
  the password, so the Caddyfile doesn't churn.
- Keep `dashboard.secure: true`. Basic-auth sends the credentials with every request; over plain HTTP
  (`secure: false`) they'd travel in cleartext. pithead warns if you set a password without HTTPS, but
  won't stop you. With the default `tls internal`, Caddy serves a locally-trusted certificate; your
  browser will warn the first time unless you trust Caddy's local CA.
- A login is access control for the dashboard, not the miner. It gates the web UI only. The stratum
  port miners connect to is a separate surface; gate that with
  [`p2pool.stratum_password`](#configuration-reference) and `p2pool.stratum_bind`.
- Exposing to the public internet is still discouraged. A password plus HTTPS is the right baseline,
  but for reaching the dashboard from outside the LAN, publish it as a Tor onion service (below)
  rather than forwarding a port. Basic-auth has no rate-limiting or lockout on its own.

To remove the login again, clear the password (`"password": ""`) and `apply`. pithead drops the
`basic_auth` block and the dashboard is open on the LAN as before.

### Remote access over Tor (onion service)

Set `dashboard.onion.enabled: true` to publish the dashboard as a Tor v3 hidden service. You then
reach it from anywhere over Tor — no port-forward, no VPN, no public IP, no inbound firewall hole.
The stack already runs Tor for the mining traffic; this rides the same daemon.

```json
"dashboard": {
    "secure": true,
    "onion": { "enabled": true, "client_auth": true },
    "auth": { "username": "admin", "password": "a long passphrase you choose" }
}
```

Because a published `.onion` puts a control panel at a stable address, pithead **fails closed**:

- If you enable the onion without a `dashboard.auth.password`, pithead **generates a strong one**,
  saves it to `config.json`, and uses `admin` as the login — so the onion is never published without
  a password. If you set the password yourself it must be at least 16 characters, and pithead rejects
  obviously weak choices (a single repeated character, well-known patterns). A published address is
  reachable by anyone who learns it, and per-request rate-limiting is meaningless over Tor — every
  request arrives from the local Tor daemon, so there is no source IP to throttle. Use a passphrase.
- **Client authorization is on by default** (`client_auth: true`). A client-auth'd onion does not
  respond at all without your client key, so the address cannot be scanned or brute-forced — the
  password becomes a second factor behind it. This is the strong primary gate.
- The onion is served over **both HTTP and HTTPS**, fronted by the same login as the LAN path, and
  bound to the internal Docker bridge (not the LAN), so it is reachable only through Tor. Tor Browser
  upgrades `http://` to `https://` by default, so it lands on the HTTPS side automatically — no
  browser tweaks needed. The HTTPS cert is **self-signed** (Caddy's internal CA, for the `.onion`
  name), exactly like the LAN dashboard's cert: a `.onion` can't obtain a browser-trusted certificate
  without a manual CA process, and Tor already encrypts the transport, so the browser shows a one-time
  "accept the risk" prompt — the same click you make for the LAN dashboard.

After `apply`, read the address from `./pithead status` or `./pithead doctor` (printed only to that local
output). Treat the `.onion` as a secret: anyone who has it can _attempt_ the login (and, without
client-auth, reach it).

**Connecting with client authorization.** With `client_auth: true` the onion won't answer at all
until your Tor client presents the private key. Run `./pithead onion-client-key` on the host — it
prints the address and the key in both forms you might need (it's kept out of `status`, which is a
shareable report). Then pick your client:

- **Tor Browser (easiest).** Open `http://<address>.onion` (Tor Browser upgrades it to `https://`
  automatically). Accept the one-time self-signed-cert prompt ("Advanced" → "Accept the Risk and
  Continue" — the same as the LAN dashboard). Tor Browser then prompts for the onion's private key —
  paste the bare key (the value after `x25519:`) and continue. Nothing else to set up.
- **System Tor or Orbot (persistent).** Add a line to your `torrc`:
  `ClientOnionAuthDir /var/lib/tor/onion_auth` (any dir you own, mode `0700`). Inside it, create
  `dashboard.auth_private` containing the one-line form
  `<address>:descriptor:x25519:<private-key>`, then reload Tor. Now any Tor-aware client on that
  machine can reach the onion.

After that, browse to `http://<address>.onion` (it becomes `https://` — accept the self-signed cert
once) and log in with your dashboard username/password. Without the client key the onion is invisible
— that's the point. Set `client_auth: false` for a deliberately password-only onion (weaker: the
address becomes online-guessable, so lean on the password).

**Rotation.** A leaked `.onion` address or client key is otherwise permanent. Run
`./pithead rotate-dashboard-onion` to mint a fresh address and client key; the old ones stop working
immediately, and the command prints the new client line.

Prefer a mesh VPN like Tailscale instead? Point it at the LAN yourself — the stack does not ship a
profile for it, and the onion service is the supported remote path.

---

## Reusing an existing node

If you already run a synced Monero node, you can skip most or all of the initial blockchain sync.
There are two ways to do it.

> No existing node, but the over-Tor first sync is too slow? You don't have to reuse a chain. You
> can sync the bundled nodes over clearnet for the one-time initial download, then switch back to
> Tor. It's a default-off, privacy-relevant opt-in: see
> [`monero.clearnet_initial_sync` / `tari.clearnet_initial_sync`](#configuration-reference) and the
> full [threat model in Privacy](privacy.md#optional-clearnet-initial-sync-off-by-default).

### Option A — Point the bundled node at your existing blockchain

The Monero data directory mounts to `/home/ubuntu/.bitmonero` inside the container, the same layout a
standard `monerod` uses (its native `$HOME/.bitmonero`). To have the bundled node adopt a blockchain you've already downloaded,
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

Then run `./pithead apply`. The bundled `monerod` reuses the blockchain in place: no re-sync
from genesis, just a quick catch-up of any blocks produced since your node last ran.

A few things to keep in mind:

- Stop your other node first. Two `monerod` processes must never use the same data directory at the
  same time, or they'll corrupt the database.
- Match the prune setting. A pruned blockchain needs `monero.prune: true` (the default); an unpruned
  (full) blockchain needs `monero.prune: false`. They're not interchangeable.
- Ownership: the host directory must be readable/writable by the user that runs the stack. `apply`
  sets ownership on directories it creates, but won't change an existing tree out from under you.

### Option B — Connect to a remote node

If your existing Monero node runs on another machine, or you want to use a node you don't host,
switch to remote mode and the stack won't run its own `monerod` at all. See
[Connecting to a remote Monero node](#connecting-to-a-remote-monero-node) below.

> Tari uses the same mechanism: point `tari.data_dir` at an existing Minotari node directory
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
- The remote node must be set up for P2Pool mining, with ZMQ publishing enabled (`zmq-pub`, port
  `18083` by default) and its RPC reachable by P2Pool. In practice that means a node you run and
  control; general-purpose public "open node" endpoints do not work, since they don't expose ZMQ.
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
