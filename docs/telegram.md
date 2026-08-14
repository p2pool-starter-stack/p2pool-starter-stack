# Telegram Bot

Pithead can push a small set of **operational alerts** to Telegram, so you find out the moment
something needs attention — without sitting on the dashboard. It can also answer a few **read-only
status commands** on demand, so you can check on the stack from your phone. Both are **off by
default**; this guide takes you from nothing to a working alert in about five minutes, then adds
commands if you want them.

> **What this is — and isn't.** Alerts are a one-way push (a pager). The status commands
> (`/status`, `/hashrate`, and friends) are **read-only** — they report what the dashboard already
> knows and never change anything, so the worst a leaked chat can do is *read* your status. Two
> **control** commands (`/restart`, `/apply`) can act on the host, but they are a **separate,
> off-by-default opt-in** locked behind an operator allow-list and a per-action confirmation — see
> [Control commands](#control-commands).

---

## What you'll get

When enabled, the stack sends a short message on each of these events. Every alert is
**debounced** — a momentary blip won't ping you, and you get **one** message per real
transition, not a stream:

| Alert | When it fires |
|---|---|
| 🔴 **Node down** | Your Monero (or Tari) node has been unreachable long enough to be considered down — the stack has stopped serving your rigs so they **fail over to their backup pools**. |
| 🟢 **Node recovered** | The node is back and stable; the stack has readmitted your rigs. |
| 🔴 **Worker offline** | A rig stopped hashing and hasn't been seen for a few minutes (a reboot, a dropped connection, a dead miner) — it's showing **DOWN** on the dashboard. |
| 🟢 **Worker back online** | A rig that had gone offline is hashing again. |
| 🟢 **New worker joined** | A rig the stack hasn't seen before connected — a new miner joined the fleet. |
| ⚪ **Worker left** | A rig dropped off the dashboard entirely (removed from the worker list, not just DOWN). |
| ✅ **Sync finished** | The initial blockchain sync completed and mining has started — handy on first run, when the sync can take hours. |
| 🟠 **Disk filling up** | The data disk crossed the warn/critical threshold — a full disk can corrupt the Monero database, so free space before it runs out. |
| 🔴 **DB write failing** | The dashboard can no longer write to its database; hashrate history, shares, and stats will be lost on restart until it's fixed (usually disk space or permissions). |
| 🔄 **DB reset** | The database was found corrupt and auto-healed — the bad file was quarantined and a fresh one started, so history before now was cleared (the stack kept running). |
| 🔴 **Container trouble** | A stack container is restart-looping (an OOM kill — the per-container memory ceiling doing its job — or a bad config) or running but failing its healthcheck for over 2 minutes. One alert per incident, not one per restart, and a recovery note when it stabilises. Intentional stops (the sync hold, node-down failover) never fire it. |
| ⚠ **No PPLNS share (XvB)** | You're donating to XvB but hold no share in the PPLNS window, so raffle wins are **skipped** — donations are wasted until you land one. Only fires when XvB is enabled. |
| ⚠ **Clearnet sync active** | A node is doing its initial sync over **clearnet**, so this host's IP is exposed to that chain's P2P network until it finishes (it reverts to Tor automatically). |
| 🎰 **XvB registration** | XvB auto-registration was rejected (bad payout address) or is failing — raffle wins won't count until it recovers. Only fires when XvB is enabled. |
| 📉 **Hashrate low for tier** | You picked a fixed XvB donation tier your hashrate can't sustain — lower the tier or add hashrate. Fires on the transition and clears when it recovers. |
| ⚠️ **Hashrate drop** | Total fleet hashrate fell sharply below its recent normal and **stayed down** — a rig gone dark, a network cut, or a stalled miner. The dashboard also drops a marker on the hashrate chart at the moment it happened. Fires once on the drop and again on recovery. Thresholds are tunable (`dashboard.hashrate_drop_threshold`, `dashboard.hashrate_drop_minutes`). |
| 🧠 **HugePages not reserved** | RandomX runs capped until HugePages are reserved. Fires when the dashboard first sees them missing and again once a reboot applies them — so you know the tuning took. |
| 💾 **Low RAM** | This host has less RAM than the stack wants (syncing is memory-heavy; Tari can OOM). Sent once when first detected — a heads-up that instability may be under-provisioning, not a bug. |
| 🚨 **Payout wallet changed** | The wallet p2pool mines to differs from the last one seen — every future reward goes to the new address. Fires on **every** change, including one you made yourself with `./pithead apply`, so treat it as a confirmation; if you didn't change it, your rewards are being redirected. Addresses appear truncated to 8 characters (full addresses never leave the host), and the dashboard shows a matching top-bar warning for 72 hours — the dashboard warning works even with Telegram off. |
| 🎉 **Block found** | The P2Pool sidechain found a Monero block. Pool-wide: every miner with a PPLNS share gets paid from it. |
| 💰 **Payout incoming** | That block pays **you** — this node held a share in the PPLNS window when it was found. The amount lands in your wallet once the block matures (about two hours). |
| ✅ **Payout confirmed** | A P2Pool payout (Monero or Tari) matured and was seen **on-chain** by the view-only wallet — ground truth that a reward actually arrived, beside the estimate. Fires once per confirmed payout. Only when a view key is set (see [Payout confirmation](dashboard.md#payout-confirmation)). |
| 🆕 **New release** | A newer Pithead release is available (the same signal as the dashboard header badge). |
| 🚀 **Pithead online** | Sent once when the dashboard starts — a heartbeat that the stack is up (and confirms the bot works after setup). |
| 📅 **Daily summary** | A once-a-day retrospective of the last 24h across your whole fleet — date/time, an **incident roll-up** (what went wrong during the day, or an all-clear), **24h hashrate** with the **P2Pool / XvB split**, **shares found in the day**, an **estimated daily earnings** figure, and a **per-machine 24h breakdown** — pushed at a set local time (**08:00** by default; `telegram.daily_summary_time`). |

Every message is prefixed with your dashboard hostname (e.g. `[rig-box.lan]`), so if you point
more than one stack at the same chat you can tell them apart.

Each of these can be **turned off individually** — see [Choosing which alerts you get](#choosing-which-alerts-you-get).

---

## Setup

You need two things: a **bot token** (the credential Pithead uses to send) and a **chat id** (where
the messages go). Both come from Telegram, in a few taps.

### 1. Create a bot and get its token

1. In Telegram, open a chat with **[@BotFather](https://t.me/BotFather)** (the official bot for
   making bots).
2. Send `/newbot` and follow the prompts — pick a name and a username (the username must end in
   `bot`, e.g. `my_pithead_bot`).
3. BotFather replies with a **token** that looks like:

   ```
   123456789:AAExampleExampleExampleExampleExample
   ```

   This is your `bot_token`. **Treat it like a password** — anyone with it can post as your bot.

### 2. Pick where alerts go (a group is recommended)

You can send alerts straight to your own Telegram account, but a **dedicated group** is the
cleaner choice: it keeps alerts out of your personal chats, lets you mute them with one tap, and
lets you add other operators (or a second alert source — see
[One chat, two bots](#one-chat-two-bots)).

1. Create a new Telegram **group** (e.g. "Pithead alerts").
2. Add your bot to it: open the group → **Add members** → search for your bot's username.

> If you'd rather have alerts come as a normal direct message instead, skip the group and just
> **send your bot a `/start`** message — that's enough for it to be allowed to message you back.

### 3. Find your chat id

The easiest way:

1. Add **[@userinfobot](https://t.me/userinfobot)** to the same group (or message it directly for a
   1-to-1 chat). It immediately replies with the chat's **id**.
2. Note the number. **Group ids are negative** and often long, e.g. `-1001234567890`. A direct
   chat id is a positive number, e.g. `987654321`.
3. You can remove `@userinfobot` afterwards.

> **Manual alternative** (no third-party bot): send any message in the group, then open
> `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates` in a browser and read the `chat.id` field
> from the JSON. (You may need to send the message *after* adding your bot for it to show up.)

### 4. Put it in `config.json`

Add a `telegram` block to your `config.json`. The minimum to switch it on:

```json
{
    "monero":   { "wallet_address": "your_monero_wallet_address" },
    "tari":     { "wallet_address": "your_tari_wallet_address" },

    "telegram": {
        "enabled": true,
        "bot_token": "123456789:AAExampleExampleExampleExampleExample",
        "chat_id": "-1001234567890"
    }
}
```

`chat_id` can be written as a string (recommended, since group ids are long and negative) or a
number — both work.

### 5. Apply

```bash
./pithead apply
```

`apply` re-renders the stack and restarts the dashboard with the new settings. On the next health
cycle, alerting is live. To confirm it works end-to-end, you can stop a rig (or briefly stop a
node) and wait for the offline/down alert — remember the debounce means it's a few minutes, not
instant, by design.

---

## Choosing which alerts you get

Every event is on by default once Telegram is enabled. To silence one, add it to a `telegram.events`
block and set it to `false` — any event you don't list stays on:

```json
"telegram": {
    "enabled": true,
    "bot_token": "…",
    "chat_id": "…",
    "events": {
        "worker_offline": false,
        "worker_recovered": false
    }
}
```

| Event key | Default | Alert |
|---|---|---|
| `node_down` | `true` | Monero/Tari node went down; also the Monero node reachable but out of sync for 10+ minutes (peers lost after a Tor restart) |
| `node_recovered` | `true` | …and came back / back in sync |
| `worker_offline` | `true` | A rig went DOWN |
| `worker_recovered` | `true` | …and came back |
| `worker_joined` | `true` | A new rig joined the fleet |
| `worker_left` | `true` | A rig dropped off the dashboard entirely |
| `sync_finished` | `true` | Initial sync done, mining started |
| `disk_space` | `true` | Data disk filling up / critical / recovered |
| `db_unhealthy` | `true` | Dashboard database writes failing / recovered |
| `db_reset` | `true` | Corrupt dashboard database auto-healed (quarantined + reset); history cleared |
| `xvb_no_share` | `true` | XvB on but no PPLNS share (wins skipped) / restored |
| `clearnet_exposed` | `true` | A node is syncing over clearnet (IP exposed) / back on Tor |
| `xvb_registration` | `true` | XvB auto-registration rejected / failing / recovered |
| `new_release` | `true` | A newer Pithead release is available |
| `stack_online` | `true` | One-shot "dashboard is up" heartbeat on start |
| `daily_summary` | `true` | Once-a-day status roll-up (time set by `telegram.daily_summary_time`, default `08:00`) |
| `hashrate_low` | `true` | Hashrate can't sustain the chosen XvB tier / recovered |
| `hashrate_loss` | `true` | Total hashrate dropped sharply and stayed down (outage / rig dark) / recovered |
| `hugepages` | `true` | HugePages not reserved (RandomX capped) / reserved after a reboot |
| `low_ram` | `true` | Host has less RAM than the stack wants (one-shot heads-up) |
| `wallet_changed` | `true` | The payout wallet p2pool mines to changed — fires on every change, including your own `./pithead apply` (old/new addresses truncated to 8 chars) |
| `high_reject_rate` | `true` | Pool-wide reject rate over the trailing hour crossed 5% (the same threshold as the dashboard's ⚠ flag) / dropped back |
| `block_found` | `true` | The P2Pool sidechain found a Monero block (pool-wide — every miner with a PPLNS share gets paid) |
| `payout_found` | `true` | That block pays you — this node held a share in the PPLNS window when it was found |
| `payout_confirmed` | `true` | A payout (Monero or Tari) confirmed on-chain by the view-only wallet |
| `container_unhealthy` | `true` | A stack container is crash-looping or stuck failing its healthcheck / recovered |
| `raffle_win` | `true` | This wallet won an XvB raffle round, per XvB's public winners file — fires once per win, with the round type and credited hashrate |

Run `./pithead apply` after editing.

> The dashboard also shows an **AVX2-missing** badge when the CPU lacks AVX2, but it has **no
> alert** — it's a fixed hardware fact with nothing to do at runtime, so it stays a badge (and shows
> in `/status`) rather than a push you can't act on.

> **Tari note.** A node-down/recovered alert fires for **Tari only when Tari is treated as
> required** (`dashboard.tari_required: true`, the default). If you've made Tari non-blocking, a
> Tari outage doesn't stop your Monero mining, so it isn't alerted as a node-down — matching how
> the rest of the stack treats a non-blocking Tari. Monero is always alerted.

---

## Commands

Beyond alerts, the bot can answer **status queries on demand** — ask it how things are and it
replies with what the dashboard already knows. This is a **separate opt-in** from alerts: turn it on
by adding a `commands` block.

```json
"telegram": {
    "enabled": true,
    "bot_token": "…",
    "chat_id": "…",
    "commands": { "enabled": true }
}
```

Run `./pithead apply` after editing. The commands:

| Command | Reply |
|---|---|
| `/status` | One-glance health: each node up/down/syncing, the **Tari merge-mine link** (gRPC connected — distinct from the node being synced), whether mining is active, workers online, total hashrate, PPLNS shares in window, and — when XvB is on — the **24h P2Pool/XvB split** (same figures as the daily summary) — followed by any active **warning/error badges** (the same ones the dashboard's top bar shows), or an explicit "✅ No warnings." |
| `/info` | About this stack: the running **version** (and whether a newer release is available), the Monero **DB mode** (pruned / full), the P2Pool **sidechain** (Mini / Main), and the **privacy posture** (Tor-only, or how many clearnet paths are exposed). |
| `/hashrate` | Total hashrate plus a per-rig breakdown of everything currently online. |
| `/workers` | Every rig's online/offline state, with uptime for the ones that are up. |
| `/sync` | Monero and Tari sync progress (percent and block height). |
| `/system` | Host resources: disk, RAM, CPU + load, and HugePages. |
| `/pool` | P2Pool sidechain type, pool hashrate, Monero network height + difficulty, PPLNS shares in window, current **effort** (luck indicator), **sidechain blocks found**, **share acceptance** (accepted/rejected + reject %), and the **best share** difficulty found. |
| `/xvb` | XvB mode, current and target tier, the target tier's **threshold and cost** (holding a tier ≈ donating its threshold continuously, on both credited averages; a tier is **raffle status, not an XMR payout**), hashrate **routed** to XvB, the **credited** 1h/24h averages XvB measures (what sets your tier), raffle eligibility (PPLNS share), and a stale-data warning if the XvB feed is behind. |
| `/earnings` | Estimated P2Pool XMR per day/month, from both your **1h** and (once available) steadier **24h** average hashrate, plus the XTM the same hashrate **merge-mines alongside** (shown only while merge-mining figures are live). Excludes XvB-donated hashrate. With [payout confirmation](dashboard.md#payout-confirmation) on, the estimate is followed by what actually landed: **confirmed yesterday / 7d / 30d** totals per chain, the same figures and `*` partial marking the dashboard's Confirmed on-chain block shows. The confirmed totals come off the wallet, so they still report even when the estimate is waiting on network data. |
| `/luck` | Pool cadence: time since the pool's last block (pool-wide, not your payout), estimated **time-to-share** for your hashrate, **luck** (actual vs. expected shares in the PPLNS window — over 100 % = running lucky), and **your PPLNS weight** (the sum of your share difficulty in the window). The same figures as the dashboard's Pool Cadence & Luck card. |
| `/help` | The command list. |

The numbers come from the **same source as the dashboard**, so a reply and the web view always
agree. In a group, address the bot directly if you like — `/status@your_pithead_bot` works too.

**Only the configured `chat_id` is answered.** A message from any other chat is ignored with no
reply, so the bot can't be used by anyone you haven't put in that chat. The bot **long-polls**
Telegram (`getUpdates`) rather than exposing a webhook, so it needs **no inbound port** and rides
the same outbound path as the alerts — nothing about your host is exposed to receive commands.

> **Tor-only host.** Like alerts, commands reach `api.telegram.org` over clearnet. With no clearnet
> egress the poll just fails silently and the bot answers nothing — see
> [Privacy and secrets](#privacy-and-secrets).

---

## Control commands

Two commands can **act on the host** rather than just report:

| Command | What it does |
|---|---|
| `/restart` | Recreate the running stack (`./pithead restart`). |
| `/apply` | Re-render and re-apply the **current** `config.json` on the host (`./pithead apply`). It applies what is already on disk — it does not carry a config change from Telegram. |

This is a **remotely-reachable control surface**, so it is off by default and gated at every step.
The bot token being known is **not** authorization. Turn it on only if you accept that a Telegram
message can trigger these actions, and set the allow-list to the operators who may.

```json
"telegram": {
    "enabled": true,
    "bot_token": "…",
    "chat_id": "…",
    "commands": { "enabled": true },
    "control": {
        "enabled": true,
        "allowed_ids": [123456789],
        "confirm_timeout": 60
    }
},
"dashboard": {
    "auth": { "username": "admin", "password": "…" },
    "control": { "enabled": true }
}
```

How the gating works:

- **Operator allow-list.** A control command is accepted **only** from the numeric Telegram **user
  ids** in `allowed_ids` — being in the right `chat_id` is not enough. Every other sender is refused
  and dropped silently (no reply, so the bot can't be used to probe who is authorised). Find your
  user id the same way you found your chat id ([step 3](#3-find-your-chat-id)); with an **empty**
  allow-list the whole feature stays off.
- **Per-action confirmation, deny-on-timeout.** Issuing `/restart` or `/apply` doesn't do anything
  yet — the bot replies with the concrete action and a single **Confirm** button. Nothing happens
  until you tap it, and if you don't within `confirm_timeout` seconds (default 60) the request is
  **denied**, never queued. Only the operator who issued the command can confirm it, and each button
  is one-shot.
- **Per-operator rate limit.** Each allow-listed operator can be issued at most a handful of confirm
  prompts per rolling hour; past that, `/restart` / `/apply` from that operator are dropped without a
  prompt (an anti-fatigue guard so a stuck or compromised session can't spam approvals). The budget is
  keyed per operator, so one hitting the cap never locks the others out. Not configurable.
- **A fixed, small action set.** The two verbs are the whole surface — a Telegram message **selects**
  one of them, it never becomes a host command. There is no arbitrary execution.
- **It rides the config-editor's channel, not a new one.** Both verbs act by dropping a typed intent
  into the same host-control spool the dashboard config editor uses (`dashboard.control.enabled`,
  see [Editing config from the dashboard](configuration.md)); the root runner on the host validates
  and runs the fixed verb. The dashboard container never runs a host command itself. That is why
  `dashboard.control.enabled` (and its login) is a prerequisite — `apply` refuses to enable the
  Telegram control commands without it.
- **Everything is audited.** Each confirmed command lands in the host-side control audit log
  (`data/control/audit/control.log`) with the actor tagged `tg-<your-user-id>` and the outcome —
  the same tamper-evident log the config editor writes to.

A **config-changing** apply is deliberately **not** a Telegram command: editing config still goes
through the dashboard's editor, where the host's default-deny allowlist refuses security-sensitive
keys. `/apply` here only re-applies the config already on the host.

> **Tuning the confirmation window.** `confirm_timeout` is in seconds. Shorten it if you want a
> tighter window; a value that is too short just means you have to be quicker to tap Confirm before
> the request is denied.

---

## One chat, two bots

Pithead's companion **Healthchecks.io** monitor (a "dead-man's switch" that detects the whole host
going dark from *outside* the stack) can deliver its alerts to Telegram too. The two are
complementary:

- **This (in-stack) alerter** reports everything the host can tell you **while it's alive** — a
  node down, a rig offline, sync finished.
- **Healthchecks.io** reports the case this one can't: the **whole host is dead** (power cut,
  kernel panic, network gone) and therefore can't send anything itself.

The clean setup is to point **both at the same Telegram group** — one place for every alert. They
necessarily use **two different bots**:

- This alerter uses **your own BotFather bot** (`bot_token` above) posting to your `chat_id`.
- Healthchecks.io has **its own** Telegram integration bot that you authorize into the chat on the
  Healthchecks.io side — you never paste a token into Healthchecks.io.

So the thing you share is the **chat**, not the token: create the group, add **both** bots to it,
and use that group's id here. Each source labels its own messages, so you can always tell which is
which. (Keeping them in separate chats is fine too — only useful if you want to mute or route them
differently.)

### Adding Healthchecks.io to the same group

Once your Pithead bot is posting to the group, add Healthchecks.io's bot to it as well. You do
**not** paste any token into Healthchecks.io — you authorize its bot from their side:

1. In Telegram, **add [@HealthchecksBot](https://t.me/HealthchecksBot) to your alerts group** (the
   same group the Pithead bot posts to). It joins as a member with no access to group messages.
2. In the group, send **`/start@HealthchecksBot`**. Use the **`@HealthchecksBot`** suffix, not a
   bare `/start` — your Pithead bot is already in the group, so a plain `/start` is ambiguous and
   won't reach the right bot.
3. HealthchecksBot replies with a **confirmation link**. Tap it — Healthchecks.io opens in your
   browser.
4. **Select the project** your ping URL belongs to and click **"Connect Telegram"**. Done — host-down
   alerts now land in the same group as your Pithead bot's alerts.

Full walkthrough on their site: **<https://healthchecks.io/integrations/add_telegram/>**. For the
rest of the Healthchecks.io setup (creating the check, the ping URL, `config.json`), see
[Monitoring & Alerting](monitoring.md).

---

## Webhook and ntfy sinks

Telegram is not the only way out. Every alert above can also be pushed to a **generic JSON
webhook** (Gotify, Home Assistant, n8n, anything that accepts a POST) and/or an **[ntfy](https://ntfy.sh)
topic** — with or without Telegram. Both are **off by default** and configured in their own
top-level `config.json` block:

```json
"notifications": {
    "webhooks": ["https://example.com/pithead-hook"],
    "ntfy": {
        "url": "https://ntfy.sh/your-topic",
        "token": ""
    },
    "tor": true
}
```

- **`webhooks`** — a list of URLs. Each alert is POSTed to every URL as JSON:

  ```json
  {"event": "node_down", "text": "🔴 ⛓️ Monero node is DOWN — workers failing over to backup pools.", "ts": 1781136000}
  ```

  `event` is the same key used in `telegram.events` (the table above), `text` is the exact
  message Telegram would get, `ts` is a Unix timestamp.
- **`ntfy.url`** — one topic URL (`https://server/topic`; self-hosted servers work). Each alert's
  text is POSTed as the message body. Set `ntfy.token` for an access-protected topic — it's sent
  as an `Authorization: Bearer` header.
- **`tor`** — keep the POSTs on Tor (the default; see below).

Then `./pithead apply`. Sinks carry **every** event — the `telegram.events` toggles gate Telegram
only. Like the Telegram alerter, sends **fail silently** (an unreachable endpoint never breaks the
stack), and the URLs and token are **secrets**: webhook URLs often embed a key in the query
string, so they live only in the owner-only `.env` and are never printed by `apply` or written to
a log line.

**Tor and the LAN carve-out.** With `tor: true` (the default) every POST rides the bundled Tor
SOCKS proxy, so the endpoint sees a **Tor exit, not your host IP** — same rule as Telegram. That
also means the endpoint must be **Tor-reachable**: Tor exits cannot reach private (RFC1918)
addresses, so a webhook or ntfy server on your LAN needs `tor: false`. Flipping it routes the
POSTs directly — a **clearnet** endpoint then sees your host IP on every alert, so keep `tor:
true` unless every configured endpoint is on your own network.

### Setting up ntfy, step by step

[ntfy](https://ntfy.sh) pushes each alert to your phone or desktop with no account — you pick a
topic name and subscribe to it.

1. **Pick a topic.** A topic is the name on the end of the URL. Anyone who knows it can read your
   alerts, so treat it like a password: make it long and unguessable — e.g.
   `pithead-a7f3k9x2-alerts`. On the public server that's `https://ntfy.sh/pithead-a7f3k9x2-alerts`.
2. **Subscribe.** Install the ntfy app (Android or iOS) or open [ntfy.sh](https://ntfy.sh) in a
   browser, and subscribe to that same topic. Nothing arrives yet — you have only started
   listening.
3. **Point the stack at it.** Add the topic URL to `config.json`, then `./pithead apply`:

   ```json
   "notifications": { "ntfy": { "url": "https://ntfy.sh/pithead-a7f3k9x2-alerts" }, "tor": true }
   ```

   The URL is the capability, so it is treated as a secret: it lives only in the owner-only `.env`
   and is never printed or logged.
4. **Test it.** Trigger an alert — stop a worker, or run `./pithead down` then `./pithead up` for a
   node-down/recovery pair — and confirm it lands on your device.

**Protected topics.** For a self-hosted ntfy with access control, add `"token": "tk_..."` to the
`ntfy` block; it is sent as an `Authorization: Bearer` header (also a secret).

**Over Tor (the default).** With `tor: true`, alerts reach the ntfy server through a Tor exit, so
it never sees your home IP — public `ntfy.sh` works fine this way. A self-hosted ntfy on your own
**LAN** is not Tor-reachable (Tor exits cannot reach private addresses), so set `tor: false` for
it; that sends directly, and the LAN server seeing your host IP is expected on your own network.

---

## Privacy and secrets

- **The bot token is a secret.** Pithead stores it in `.env`, which is created **owner-only**
  (`chmod 600`) and is **git-ignored**, exactly like the Monero node RPC password. The dashboard
  **never writes the token to a log line** — not even inside an error message.
- **Always over Tor.** Both the alert sends and the command long-poll reach `api.telegram.org`
  **through the bundled Tor SOCKS proxy** (`socks5h`, so the DNS lookup goes through Tor too) — the
  same routing as the Healthchecks.io pinger and the XvB fetch. Telegram sees a **Tor exit, not your
  host IP**, so enabling the bot doesn't expose where your stack runs. If Tor is momentarily down (or
  Telegram is blocking that exit), sends and polls **fail silently** — no errors, no log spam, the
  rest of the stack is unaffected — and resume on their own.

---

## Tuning the debounce (advanced)

The defaults err on the side of **not** crying wolf. If you want faster (or quieter) worker alerts,
override these environment variables for the dashboard container — both are in seconds:

| Variable | Default | Meaning |
|---|---|---|
| `WORKER_OFFLINE_AFTER_SEC` | `300` | A rig must be unseen this long before "offline" fires. |
| `WORKER_RECOVERY_AFTER_SEC` | `120` | A rig must be back this long before "back online" fires. |

Node-down timing is shared with the existing failover logic (`NODE_DOWN_AFTER_SEC` /
`NODE_RECOVERY_AFTER_SEC`). These are advanced knobs; most operators never touch them.

The **hashrate-drop** alert has its own two `config.json` knobs (not env vars):
`dashboard.hashrate_drop_threshold` (percent below the recent normal that counts as a drop, default
`50`) and `dashboard.hashrate_drop_minutes` (how long it must stay down before firing, default `10`).

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| No messages at all | Confirm `telegram.enabled` is `true` **and** both `bot_token` and `chat_id` are set — a missing one keeps alerting **off**. Did you run `./pithead apply`? |
| Still nothing | Make sure the bot has been **added to the group** (or that you sent it `/start` for a direct chat). A bot can't message a chat it isn't in. |
| `chat_id` looks wrong | Group ids are **negative** and long (`-100…`). Re-check with `@userinfobot`. |
| Works for "down" but not a specific alert | Check `telegram.events` — that event may be toggled `false`. |
| Alerts work but commands don't | Commands are a **separate** switch: set `telegram.commands.enabled` to `true` and `./pithead apply`. |
| Bot ignores my commands | It only answers the configured `chat_id`. Send from that exact chat, and check the id with `@userinfobot`. |
| No messages, Tor issues | Telegram is reached **over Tor**; if Tor is down or Telegram is blocking the exit, sends/polls fail silently and resume on their own. See [Privacy and secrets](#privacy-and-secrets). |

---

## See also

- [Configuration](configuration.md) — every `config.json` key, including the `telegram.*` block.
- [The Dashboard](dashboard.md) — the live view these alerts complement.
- [Operations & Maintenance](operations.md) — `apply`, upgrades, and troubleshooting.
