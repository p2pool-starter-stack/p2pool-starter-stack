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

This is **off by default** and entirely optional — when disabled, nothing pings and nothing is
logged.

---

## Setup (about 5 minutes)

### 1. Create a check on Healthchecks.io

1. Sign up at [healthchecks.io](https://healthchecks.io) — the **free tier** (20 checks, 3
   months of history) is plenty for one stack. (Prefer to self-host? See
   [Self-hosting](#self-hosting-your-own-instance) below.)
2. Create a new check. Name it something like `pithead`.
3. Set its schedule:
   - **Period** — how often Healthchecks.io *expects* a ping. Set this comfortably **above**
     your ping interval (default 60s) so a single missed cycle — e.g. a quick dashboard
     restart — doesn't trip a false alarm. **5 minutes** is a sensible starting point.
   - **Grace** — how long after a missed period before you're alerted. **5–10 minutes** is
     reasonable; shorter means faster alerts but more false positives on brief blips.
4. Copy the check's **ping URL** — it looks like `https://hc-ping.com/<uuid>`.

### 2. Choose where alerts go

On the check's **Integrations** tab, point it at however you want to be notified — **email**,
**Telegram**, Slack, Discord, a webhook, and more. If you already use Telegram for other
alerts, you can route Healthchecks.io to the **same** Telegram chat, so host-down alerts and
in-stack events land in one place.

### 3. Paste the ping URL into `config.json`

Add a `healthchecks` block (see [`config.advanced.example.json`](../config.advanced.example.json)):

```json
{
    "healthchecks": {
        "enabled": true,
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
- **Health-aware (optional).** With `signal_fail_on_node_down` on (the default), the stack
  sends a `/fail` signal — turning the check red immediately — whenever a *required* node is
  down: monerod always, and Tari only when `dashboard.tari_required` is `true` (the same
  condition that fails miners over to their backup pools, see
  [Configuration](configuration.md#configuration-reference)). So the check catches a
  degraded-but-alive stack too, not just a dead host. Set it to `false` for plain liveness
  (only a dead host trips the alert).
- **Fails silently.** A ping that can't get out — you're offline, or running
  [Tor-only](architecture.md) without clearnet — is ignored quietly (it's logged at debug
  level only). Healthchecks.io will alert on the missed ping regardless, which is the point.

---

## Configuration reference

| Key | Default | Description |
|---|---|---|
| `healthchecks.enabled` | `false` | Master switch. When off, the stack never pings and logs nothing. |
| `healthchecks.ping_url` | _(blank)_ | The ping URL from Healthchecks.io, e.g. `https://hc-ping.com/<uuid>`. A bare uuid/slug is also accepted and is joined onto `base_url`. Treated as a secret (stored in the owner-only `.env`). |
| `healthchecks.base_url` | `https://hc-ping.com` | Only used when `ping_url` is a bare uuid (not a full URL). Override it to point at a [self-hosted](#self-hosting-your-own-instance) instance. |
| `healthchecks.interval_seconds` | `60` | Minimum seconds between pings. The loop runs every 30s, so a value below that just pings every cycle. Keep your Healthchecks **period + grace** well above this. |
| `healthchecks.signal_fail_on_node_down` | `true` | Send `/fail` (red the check now) while a required node is down. `false` = plain liveness only. |

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
        "enabled": true,
        "ping_url": "https://hc.example.com/ping/your-unique-uuid-here"
    }
}
```

Alternatively, store the bare uuid in `ping_url` and set `base_url` to your instance's ping
prefix (e.g. `https://hc.example.com/ping`).

---

## Privacy note

Pinging the hosted **hc-ping.com** happens over **clearnet**, which reveals your host's IP
address to Healthchecks.io — separate from the Monero/Tari traffic the stack routes over
[Tor](architecture.md). If that matters to you, **self-host** Healthchecks on infrastructure
you control (ideally reachable as an onion service or over a VPN). This feature is opt-in and
off by default precisely because it's a clearnet beacon.

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

- [Configuration](configuration.md) — the full `config.json` reference, including
  `dashboard.tari_required`, which governs the `/fail` signal.
- [Architecture](architecture.md) — the privacy model and the Tor routing this feature sits
  outside of.
- [Operations & Maintenance](operations.md) — the `pithead` command reference, logs, and
  troubleshooting.
