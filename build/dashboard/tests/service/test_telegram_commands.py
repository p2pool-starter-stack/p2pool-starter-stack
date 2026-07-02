"""Unit tests for the on-demand Telegram command interface (Issue #45).

Covers command parsing, the pure reply formatters (fed hand-built Metrics), reply routing
(``build_metrics`` stubbed so no DB is touched), single-chat access control, and the
enabled/disabled gating. No network — the transport is stubbed throughout.
"""

import asyncio
from dataclasses import replace
from types import SimpleNamespace

import pytest

from mining_dashboard.service import telegram_commands as tc
from mining_dashboard.service.metrics import Metrics, SyncMetric

_SYNCED = SyncMetric(
    percent=100, current=10, target=10, remaining=0, has_target=True, done=True, down=False
)
_DOWN = SyncMetric(
    percent=0, current=0, target=0, remaining=0, has_target=False, done=False, down=True
)
_SYNCING = SyncMetric(
    percent=42.5, current=850, target=2000, remaining=1150, has_target=True, done=False, down=False
)

_BASE = Metrics(
    total_h15=10500.0,
    p2pool_1h=8000.0,
    p2pool_24h=8100.0,
    xvb_1h=2100.0,
    xvb_24h=2300.0,
    xvb_routed_1h=2000.0,
    xvb_routed_24h=2050.0,
    stratum_h15=10300.0,
    stratum_h1h=10400.0,
    stratum_h24h=10200.0,
    mode="P2POOL",
    xvb_enabled=True,
    current_tier="Donor",
    target_tier="Donor",
    target_threshold=1000.0,
    target_sustainable=True,
    low_hr_warning=False,
    xvb_fail_count=0,
    xvb_last_update=0,
    workers_online=2,
    workers_total=3,
    shares_in_window=5,
    pplns_window=2160,
    block_time=10,
    pool_type="Mini",
    pool_hashrate=120_000_000.0,
    pool_difficulty=250_000_000.0,
    network_difficulty=380_000_000_000.0,
    network_height=3210001,
    global_syncing=False,
    monero=_SYNCED,
    tari=_SYNCED,
    monero_mode="Unknown",
    tari_mining=True,
)


def _metrics(**over):
    return replace(_BASE, **over)


# --- parse_command ------------------------------------------------------------------------


@pytest.mark.parametrize(
    "text,expected",
    [
        ("/status", "status"),
        ("  /sync  ", "sync"),
        ("/HASHRATE", "hashrate"),
        ("/system", "system"),
        ("/pool", "pool"),
        ("/xvb", "xvb"),
        ("/status@PitheadBot", "status"),  # group @mention suffix stripped
        ("/workers now please", "workers"),  # only the first word matters
        ("/help", "help"),
        ("/frobnicate", "unknown"),  # a slash command we don't answer
        ("hello there", None),  # plain chatter is ignored
        ("", None),
        (None, None),
        ("/", None),
    ],
)
def test_parse_command(text, expected):
    assert tc.parse_command(text) == expected


# --- formatters ---------------------------------------------------------------------------


def test_status_active():
    out = tc.format_status(_metrics(), mining_active=True)
    assert "Monero node: 🟢 synced" in out
    assert "Mining: 🟢 active (P2POOL)" in out
    assert "Workers: 2/3 online" in out
    assert "10.50 kH/s" in out
    assert "PPLNS shares: 5 in window" in out


def test_status_syncing_beats_mining_flag():
    # While the whole stack is syncing, the reply says "holding", never "active".
    out = tc.format_status(_metrics(global_syncing=True), mining_active=True)
    assert "holding" in out
    assert "active" not in out


def test_status_node_down_and_not_mining():
    out = tc.format_status(_metrics(monero=_DOWN), mining_active=False)
    assert "Monero node: 🔴 down" in out
    assert "Mining: 🔴 not mining" in out


def test_hashrate_lists_online_workers_desc():
    workers = [
        {"name": "rig-a", "status": "online", "h15": 3000},
        {"name": "rig-b", "status": "online", "h15": 7000},
        {"name": "rig-c", "status": "offline", "h15": 0},
    ]
    out = tc.format_hashrate_reply(_metrics(), workers)
    # Highest first, offline excluded.
    assert out.index("rig-b") < out.index("rig-a")
    assert "rig-c" not in out


def test_hashrate_no_online_workers():
    out = tc.format_hashrate_reply(_metrics(), [{"name": "x", "status": "offline"}])
    assert "No workers online." in out


def test_workers_online_first_with_offline_flagged():
    workers = [
        {"name": "off-1", "status": "offline", "h15": 0},
        {"name": "on-1", "status": "online", "h15": 5000, "uptime": 3661},
    ]
    out = tc.format_workers(workers)
    lines = out.splitlines()
    assert "🟢 on-1" in lines[1] and "up 1h 1m" in lines[1]  # online first, uptime shown
    assert "🔴 off-1 — offline" in lines[2]


def test_workers_empty():
    assert "No workers connected." in tc.format_workers([])


def test_status_node_syncing_percent():
    # _node_state's "syncing %" branch (not down, not done).
    out = tc.format_status(_metrics(monero=_SYNCING), mining_active=True)
    assert "Monero node: ⏳ syncing 42.5%" in out


def test_sync_line_variants():
    out = tc.format_sync(_metrics(monero=_SYNCING, tari=_DOWN))
    assert "Monero: ⏳ 42.5% (850/2,000)" in out
    assert "Tari: 🔴 node down" in out


def test_sync_line_no_target():
    # A chain that's syncing but hasn't discovered a target height yet.
    no_target = SyncMetric(
        percent=12.0, current=0, target=0, remaining=0, has_target=False, done=False, down=False
    )
    assert "Monero: ⏳ syncing 12.0%" in tc.format_sync(_metrics(monero=no_target))


def test_system_reads_snapshot():
    system = {
        "disk": {"used_gb": 120.4, "total_gb": 500.0, "percent_str": "24%"},
        "memory": {"used_gb": 3.2, "total_gb": 16.0, "percent_str": "20%"},
        "cpu_percent": "12.5%",
        "load": "0.50 0.40 0.30",
        "hugepages": ["Enabled", "status-ok", "3072/3072"],
    }
    out = tc.format_system(system)
    assert "Disk: 120.4/500.0 GB (24%)" in out
    assert "RAM: 3.2/16.0 GB (20%)" in out
    assert "CPU: 12.5%" in out
    assert "HugePages: Enabled (3072/3072)" in out


def test_pool_reads_metrics():
    out = tc.format_pool(_metrics(pool_type="Mini", network_height=3210001))
    assert "P2Pool Mini" in out
    assert "Network height: 3,210,001" in out
    assert "5 in window" in out  # shares_in_window from _BASE


def test_xvb_enabled_with_share():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=5))
    assert "Current tier: Donor" in out
    assert "raffle-eligible" in out


def test_xvb_no_share_warns():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=0))
    assert "wins skipped" in out


def test_xvb_disabled():
    assert "disabled" in tc.format_xvb(_metrics(xvb_enabled=False))


def test_host_label_prefix():
    assert tc.format_sync(_metrics(), host_label="rig-box").startswith("[rig-box] ")
    # The placeholder is never printed.
    assert not tc.format_sync(_metrics(), host_label="Unknown Host").startswith("[")


# --- reply_for routing --------------------------------------------------------------------


def _bot(monkeypatch, latest_data=None, **over):
    monkeypatch.setattr(tc, "build_metrics", lambda data, sm: _metrics(**over))
    ds = SimpleNamespace(latest_data=latest_data or {}, state_manager=object())
    return tc.TelegramCommandBot(ds, enabled=True, bot_token="tok", chat_id="42", host_label="")


def test_reply_for_help_and_unknown_need_no_metrics():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    bot = tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1", host_label="")
    assert "/status" in bot.reply_for("/help")
    assert "Unknown command" in bot.reply_for("/nope")
    assert bot.reply_for("just chatting") is None


def test_reply_for_status_uses_mining_flag(monkeypatch):
    bot = _bot(monkeypatch, latest_data={"miner_released": True, "workers_rejected": False})
    assert "🟢 active" in bot.reply_for("/status")
    # Rejected workers (node-down failover) reads as not mining even when released.
    bot2 = _bot(monkeypatch, latest_data={"miner_released": True, "workers_rejected": True})
    assert "🔴 not mining" in bot2.reply_for("/status")


def test_reply_for_workers_reads_snapshot(monkeypatch):
    workers = [{"name": "z", "status": "online", "h15": 1000}]
    bot = _bot(monkeypatch, latest_data={"workers": workers})
    assert "z" in bot.reply_for("/workers")


def test_reply_for_system_reads_snapshot_without_metrics():
    # /system reads only the raw snapshot — build_metrics must not be needed (left unstubbed).
    ds = SimpleNamespace(latest_data={"system": {"cpu_percent": "9%"}}, state_manager=None)
    bot = tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1", host_label="")
    assert "CPU: 9%" in bot.reply_for("/system")


def test_reply_for_pool_and_xvb(monkeypatch):
    bot = _bot(monkeypatch, latest_data={}, pool_type="Nano")
    assert "P2Pool Nano" in bot.reply_for("/pool")
    assert "XvB" in bot.reply_for("/xvb")


# --- enabled gating -----------------------------------------------------------------------


def test_disabled_without_token_or_chat():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    assert not tc.TelegramCommandBot(ds, enabled=True, bot_token="", chat_id="1").enabled
    assert not tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="").enabled
    assert not tc.TelegramCommandBot(ds, enabled=False, bot_token="t", chat_id="1").enabled
    assert tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1").enabled


async def test_run_is_noop_when_disabled():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    bot = tc.TelegramCommandBot(ds, enabled=False, bot_token="", chat_id="")
    # Returns immediately without touching the network — no session, no poll.
    await bot.run()


# --- access control -----------------------------------------------------------------------


async def test_handle_update_ignores_foreign_chat(monkeypatch):
    bot = _bot(monkeypatch)
    sent = []

    async def _record(session, text):
        sent.append(text)

    monkeypatch.setattr(bot, "_send", _record)
    # chat_id 999 != configured 42 → dropped, nothing sent.
    await bot._handle_update(None, {"message": {"chat": {"id": 999}, "text": "/help"}})
    assert sent == []


async def test_handle_update_replies_to_configured_chat(monkeypatch):
    bot = _bot(monkeypatch)
    sent = []

    async def _record(session, text):
        sent.append(text)

    monkeypatch.setattr(bot, "_send", _record)
    await bot._handle_update(None, {"message": {"chat": {"id": 42}, "text": "/help"}})
    assert len(sent) == 1 and "/status" in sent[0]


# --- transport (stubbed aiohttp session) --------------------------------------------------


class _Resp:
    """Minimal stand-in for an aiohttp response context manager."""

    def __init__(self, payload=None, raise_on_enter=None, raise_on_status=False):
        self._payload = payload or {}
        self._raise_on_enter = raise_on_enter
        self._raise_on_status = raise_on_status

    async def __aenter__(self):
        if self._raise_on_enter:
            raise self._raise_on_enter
        return self

    async def __aexit__(self, *exc):
        return False

    def raise_for_status(self):
        if self._raise_on_status:
            raise RuntimeError("http error")

    async def json(self):
        return self._payload


class _Session:
    """Stub aiohttp session: hands back queued responses and records calls."""

    def __init__(self, gets=None, posts=None):
        self._gets = list(gets or [])
        self._posts = list(posts or [])
        self.get_calls = []
        self.post_calls = []

    def get(self, url, params=None, timeout=None):
        self.get_calls.append((url, params))
        return self._gets.pop(0)

    def post(self, url, json=None, timeout=None):
        self.post_calls.append((url, json))
        return self._posts.pop(0)


def _make_bot():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    return tc.TelegramCommandBot(ds, enabled=True, bot_token="tok", chat_id="42")


async def test_get_updates_parses_results_and_sends_offset():
    bot = _make_bot()
    bot._offset = 7
    session = _Session(gets=[_Resp({"ok": True, "result": [{"update_id": 8}]})])
    result = await bot._get_updates(session, 0)
    assert result == [{"update_id": 8}]
    url, params = session.get_calls[0]
    assert "bottok" in url and params["offset"] == 7  # token in URL, offset forwarded


async def test_get_updates_not_ok_returns_empty():
    bot = _make_bot()
    session = _Session(gets=[_Resp({"ok": False})])
    assert await bot._get_updates(session, 0) == []


async def test_prime_offset_skips_backlog():
    bot = _make_bot()
    session = _Session(gets=[_Resp({"ok": True, "result": [{"update_id": 3}, {"update_id": 9}]})])
    await bot._prime_offset(session)
    assert bot._offset == 10  # past the last pending update


async def test_prime_offset_swallows_error():
    bot = _make_bot()
    session = _Session(gets=[_Resp(raise_on_enter=OSError("offline"))])
    await bot._prime_offset(session)  # must not raise
    assert bot._offset is None


async def test_send_posts_message():
    bot = _make_bot()
    session = _Session(posts=[_Resp({"ok": True})])
    await bot._send(session, "hi")
    url, body = session.post_calls[0]
    assert "bottok" in url and body["chat_id"] == "42" and body["text"] == "hi"


async def test_send_swallows_network_error():
    bot = _make_bot()
    session = _Session(posts=[_Resp(raise_on_status=True)])
    await bot._send(session, "hi")  # must not raise


async def test_run_processes_update_then_honours_cancel(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(bot, "_prime_offset", _async_noop)
    handled = []

    async def _fake_handle(session, update):
        handled.append(update)

    calls = {"n": 0}

    async def _fake_get(session, poll_timeout):
        calls["n"] += 1
        if calls["n"] == 1:
            return [{"update_id": 1}]
        raise asyncio.CancelledError

    monkeypatch.setattr(bot, "_handle_update", _fake_handle)
    monkeypatch.setattr(bot, "_get_updates", _fake_get)
    with pytest.raises(asyncio.CancelledError):
        await bot.run()
    assert handled == [{"update_id": 1}] and bot._offset == 2


async def test_run_backs_off_on_poll_error(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(bot, "_prime_offset", _async_noop)
    slept = []

    async def _sleep(secs):
        slept.append(secs)
        raise asyncio.CancelledError  # break out after the first backoff

    async def _boom(session, poll_timeout):
        raise OSError("telegram unreachable")

    monkeypatch.setattr(tc.asyncio, "sleep", _sleep)
    monkeypatch.setattr(bot, "_get_updates", _boom)
    with pytest.raises(asyncio.CancelledError):
        await bot.run()
    assert slept == [tc.POLL_ERROR_BACKOFF_SECONDS]


async def _async_noop(*args, **kwargs):
    return None
