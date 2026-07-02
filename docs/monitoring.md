# Monitoring & alerting

Pithead can ping an external **dead-man's switch** so you find out when your mining host
goes down — even when it can't tell you itself.

## Why an *external* monitor?

If the stack hits a problem while the machine is still alive — a node falls out of sync, a
container crashes — it can notice and react locally. But the failures that hurt most are the
ones that kill the whole host: **power loss, a kernel panic, a dead NIC, the box hanging**. A
dead machine can't send its own "I'm down" alert.

[Healthchecks.io](https://healthchecks.io) solves this by inverting the logic. The stack
periodically pings a unique URL; **Healthchecks.io alerts you when the pings *stop***. Because
the alert is evaluated on Healthchecks.io's servers, it survives the very outage you want to
catch. It's a *dead-man's switch*: silence is the alarm.

This is **off until you configure it** and entirely optional — with no ping URL set, nothing
pings and nothing is logged.

---

## Setup (about 5 minutes)

### 1. Create a check on Healthchecks.io

1. Sign up at [healthchecks.io](https://healthchecks.io) — the **free tier** (20 checks, 3
   months of history) is plenty for one stack. (Prefer to self-host? See
   [Self-hosting](#self-hosting-your-own-instance) below.)
2. Create a new check. Name it something like `pithead`.
3. Set its schedule. The recommended values, which match Pithead's default 60-second ping
   interval:
   - **Period — 1 minute.** How often Healthchecks.io *expects* a ping. The stack pings once
     a minute by default, so a 1-minute period tracks it closely.
   - **Grace — 5 minutes.** How long after a missed period before you're alerted. This slack
     absorbs a brief blip — e.g. a quick dashboard-container restart — without a false alarm,
     so you're only alerted after roughly **6 minutes** of true silence. Shorten it for faster
     alerts (more false positives on blips); lengthen it if you also raise `interval_seconds`.
4. Copy the check's **ping URL** — it looks like `https://hc-ping.com/<uuid>`.

### 2. Choose where alerts go

On the check's **Integrations** tab, point it at however you want to be notified — **email**,
**Telegram**, Slack, Discord, a webhook, and more. If you already use Telegram for other
alerts, you can route Healthchecks.io to the **same** Telegram chat, so host-down alerts and
in-stack events land in one place.

### 3. Paste the ping URL into `config.json`

Add a `healthchecks` block with your ping URL — that URL is the on switch (see
[`config.reference.json`](../config.reference.json)):

```json
{
    "healthchecks": {
        "ping_url": "https://hc-ping.com/your-unique-uuid-here"
    }
}
```

`enabled` and `ping_url` are all you need; everything else has a sensible default.

### 4. Apply

```bash
./pithead apply
```

`apply` previews the change and recreates the dashboard container. The ping URL is treated as
a secret — it's stored in the owner-only `.env`, never echoed by `apply`, and never logged.

That's it. Within a cycle or two the check on Healthchecks.io turns green. Kill the stack (or
the whole host) and, once the period + grace elapses, Healthchecks.io alerts you.

---

## How it works

- The dashboard's existing data-collection loop sends the ping each cycle, so it reuses the
  process that's already running — no extra container or daemon. If the host dies, the
  dashboard dies with it, the pings stop, and the alert fires. If only the dashboard container
  restarts briefly, the **grace period** absorbs the gap.
- **Liveness only — is the *stack* up.** This is a pure dead-man's switch: it reports that the
  dashboard loop (and therefore the host) is alive, nothing more. It deliberately does **not** try
  to say whether a node is synced or a miner is connected. In-stack health — monerod or Tari down
  while the box is still running — is reported by the [Telegram alerter](https://github.com/p2pool-starter-stack/pithead/issues/121)
  (#121), which can send a specific, actionable message a single red check can't. Two tools, two
  jobs: Healthchecks answers "did the whole thing die?", Telegram answers "what's wrong inside it?".
- **Always over Tor.** The ping goes through the stack's [Tor](architecture.md) SOCKS proxy, so the
  endpoint only ever sees a Tor exit, not your host IP — it's never a clearnet beacon. This means
  your ping URL must be reachable over Tor (hosted `hc-ping.com` is; a self-hosted instance must be
  public or an onion service — a LAN-only address won't work). See the [Privacy note](#privacy-note).
- **Fails silently.** A ping that can't get out — you're offline, or Tor is momentarily down — is
  ignored quietly (logged at debug level only). Healthchecks.io will alert on the missed ping
  regardless, which is the point.

---

## Configuration reference

| Key | Default | Description |
|---|---|---|
| `healthchecks.ping_url` | *(blank)* | The full ping URL from Healthchecks.io, e.g. `https://hc-ping.com/<uuid>` (or your [self-hosted](#self-hosting-your-own-instance) instance's URL). **This is the on/off switch** — set it to enable, leave it blank to keep the monitor off. Must be reachable over Tor (see [Privacy note](#privacy-note)). Treated as a secret (stored in the owner-only `.env`). |
| `healthchecks.interval_seconds` | `60` | Minimum seconds between pings (default **1 minute**). The loop runs every 30s, so a value below that just pings every cycle. Match your Healthchecks **period** to this and give the **grace** enough slack for a restart (the recommended **1-minute period / 5-minute grace** above). |

> Auto-provisioning the check via the Healthchecks.io Management API (so you wouldn't have to
> copy the URL by hand) was considered but deliberately left out: it would mean storing a
> powerful API key in your config. Manual setup keeps it simple, secret-free, and works
> equally well with a self-hosted instance.

---

## Self-hosting your own instance

Healthchecks is open source and [self-hostable](https://healthchecks.io/docs/self_hosted/). To
point Pithead at your own instance, just paste its full ping URL into `ping_url` — it already
carries your host, so nothing else is needed:

```json
{
    "healthchecks": {
        "ping_url": "https://hc.example.com/ping/your-unique-uuid-here"
    }
}
```

Because the ping **always goes over Tor**, your instance must be reachable that way: expose it as
an **onion service** (best for privacy — the ping stays on Tor end to end) or on a public URL. A
LAN-only address (e.g. `http://192.168.1.10/...`) won't work — Tor can't route to private addresses.

---

## Privacy note

The ping is **always routed over Tor**, reusing the same bridge Tor SOCKS proxy as the XvB fetch —
so the endpoint sees a **Tor exit**, not your host's IP, and the DNS lookup goes through Tor too
(`socks5h`). There is no clearnet mode; the dead-man's switch is never an IP beacon.

Two things to know:

- **Tor is part of the ping path.** If the Tor container is down while the host is up, the ping
  can't get out and the check will eventually alert — a *false* "host down". The 5-minute grace
  absorbs brief Tor blips, and pings retry every cycle, so only a sustained Tor outage trips it.
  That's usually what you want (Tor down *is* a problem worth knowing about).
- **Your ping URL must be Tor-reachable.** Hosted `hc-ping.com` is. A self-hosted instance must be
  public or, better, an **onion service** — paste its `.onion` URL and the ping stays on Tor end to
  end with no exit node in the middle. A LAN-only address won't work (Tor can't route to it).

---

## Optional: a host-level ping, independent of the dashboard

Pinging from the dashboard loop covers the big failure modes (host death, dashboard crash). If
you want a liveness signal that doesn't depend on the dashboard at all — handy on a dedicated
mining box — add a small **systemd timer** on the host that curls the same (or a second) ping
URL:

```ini
# /etc/systemd/system/pithead-heartbeat.service
[Unit]
Description=Ping Healthchecks.io (host heartbeat)
[Service]
Type=oneshot
ExecStart=/usr/bin/curl -fsS -m 10 --retry 3 https://hc-ping.com/your-unique-uuid-here
```

```ini
# /etc/systemd/system/pithead-heartbeat.timer
[Unit]
Description=Run the Healthchecks.io heartbeat every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now pithead-heartbeat.timer
```

Use a **separate** check for the host timer if you want to tell "the host is up" apart from
"the mining stack is up."

---

## Verifying & troubleshooting

- **The check never goes green.** Confirm `enabled` is `true` and you ran `./pithead apply`.
  Check the dashboard logs (`./pithead logs dashboard`) for a `Healthchecks.io dead-man's
  switch enabled` line at startup; if you see `Healthchecks enabled but no ping_url
  configured`, the URL is missing. Ping failures themselves are logged at debug level only.
- **Test it end to end.** Stop the stack (`./pithead stop`) and wait for the period + grace to
  elapse — you should get the alert. Start it again and the check recovers.
- **Too many false alarms.** Increase the **period** and/or **grace** on Healthchecks.io, or
  raise `interval_seconds` if you've set it very low.

---

## See also

- [Configuration](configuration.md) — the full `config.json` reference.
- [Architecture](architecture.md) — the privacy model and the Tor routing this feature rides.
- [Operations & Maintenance](operations.md) — the `pithead` command reference, logs, and
  troubleshooting.
