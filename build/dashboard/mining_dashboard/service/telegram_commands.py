import asyncio
import logging

import aiohttp

from mining_dashboard.config.config import (
    HOST_IP,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
    TELEGRAM_COMMANDS_ENABLED,
    TELEGRAM_ENABLED,
)
from mining_dashboard.helper.utils import format_duration, format_hashrate
from mining_dashboard.service.metrics import build_metrics
from mining_dashboard.service.telegram_notifier import TELEGRAM_API_BASE

logger = logging.getLogger("TelegramCommands")

# Seconds handed to getUpdates: Telegram holds the request open until an update arrives or this
# elapses, so the bot makes ~one request per interval while idle (long-poll, not busy-poll).
LONG_POLL_SECONDS = 25
# Quiet retry after a failed poll — a Tor-only / offline host can't reach api.telegram.org, so a
# persistently-blocked bot backs off instead of hot-looping (and never spams ERROR; #59 discipline).
POLL_ERROR_BACKOFF_SECONDS = 15

# The commands the bot answers. All are read-only status queries — the bot can never change the
# stack (start/stop/apply live on the CLI), so a leaked chat can at worst read status, not act.
COMMANDS = ("status", "hashrate", "workers", "sync", "help")

HELP_TEXT = (
    "Pithead bot — commands:\n"
    "/status — stack health at a glance\n"
    "/hashrate — total + per-worker hashrate\n"
    "/workers — each rig's online/offline state\n"
    "/sync — Monero + Tari node sync progress\n"
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


def format_status(metrics, mining_active, host_label=""):
    """Overall stack health — the answer to '/status'. Pure: folds a :class:`Metrics` (plus the
    mining-active flag the loop derives from the sync gate) into text; no I/O."""
    lines = [
        f"{_prefix(host_label)}\U0001f4ca Pithead status",
        f"Monero node: {_node_state(metrics.monero)}",
        f"Tari node: {_node_state(metrics.tari)}",
    ]
    if metrics.global_syncing:
        lines.append("Mining: ⏳ holding — chain(s) syncing")
    elif mining_active:
        lines.append(f"Mining: \U0001f7e2 active ({metrics.mode})")
    else:
        lines.append("Mining: \U0001f534 not mining")
    lines.append(f"Workers: {metrics.workers_online}/{metrics.workers_total} online")
    lines.append(f"Hashrate: {format_hashrate(metrics.total_h15)} (10m avg)")
    lines.append(f"PPLNS shares: {metrics.shares_in_window} in window")
    return "\n".join(lines)


def format_hashrate_reply(metrics, workers, host_label=""):
    """Total + per-online-worker hashrate — the answer to '/hashrate'."""
    lines = [
        f"{_prefix(host_label)}⚡ Hashrate",
        f"Total: {format_hashrate(metrics.total_h15)} (10m avg)",
    ]
    online = [w for w in workers if w.get("status") == "online"]
    if not online:
        lines.append("No workers online.")
    for w in sorted(online, key=lambda w: w.get("h15", 0) or 0, reverse=True):
        lines.append(f"• {w.get('name', '?')}: {format_hashrate(w.get('h15', 0))}")
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
                f"\U0001f7e2 {w.get('name', '?')} — {format_hashrate(w.get('h15', 0))}{tail}"
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
    ):
        self.data_service = data_service
        self._token = (bot_token or "").strip()
        # chat_id may be a negative group id (e.g. -1001234567890); keep it a string for exact
        # equality against the id Telegram sends back.
        self.chat_id = str(chat_id or "").strip()
        self.host_label = host_label
        self._api_base = api_base.rstrip("/")
        self.long_poll = long_poll
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
        metrics = build_metrics(data, self.data_service.state_manager)
        if cmd == "status":
            mining = bool(data.get("miner_released") and not data.get("workers_rejected"))
            return format_status(metrics, mining, self.host_label)
        if cmd == "hashrate":
            return format_hashrate_reply(metrics, data.get("workers", []), self.host_label)
        if cmd == "workers":
            return format_workers(data.get("workers", []), self.host_label)
        if cmd == "sync":
            return format_sync(metrics, self.host_label)
        return None

    async def run(self):
        """Long-poll for commands until cancelled. A no-op when disabled."""
        if not self.enabled:
            return
        logger.info("Telegram command interface enabled — polling for commands.")
        async with aiohttp.ClientSession() as session:
            await self._prime_offset(session)
            while True:
                try:
                    updates = await self._get_updates(session, self.long_poll)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    logger.debug("Telegram getUpdates failed (%s)", type(exc).__name__)
                    await asyncio.sleep(POLL_ERROR_BACKOFF_SECONDS)
                    continue
                for update in updates:
                    self._offset = update.get("update_id", 0) + 1
                    await self._handle_update(session, update)

    async def _prime_offset(self, session):
        """Advance the offset past any pending backlog without acting on it, so a command queued
        while the dashboard was down isn't run on startup."""
        try:
            updates = await self._get_updates(session, 0)
            if updates:
                self._offset = updates[-1].get("update_id", 0) + 1
        except Exception as exc:
            logger.debug("Telegram offset prime skipped (%s)", type(exc).__name__)

    async def _get_updates(self, session, poll_timeout):
        params = {"timeout": poll_timeout, "allowed_updates": '["message"]'}
        if self._offset is not None:
            params["offset"] = self._offset
        url = f"{self._api_base}/bot{self._token}/getUpdates"
        # The client read timeout must outlast Telegram's long-poll hold, or aiohttp aborts the
        # request the server is legitimately keeping open.
        client_timeout = aiohttp.ClientTimeout(total=poll_timeout + 10)
        async with session.get(url, params=params, timeout=client_timeout) as resp:
            resp.raise_for_status()
            payload = await resp.json()
        if not payload.get("ok"):
            return []
        return payload.get("result", [])

    async def _handle_update(self, session, update):
        message = update.get("message") or {}
        chat = message.get("chat") or {}
        # Access control: only the configured chat may drive the bot. Anything else is dropped
        # silently — no reply, so an unknown chat can't even confirm the bot exists.
        if str(chat.get("id")) != self.chat_id:
            return
        reply = await asyncio.to_thread(self._safe_reply_for, message.get("text", ""))
        if reply:
            await self._send(session, reply)

    def _safe_reply_for(self, text):
        """Never let a formatting/read bug kill the poll loop — a broken command just goes quiet."""
        try:
            return self.reply_for(text)
        except Exception as exc:
            logger.debug("Telegram command handling failed (%s)", type(exc).__name__)
            return None

    async def _send(self, session, text):
        url = f"{self._api_base}/bot{self._token}/sendMessage"
        payload = {"chat_id": self.chat_id, "text": text, "disable_web_page_preview": True}
        try:
            async with session.post(
                url, json=payload, timeout=aiohttp.ClientTimeout(total=10)
            ) as resp:
                resp.raise_for_status()
        except Exception as exc:
            # Log only the exception type — a requests/aiohttp error can embed the token-bearing URL.
            logger.debug("Telegram reply failed (%s)", type(exc).__name__)
