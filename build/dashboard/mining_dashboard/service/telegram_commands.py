import asyncio
import logging
import time

import requests

from mining_dashboard.config.config import (
    HOST_IP,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
    TELEGRAM_COMMANDS_ENABLED,
    TELEGRAM_ENABLED,
    TOR_SOCKS_PROXY,
)
from mining_dashboard.helper.utils import effective_hashrate, format_duration, format_hashrate
from mining_dashboard.service.earnings import xmr_per_hs_day
from mining_dashboard.service.egress import egress_posture_from_config
from mining_dashboard.service.metrics import build_metrics
from mining_dashboard.service.telegram_notifier import TELEGRAM_API_BASE
from mining_dashboard.version import resolve_version
from mining_dashboard.web.views import build_badges

logger = logging.getLogger("TelegramCommands")

# Seconds handed to getUpdates: Telegram holds the request open until an update arrives or this
# elapses, so the bot makes ~one request per interval while idle (long-poll, not busy-poll).
LONG_POLL_SECONDS = 25
# Quiet retry after a failed poll — a Tor-only / offline host can't reach api.telegram.org, so a
# persistently-blocked bot backs off instead of hot-looping (and never spams ERROR; #59 discipline).
POLL_ERROR_BACKOFF_SECONDS = 15

# The commands the bot answers. All are read-only status queries — the bot can never change the
# stack (start/stop/apply live on the CLI), so a leaked chat can at worst read status, not act.
COMMANDS = (
    "status",
    "info",
    "hashrate",
    "workers",
    "sync",
    "system",
    "pool",
    "xvb",
    "earnings",
    "help",
)

HELP_TEXT = (
    "Pithead bot — commands:\n"
    "/status — stack health at a glance\n"
    "/info — version, updates, DB mode, privacy posture\n"
    "/hashrate — total + per-worker hashrate\n"
    "/workers — each rig's online/offline state\n"
    "/sync — Monero + Tari node sync progress\n"
    "/system — host disk, RAM, CPU, HugePages\n"
    "/pool — P2Pool sidechain + Monero network\n"
    "/xvb — XvB mode, tier, and raffle eligibility\n"
    "/earnings — estimated P2Pool XMR per day\n"
    "/help — this message"
)


def _prefix(host_label):
    """Hostname tag so replies from several stacks sharing one chat stay distinguishable.
    'Unknown Host' is config.py's placeholder when HOST_IP is unset — drop it, don't print it."""
    if host_label in (None, "", "Unknown Host"):
        return ""
    return f"[{host_label}] "


def parse_command(text):
    """Extract the command word from a message, or ``None`` if it isn't a slash command.

    Returns the bare command (lowercased, with any ``@botname`` suffix stripped — Telegram appends
    it in groups, e.g. ``/status@PitheadBot``). An unrecognized slash command comes back as
    ``"unknown"`` so the caller can nudge with the help text; plain chatter returns ``None`` and is
    ignored, so the bot never talks over a group it happens to share.
    """
    if not text:
        return None
    text = text.strip()
    if not text.startswith("/"):
        return None
    word = text.split(maxsplit=1)[0]
    cmd = word[1:].split("@", 1)[0].lower()
    if not cmd:
        return None
    return cmd if cmd in COMMANDS else "unknown"


def _node_state(sync):
    """One-glance node health from a :class:`~mining_dashboard.service.metrics.SyncMetric`."""
    if sync.down:
        return "\U0001f534 down"
    if sync.done:
        return "\U0001f7e2 synced"
    return f"⏳ syncing {sync.percent:.1f}%"


def _human_count(n):
    """Compact SI-suffixed number for large figures like network difficulty (380_000_000_000 →
    '380.00 G'). Small values pass through as a plain integer."""
    n = float(n or 0)
    for unit in ("", "K", "M", "G", "T", "P"):
        if abs(n) < 1000:
            return f"{n:.2f} {unit}".strip() if unit else f"{int(n)}"
        n /= 1000
    return f"{n:.2f} E"


def format_status(metrics, mining_active, host_label="", warnings=None, merge_mining=None):
    """Overall stack health — the answer to '/status'. Pure: folds a :class:`Metrics` (plus the
    mining-active flag the loop derives from the sync gate, any active warning/error badges, and the
    Tari merge-mine link state) into text; no I/O. ``merge_mining`` is the gRPC-connected flag — a
    distinct signal from a synced Tari node (the link can be down while the node is up), or ``None``
    to omit the line (Tari not in play)."""
    lines = [
        f"{_prefix(host_label)}\U0001f4ca Pithead status",
        f"Monero node: {_node_state(metrics.monero)}",
        f"Tari node: {_node_state(metrics.tari)}",
    ]
    if merge_mining is not None:
        lines.append(f"Merge-mining: {'🟢 Tari linked' if merge_mining else '⏸ Tari not linked'}")
    if metrics.global_syncing:
        lines.append("Mining: ⏳ holding — chain(s) syncing")
    elif mining_active:
        lines.append(f"Mining: \U0001f7e2 active ({metrics.mode})")
    else:
        lines.append("Mining: \U0001f534 not mining")
    lines.append(f"Workers: {metrics.workers_online}/{metrics.workers_total} online")
    lines.append(f"Hashrate: {format_hashrate(metrics.total_h15)} (10m avg)")
    lines.append(f"PPLNS shares: {metrics.shares_in_window} in window")
    # Surface the same warning/error badges the dashboard's top bar shows (#104), so /status is a
    # one-glance "anything wrong?" — or an explicit all-clear.
    if warnings:
        lines.append("")
        lines.append("⚠️ Warnings:")
        lines.extend(f"• {w}" for w in warnings)
    else:
        lines.append("")
        lines.append("✅ No warnings.")
    return "\n".join(lines)


def format_info(version, update, metrics, egress_summary, host_label=""):
    """The 'about this stack' card — the answer to '/info'. Folds the build version, whether an
    upgrade is available, the Monero DB mode, the P2Pool sidechain, and the privacy (egress) posture
    into one glance. Static-ish facts, kept out of /status (which is live health)."""
    lines = [f"{_prefix(host_label)}\U0001f4df Pithead info"]

    ver = (version or {}).get("text", "unknown")
    lines.append(f"Version: {ver}{' (dev build)' if (version or {}).get('dev') else ''}")

    update = update or {}
    if update.get("available") and update.get("latest"):
        lines.append(f"Updates: \U0001f195 {update['latest']} available — ./pithead upgrade")
    else:
        lines.append("Updates: ✅ Up to date")

    mode = metrics.monero_mode
    lines.append(f"Monero DB: {mode}" if mode in ("Pruned", "Full") else "Monero DB: unknown")
    lines.append(f"Sidechain: P2Pool {metrics.pool_type}")

    egress_summary = egress_summary or {}
    if egress_summary.get("all_tor", True):
        lines.append("Egress: \U0001f9c5 Tor-only")
    else:
        lines.append(f"Egress: ⚠️ {egress_summary.get('label', 'clearnet exposure')}")
    return "\n".join(lines)


def status_warnings(data, metrics, db_healthy):
    """The active warning/error badges for /status: every ``bad`` badge plus the ``⚠``-flagged
    ``warn`` badges (which the informational states — 'Syncing…', 'Miner held' — deliberately lack),
    reusing :func:`build_badges` so this never drifts from the dashboard's own top bar. The leading
    ``⚠`` is stripped since the section already has one header."""
    out = []
    for b in build_badges(data, metrics, "", db_healthy=db_healthy):
        if b["variant"] == "bad" or b["text"].startswith("⚠"):
            out.append(b["text"].removeprefix("⚠ "))
    return out


def format_hashrate_reply(metrics, workers, host_label=""):
    """Total + per-online-worker hashrate — the answer to '/hashrate'.

    Both the total and each per-worker figure use the same :func:`effective_hashrate` (10m average,
    1m fallback for a rig without 10m history yet), so the per-worker lines add up to the total —
    a just-connected worker reads its real live rate, not 0.
    """
    lines = [
        f"{_prefix(host_label)}⚡ Hashrate",
        f"Total: {format_hashrate(metrics.total_h15)} (10m avg)",
    ]
    online = [w for w in workers if w.get("status") == "online"]
    if not online:
        lines.append("No workers online.")
    for w in sorted(online, key=effective_hashrate, reverse=True):
        lines.append(f"• {w.get('name', '?')}: {format_hashrate(effective_hashrate(w))}")
    return "\n".join(lines)


def format_workers(workers, host_label=""):
    """Per-worker online/offline roll-call — the answer to '/workers'. Offline first-sighted
    workers are those xmrig-proxy still lists with a dead connection."""
    if not workers:
        return f"{_prefix(host_label)}\U0001f477 Workers\nNo workers connected."
    lines = [f"{_prefix(host_label)}\U0001f477 Workers"]
    # Online first, then by name — the offline ones are what an operator scans for.
    for w in sorted(workers, key=lambda w: (w.get("status") != "online", w.get("name", ""))):
        if w.get("status") == "online":
            up = w.get("uptime") or 0
            tail = f" · up {format_duration(up)}" if up else ""
            lines.append(
                f"\U0001f7e2 {w.get('name', '?')} — {format_hashrate(effective_hashrate(w))}{tail}"
            )
        else:
            lines.append(f"\U0001f534 {w.get('name', '?')} — offline")
    return "\n".join(lines)


def _sync_line(name, sync):
    if sync.down:
        return f"{name}: \U0001f534 node down"
    if sync.done:
        return f"{name}: \U0001f7e2 synced"
    if sync.has_target:
        return f"{name}: ⏳ {sync.percent:.1f}% ({sync.current:,}/{sync.target:,})"
    return f"{name}: ⏳ syncing {sync.percent:.1f}%"


def format_sync(metrics, host_label=""):
    """Monero + Tari sync progress — the answer to '/sync'."""
    return "\n".join(
        [
            f"{_prefix(host_label)}\U0001f504 Sync status",
            _sync_line("Monero", metrics.monero),
            _sync_line("Tari", metrics.tari),
        ]
    )


def format_system(system, host_label=""):
    """Host resource usage — the answer to '/system'. Reads the ``system`` snapshot the dashboard
    already collects (disk / RAM / CPU / load / HugePages)."""
    disk = system.get("disk", {})
    mem = system.get("memory", {})
    hp_status, _hp_class, hp_value = system.get("hugepages", ["Unknown", "", "0/0"])
    return "\n".join(
        [
            f"{_prefix(host_label)}\U0001f5a5️ System",
            f"Disk: {disk.get('used_gb', 0):.1f}/{disk.get('total_gb', 0):.1f} GB "
            f"({disk.get('percent_str', '0%')})",
            f"RAM: {mem.get('used_gb', 0):.1f}/{mem.get('total_gb', 0):.1f} GB "
            f"({mem.get('percent_str', '0%')})",
            f"CPU: {system.get('cpu_percent', '0%')} · load {system.get('load', 'n/a')}",
            f"HugePages: {hp_status} ({hp_value})",
        ]
    )


def format_pool(metrics, data=None, host_label=""):
    """P2Pool sidechain + Monero network figures — the answer to '/pool'. Enriched with the share
    submission health and best share the proxy tracks, and the node's found blocks (#82)."""
    data = data or {}
    lines = [
        f"{_prefix(host_label)}\U0001f30a Pool & network",
        f"Sidechain: P2Pool {metrics.pool_type}",
        f"Pool hashrate: {format_hashrate(metrics.pool_hashrate)}",
    ]
    blocks = (data.get("pool", {}) or {}).get("pool", {}).get("blocks_found")
    if blocks:
        lines.append(f"Blocks found: {blocks:,}")
    lines.append(
        f"Network: height {metrics.network_height:,} · diff {_human_count(metrics.network_difficulty)}"
    )
    lines.append(
        f"PPLNS shares: {metrics.shares_in_window} in window ({metrics.pplns_window} blocks)"
    )
    # Current share effort — a luck indicator (<100% = finding shares faster than average).
    stratum = data.get("stratum", {}) or {}
    if "current_effort" in stratum:
        lines.append(f"Effort: {stratum['current_effort']:.1f}%")
    # Share submission health from the xmrig-proxy /summary (#82): accepted/rejected + best found.
    summary = data.get("proxy_summary", {}) or {}
    accepted = summary.get("accepted", 0) or 0
    rejected = summary.get("rejected", 0) or 0
    if accepted or rejected:
        total = accepted + rejected
        reject_pct = (rejected / total * 100) if total else 0.0
        lines.append(f"Shares to pool: {accepted:,} ✓ / {rejected:,} ✗ ({reject_pct:.2f}% rejects)")
    best = summary.get("best", 0) or 0
    if best:
        lines.append(f"Best share: \U0001f48e {int(best):,}")
    return "\n".join(lines)


def format_xvb(metrics, host_label=""):
    """XvB mode / tier / raffle eligibility — the answer to '/xvb'."""
    prefix = _prefix(host_label)
    if not metrics.xvb_enabled:
        return f"{prefix}\U0001f3b0 XvB is disabled."
    lines = [
        f"{prefix}\U0001f3b0 XvB",
        f"Mode: {metrics.mode}",
        f"Current tier: {metrics.current_tier}",
        f"Target tier: {metrics.target_tier}",
        f"Routed to XvB: {format_hashrate(metrics.xvb_routed_1h)} (1h)",
        # Credited averages are what XvB itself measures — the figures that actually set your tier
        # (routed above is what we send; credited is what counts). Showing both explains the tier.
        f"Credited by XvB: {format_hashrate(metrics.xvb_1h)} (1h) · "
        f"{format_hashrate(metrics.xvb_24h)} (24h)",
    ]
    # The share half of raffle eligibility (#158): no PPLNS share means XvB wins are skipped.
    if metrics.shares_in_window > 0:
        lines.append("PPLNS share: \U0001f7e2 held (raffle-eligible)")
    else:
        lines.append("PPLNS share: ⚠ none — XvB wins skipped")
    if metrics.xvb_stale:
        lines.append("⚠ XvB stats are stale — showing last-known values.")
    return "\n".join(lines)


def format_earnings(metrics, network, host_label=""):
    """Estimated P2Pool XMR earnings — the answer to '/earnings'. Reuses the same rate the dashboard
    calculator uses (``xmr_per_hs_day``) applied to the displayed P2Pool 1h-average hashrate; Tari
    merge-mining earnings are a separate thing and not included (#12)."""
    reward_atomic = (network or {}).get("reward", 0) or 0
    coeff_day = xmr_per_hs_day(reward_atomic, metrics.network_difficulty)
    if coeff_day <= 0:
        return f"{_prefix(host_label)}\U0001f4b0 Earnings estimate unavailable (waiting on network data)."
    daily_1h = coeff_day * metrics.p2pool_1h
    lines = [
        f"{_prefix(host_label)}\U0001f4b0 Estimated P2Pool earnings",
        f"1h avg {format_hashrate(metrics.p2pool_1h)} → ~{daily_1h:.6f} XMR/day",
    ]
    # The 24h average smooths the variance a 1h window carries, so it's the steadier projection —
    # shown (and used for the 30-day figure) only once there's a day of history to average.
    if metrics.p2pool_24h > 0:
        daily_24h = coeff_day * metrics.p2pool_24h
        lines.append(
            f"24h avg {format_hashrate(metrics.p2pool_24h)} → ~{daily_24h:.6f} XMR/day "
            f"· ~{daily_24h * 30:.5f} XMR/30d"
        )
    else:
        lines.append(f"~{daily_1h * 30:.5f} XMR/30d")
    lines.append("Estimate only — excludes XvB-donated hashrate and Tari merge-mining.")
    return "\n".join(lines)


# Friendly labels for the daily incident log (#342), keyed by AlertService event.
_INCIDENT_LABELS = {
    "node_down": "node down",
    "worker_offline": "worker offline",
    "disk_space": "disk warning",
    "db_unhealthy": "DB write fail",
    "xvb_no_share": "XvB no-share",
    "xvb_registration": "XvB registration",
    "clearnet_exposed": "clearnet exposure",
    "hashrate_low": "hashrate low",
    "hashrate_loss": "hashrate drop",
}


def _incident_line(incidents):
    """One-line roll-up of the day's problems, or an all-clear. ``incidents`` is a {event: count}
    dict (from ``AlertService.drain_incidents``); ``None`` means the caller didn't track any."""
    if incidents is None:
        return None
    if not incidents:
        return "\U0001f7e2 No incidents in the last 24h"
    parts = [
        f"{n}× {_INCIDENT_LABELS.get(k, k)}"
        for k, n in sorted(incidents.items(), key=lambda kv: (-kv[1], kv[0]))
    ]
    return "\U0001f6a8 Incidents (24h): " + " · ".join(parts)


def format_daily_summary(metrics, data, host_label="", now=None, incidents=None):
    """The once-a-day retrospective pushed by the alerter — **what happened across the fleet over
    the last 24h**, not a live snapshot. Reuses the same domain values the dashboard shows.

    Consistency by construction: the fleet 24h figure is the sum of each rig's 24h average, and the
    XvB split is that total apportioned by the day's routing fraction — so the per-rig lines add up
    to the headline and P2Pool + XvB equals it. ``now`` is injectable for tests; it stamps the
    message and bounds the 24h share count.
    """
    now = time.time() if now is None else now
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(now))
    online = [w for w in data.get("workers", []) if w.get("status") == "online"]
    fleet_24h = sum(w.get("h24h", 0) or 0 for w in online)
    shares_24h = sum(1 for s in data.get("shares", []) if s.get("ts", 0) >= now - 86400)

    lines = [f"{_prefix(host_label)}\U0001f4c5 Daily summary — {stamp}"]
    incident_line = _incident_line(incidents)
    if incident_line:
        lines.append(incident_line)
    lines.append(f"⚡ 24h hashrate: {format_hashrate(fleet_24h)}")
    if metrics.xvb_enabled:
        routed = (metrics.p2pool_24h or 0) + (metrics.xvb_routed_24h or 0)
        xvb_frac = (metrics.xvb_routed_24h or 0) / routed if routed else 0
        xvb_hr = fleet_24h * xvb_frac
        lines.append(
            f"   \U0001f535 P2Pool {format_hashrate(fleet_24h - xvb_hr)} · "
            f"\U0001f3b2 XvB {format_hashrate(xvb_hr)} ({xvb_frac * 100:.0f}% to XvB)"
        )
        lines.append(f"\U0001f3b0 XvB tier: {metrics.current_tier}")
    lines.append(f"\U0001f3af Shares (24h): {shares_24h}")

    reward = (data.get("network", {}) or {}).get("reward", 0) or 0
    coeff = xmr_per_hs_day(reward, metrics.network_difficulty)
    if coeff > 0:
        lines.append(
            f"\U0001f4b0 Est. earnings: ~{coeff * (metrics.p2pool_24h or 0):.6f} XMR/day (P2Pool)"
        )

    lines.append(f"\U0001f477 Miners: {metrics.workers_online}/{metrics.workers_total} online")
    for w in sorted(online, key=lambda w: w.get("h24h", 0) or 0, reverse=True):
        lines.append(f"   • {w.get('name', '?')}: {format_hashrate(w.get('h24h', 0))}")

    disk = (data.get("system", {}) or {}).get("disk", {}) or {}
    lines.append(f"\U0001f4be Disk: {disk.get('percent_str', 'n/a')} used")
    return "\n".join(lines)


class TelegramCommandBot:
    """
    On-demand Telegram command interface (Issue #45) — the interactive half of the operator bot.

    Answers a small set of **read-only** status commands (``/status``, ``/hashrate``, ``/workers``,
    ``/sync``, ``/help``) from the data the dashboard already collects, so it never re-implements
    collection — it reuses :func:`build_metrics`, the same domain layer the web UI renders, so a
    Telegram reply and the dashboard can never disagree.

    Discipline (mirrors :class:`TelegramNotifier`):

    - **Off by default, opt-in.** Enabled only when Telegram is on *and* ``telegram.commands.enabled``
      is set *and* both ``bot_token`` and ``chat_id`` are present. Otherwise :meth:`run` returns
      immediately, so the background task is a cheap no-op for the default stack.
    - **Long-poll, no inbound port.** Uses ``getUpdates`` (outbound only) over the same egress the
      notifier uses — a webhook would need a public inbound endpoint the Tor-first appliance can't
      offer. Nothing is exposed.
    - **Single-chat access control.** Only the configured ``chat_id`` is answered; every other update
      is dropped silently, so an unknown chat gets no reply and can't use the bot as a probe oracle.
    - **Read-only.** No command mutates the stack (lifecycle stays on the CLI), so a compromised chat
      can at worst read status.
    - **Fail silent, never leaks the token.** Network errors (offline / Tor-only host) are swallowed
      at debug and the poll backs off; the ``bot_token`` only ever appears in the request URL and is
      never written to a log line.
    - **No stale replay.** On startup the backlog is skipped (offset primed past pending updates), so
      a command sent while the dashboard was down isn't executed minutes later on restart.
    """

    def __init__(
        self,
        data_service,
        *,
        enabled=None,
        bot_token=TELEGRAM_BOT_TOKEN,
        chat_id=TELEGRAM_CHAT_ID,
        host_label=HOST_IP,
        api_base=TELEGRAM_API_BASE,
        long_poll=LONG_POLL_SECONDS,
        tor_proxy=TOR_SOCKS_PROXY,
    ):
        self.data_service = data_service
        self._token = (bot_token or "").strip()
        # chat_id may be a negative group id (e.g. -1001234567890); keep it a string for exact
        # equality against the id Telegram sends back.
        self.chat_id = str(chat_id or "").strip()
        self.host_label = host_label
        self._api_base = api_base.rstrip("/")
        self.long_poll = long_poll
        # Route getUpdates + replies over the bridge Tor SOCKS proxy, so polling Telegram never
        # exposes the host IP (same discipline as the notifier / Healthchecks pinger).
        self._proxies = {"http": tor_proxy, "https": tor_proxy} if tor_proxy else None
        if enabled is None:
            enabled = bool(TELEGRAM_ENABLED and TELEGRAM_COMMANDS_ENABLED)
        self.enabled = bool(enabled and self._token and self.chat_id)
        self._offset = None

    def reply_for(self, text):
        """Map an incoming message to a reply string, or ``None`` to stay silent.

        Reads the latest snapshot and runs the shared :func:`build_metrics` (a couple of quick local
        SQLite reads); the caller runs this off-thread so a slow read can't stall the poll loop.
        """
        cmd = parse_command(text)
        if cmd is None:
            return None
        if cmd == "help":
            return f"{_prefix(self.host_label)}{HELP_TEXT}"
        if cmd == "unknown":
            return f"{_prefix(self.host_label)}Unknown command.\n{HELP_TEXT}"

        data = self.data_service.latest_data or {}
        # /system reads the raw snapshot only — no need to build the full metrics.
        if cmd == "system":
            return format_system(data.get("system", {}), self.host_label)

        metrics = build_metrics(data, self.data_service.state_manager)
        if cmd == "status":
            mining = bool(data.get("miner_released") and not data.get("workers_rejected"))
            warnings = status_warnings(
                data, metrics, self.data_service.state_manager.is_db_healthy()
            )
            # Merge-mine link = the Tari gRPC being READY (not merely the node being up) — the same
            # rule the dashboard's ✔ uses (#313). Omitted until Tari has been polled at all.
            tari = data.get("tari")
            merge = (bool(tari.get("connected")) and bool(tari.get("active"))) if tari else None
            return format_status(
                metrics, mining, self.host_label, warnings=warnings, merge_mining=merge
            )
        if cmd == "info":
            return format_info(
                resolve_version(),
                data.get("update"),
                metrics,
                egress_posture_from_config()["summary"],
                self.host_label,
            )
        if cmd == "hashrate":
            return format_hashrate_reply(metrics, data.get("workers", []), self.host_label)
        if cmd == "workers":
            return format_workers(data.get("workers", []), self.host_label)
        if cmd == "sync":
            return format_sync(metrics, self.host_label)
        if cmd == "pool":
            return format_pool(metrics, data, self.host_label)
        if cmd == "xvb":
            return format_xvb(metrics, self.host_label)
        if cmd == "earnings":
            return format_earnings(metrics, data.get("network", {}), self.host_label)
        return None

    async def run(self):
        """Long-poll for commands until cancelled. A no-op when disabled.

        The network calls use ``requests`` (so they ride the same Tor SOCKS proxy as the notifier)
        run off the event loop via :func:`asyncio.to_thread`, so a 25s long-poll never blocks it.
        """
        if not self.enabled:
            return
        logger.info("Telegram command interface enabled — polling for commands (over Tor).")
        await asyncio.to_thread(self._prime_offset)
        while True:
            try:
                updates = await asyncio.to_thread(self._get_updates, self.long_poll)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.debug("Telegram getUpdates failed (%s)", type(exc).__name__)
                await asyncio.sleep(POLL_ERROR_BACKOFF_SECONDS)
                continue
            for update in updates:
                self._offset = update.get("update_id", 0) + 1
                await self._handle_update(update)

    def _prime_offset(self):
        """Advance the offset past any pending backlog without acting on it, so a command queued
        while the dashboard was down isn't run on startup."""
        try:
            updates = self._get_updates(0)
            if updates:
                self._offset = updates[-1].get("update_id", 0) + 1
        except Exception as exc:
            logger.debug("Telegram offset prime skipped (%s)", type(exc).__name__)

    def _get_updates(self, poll_timeout):
        """Blocking ``getUpdates`` over Tor. Called via ``to_thread`` from the loop."""
        params = {"timeout": poll_timeout, "allowed_updates": '["message"]'}
        if self._offset is not None:
            params["offset"] = self._offset
        url = f"{self._api_base}/bot{self._token}/getUpdates"
        # The read timeout must outlast Telegram's long-poll hold, or requests aborts the request
        # the server is legitimately keeping open; (connect, read) tuple.
        resp = requests.get(
            url, params=params, timeout=(10, poll_timeout + 10), proxies=self._proxies
        )
        resp.raise_for_status()
        payload = resp.json()
        if not payload.get("ok"):
            return []
        return payload.get("result", [])

    async def _handle_update(self, update):
        message = update.get("message") or {}
        chat = message.get("chat") or {}
        # Access control: only the configured chat may drive the bot. Anything else is dropped
        # silently — no reply, so an unknown chat can't even confirm the bot exists.
        if str(chat.get("id")) != self.chat_id:
            return
        reply = await asyncio.to_thread(self._safe_reply_for, message.get("text", ""))
        if reply:
            await asyncio.to_thread(self._send, reply)

    def _safe_reply_for(self, text):
        """Never let a formatting/read bug kill the poll loop — a broken command just goes quiet."""
        try:
            return self.reply_for(text)
        except Exception as exc:
            logger.debug("Telegram command handling failed (%s)", type(exc).__name__)
            return None

    def _send(self, text):
        """Blocking reply over Tor. Called via ``to_thread``."""
        url = f"{self._api_base}/bot{self._token}/sendMessage"
        payload = {"chat_id": self.chat_id, "text": text, "disable_web_page_preview": True}
        try:
            resp = requests.post(url, json=payload, timeout=10, proxies=self._proxies)
            resp.raise_for_status()
        except Exception as exc:
            # Log only the exception type — a requests error can embed the token-bearing URL.
            logger.debug("Telegram reply failed (%s)", type(exc).__name__)
