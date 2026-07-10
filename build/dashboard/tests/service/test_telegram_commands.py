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
        ("/info", "info"),
        ("  /sync  ", "sync"),
        ("/HASHRATE", "hashrate"),
        ("/system", "system"),
        ("/pool", "pool"),
        ("/xvb", "xvb"),
        ("/earnings", "earnings"),
        ("/luck", "luck"),
        ("/luck@Bot", "luck"),
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


def test_status_xvb_split_line():
    # XvB on with routed history → one "24h split" line, same math as the daily summary.
    out = tc.format_status(_metrics(), mining_active=True)
    assert "24h split" in out
    assert "P2Pool 8.10 kH/s" in out
    assert "XvB 2.05 kH/s" in out
    assert "20% to XvB" in out  # 2050 / (8100 + 2050) ≈ 20%


def test_status_xvb_off_omits_split():
    out = tc.format_status(_metrics(xvb_enabled=False), mining_active=True)
    assert "to XvB" not in out


def test_status_xvb_no_history_omits_split():
    # No routed history yet (both 24h averages zero) → the line is absent, not "0%".
    out = tc.format_status(_metrics(p2pool_24h=0, xvb_routed_24h=0), mining_active=True)
    assert "24h split" not in out


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


def test_hashrate_uses_effective_rate_for_fresh_worker():
    # A just-connected rig has no 10m (h15) history yet but is mining — it must show its live 1m
    # rate (the same value the total counts), never 0.00. (This was the reported inconsistency.)
    workers = [{"name": "fresh", "status": "online", "h15": 0, "h60": 42000, "h10": 42000}]
    out = tc.format_hashrate_reply(_metrics(), workers)
    assert "42.00 kH/s" in out
    assert "0.00 H/s" not in out


def test_workers_hashrate_uses_effective_rate():
    workers = [{"name": "fresh", "status": "online", "h15": 0, "h60": 5000, "h10": 5000}]
    assert "5.00 kH/s" in tc.format_workers(workers)


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


@pytest.mark.parametrize(
    "n,expected",
    [
        (0, "0"),
        (42, "42"),
        (999, "999"),
        (1500, "1.50 K"),
        (380e9, "380.00 G"),
        (2.5e12, "2.50 T"),
        (3e18, "3.00 E"),  # beyond peta — the fallback branch
    ],
)
def test_human_count(n, expected):
    assert tc._human_count(n) == expected


def test_pool_reads_metrics():
    out = tc.format_pool(
        _metrics(pool_type="Mini", network_height=3210001, network_difficulty=380e9)
    )
    assert "P2Pool Mini" in out
    assert "height 3,210,001" in out
    assert "diff 380.00 G" in out
    assert "5 in window" in out  # shares_in_window from _BASE


def test_pool_share_health_and_best_when_present():
    # Proxy /summary + found blocks enrich /pool (#82): acceptance rate, best share, blocks.
    data = {
        "pool": {"pool": {"blocks_found": 3}},
        "proxy_summary": {"accepted": 125_000, "rejected": 40, "best": 2_345_678},
    }
    out = tc.format_pool(_metrics(), data)
    assert "Blocks found: 3" in out
    assert "125,000 ✓ / 40 ✗ (0.03% rejects)" in out
    assert "Best share: 💎 2,345,678" in out


def test_pool_omits_share_lines_before_first_poll():
    # No proxy data yet (fresh start) → no zeroed share/best/blocks lines, just the core figures.
    out = tc.format_pool(_metrics(), {})
    assert "Shares to pool" not in out
    assert "Best share" not in out
    assert "Blocks found" not in out
    assert "Effort" not in out  # no stratum data → no effort line


def test_pool_effort_when_stratum_present():
    # Effort is a luck indicator; shown only once stratum has been polled (the key is present).
    out = tc.format_pool(_metrics(), {"stratum": {"current_effort": 87.3}})
    assert "Effort: 87.3%" in out
    # Effort right after a block can legitimately be 0.0 — still shown (key present), not hidden.
    assert "Effort: 0.0%" in tc.format_pool(_metrics(), {"stratum": {"current_effort": 0.0}})


def test_xvb_enabled_with_share():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=5, xvb_1h=2100, xvb_24h=2300))
    assert "Current tier: Donor" in out
    assert "raffle-eligible" in out
    # Credited averages (what XvB measures → sets the tier) are shown alongside routed.
    assert "Credited by XvB: 2.10 kH/s (1h) · 2.30 kH/s (24h)" in out


def test_xvb_stale_warns():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=5, xvb_stale=True))
    assert "stale" in out
    assert "stale" not in tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=5))


def test_xvb_no_share_warns():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=0))
    assert "wins skipped" in out


def test_xvb_disabled():
    assert "disabled" in tc.format_xvb(_metrics(xvb_enabled=False))


def test_status_merge_mining_line():
    linked = tc.format_status(_metrics(), True, merge_mining=True)
    assert "Merge-mining: 🟢 Tari linked" in linked
    down = tc.format_status(_metrics(), True, merge_mining=False)
    assert "Merge-mining: ⏸ Tari not linked" in down
    # None (Tari not yet polled / not in play) omits the line entirely.
    assert "Merge-mining" not in tc.format_status(_metrics(), True)


def test_earnings_estimate():
    # network reward present + a real difficulty → a positive daily figure, rendered with the
    # dashboard card's adaptive-precision XMR rule (#387): these figures sit in the 6-dp band.
    # coeff = 0.6 XMR / 380e9 * 86400 ≈ 1.364e-7 XMR per H/s per day.
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0, p2pool_24h=8100.0), {"reward": 600_000_000_000}
    )
    assert "1h avg" in out and "~0.001091 XMR/day" in out
    # The 24h average is shown once available and drives the steadier 30d projection.
    assert "24h avg" in out and "~0.001105 XMR/day" in out
    assert "~0.033150 XMR/30d" in out


def test_earnings_falls_back_to_1h_30d_without_24h_history():
    # A fresh node with no 24h average yet still gets a 30d figure (from the 1h rate).
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0, p2pool_24h=0.0), {"reward": 600_000_000_000}
    )
    assert "24h avg" not in out
    assert "XMR/30d" in out


def test_earnings_unavailable_without_network_data():
    out = tc.format_earnings(_metrics(), {})  # no reward → coeff 0
    assert "unavailable" in out


def test_earnings_includes_tari_line_when_merge_mining():
    # #117: live Tari figures → a second line from the SAME 1h-average hashrate (merge-mined
    # alongside the XMR), at the same rate the dashboard calculator publishes.
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        {"reward": 600_000_000_000},
    )
    expected = 8000.0 * (13_000.0 / 420_000_000_000 * 86_400)
    assert f"Tari (merge-mined alongside): ~{expected:.2f} XTM/day" in out
    assert "excludes XvB-donated hashrate" in out  # Tari no longer listed as excluded


def test_earnings_omits_tari_line_without_tari_figures():
    # Tari inactive / still syncing (reward+difficulty at 0) → no phantom XTM line.
    out = tc.format_earnings(_metrics(p2pool_1h=8000.0), {"reward": 600_000_000_000})
    assert "XTM" not in out
    assert "XMR/day" in out  # the XMR estimate is unaffected


def test_luck_reads_the_cadence_metrics():
    # #84: the four figures come straight off Metrics — the same fields the dashboard card shows.
    out = tc.format_luck(
        _metrics(
            last_block_ts=1,  # ancient → the "since" duration renders (days), not "n/a"
            expected_share_sec=3600.0,
            luck_pct=123.4,
            own_pplns_weight=1_234_567.0,
        )
    )
    assert "Since pool's last block: " in out and "n/a" not in out
    assert "Est. time to a share: 1h 0m" in out
    assert "Luck: 123%" in out
    assert "Your PPLNS weight: 1,234,567" in out


def test_luck_na_before_hashrate_history():
    # Cold stack (#84 pitfall): no p2pool_1h / pool difficulty yet → n/a, never inf or "0s".
    out = tc.format_luck(_metrics())  # cadence fields at their 0.0 defaults
    assert "Since pool's last block: n/a" in out
    assert "Est. time to a share: n/a" in out
    assert "Luck: n/a" in out
    assert "Your PPLNS weight: 0" in out


def test_daily_summary_is_a_24h_retrospective():
    now = 1_000_000
    data = {
        "workers": [
            {"name": "miner-0", "status": "online", "h24h": 30000},
            {"name": "miner-1", "status": "online", "h24h": 20000},
            {"name": "old", "status": "offline", "h24h": 0},
        ],
        # 2 shares within 24h, 1 older.
        "shares": [{"ts": now - 100}, {"ts": now - 90000}, {"ts": now - 200}],
        "system": {"disk": {"percent_str": "42%"}},
        "network": {"reward": 600_000_000_000},
    }
    out = tc.format_daily_summary(
        _metrics(
            xvb_enabled=True,
            p2pool_24h=40000,
            xvb_routed_24h=10000,
            current_tier="Donor",
            workers_online=2,
            workers_total=3,
        ),
        data,
        now=now,
    )
    assert "Daily summary — " in out  # date+time stamped
    assert "24h hashrate: 50.00 kH/s" in out  # sum of per-rig h24h (30k + 20k)
    assert "20% to XvB" in out  # 10k / (40k + 10k)
    assert "P2Pool 40.00 kH/s" in out and "XvB 10.00 kH/s" in out  # apportioned, sums to fleet
    assert "XvB tier: Donor" in out
    assert "Shares (24h): 2" in out
    assert "Est. earnings" in out
    assert "miner-0: 30.00 kH/s" in out
    assert "old" not in out  # offline rig excluded
    assert "Disk: 42% used" in out
    # The retrospective drops live-status lines like node sync.
    assert "synced" not in out.lower()


def test_daily_summary_without_xvb_omits_split():
    data = {"workers": [{"name": "m", "status": "online", "h24h": 5000}], "shares": []}
    out = tc.format_daily_summary(_metrics(xvb_enabled=False), data, now=0)
    assert "24h hashrate: 5.00 kH/s" in out
    assert "to XvB" not in out


def test_daily_summary_incident_log():
    m, data = _metrics(xvb_enabled=False), {"workers": [], "shares": []}
    # Incidents present → a roll-up line, highest count first.
    out = tc.format_daily_summary(m, data, now=0, incidents={"worker_offline": 3, "node_down": 1})
    assert "Incidents (24h): 3× worker offline · 1× node down" in out
    # Empty tally → an explicit all-clear.
    assert "No incidents in the last 24h" in tc.format_daily_summary(m, data, now=0, incidents={})
    # Not tracked (None) → no incident line at all.
    none = tc.format_daily_summary(m, data, now=0, incidents=None)
    assert "Incidents" not in none and "No incidents" not in none


def test_host_label_prefix():
    assert tc.format_sync(_metrics(), host_label="rig-box").startswith("[rig-box] ")
    # The placeholder is never printed.
    assert not tc.format_sync(_metrics(), host_label="Unknown Host").startswith("[")


# --- reply_for routing --------------------------------------------------------------------


def _bot(monkeypatch, latest_data=None, db_healthy=True, **over):
    monkeypatch.setattr(tc, "build_metrics", lambda data, sm: _metrics(**over))
    sm = SimpleNamespace(is_db_healthy=lambda: db_healthy)
    ds = SimpleNamespace(latest_data=latest_data or {}, state_manager=sm)
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


def test_reply_for_status_merge_mining_from_tari_snapshot(monkeypatch):
    # gRPC linked = connected AND active (the #313 rule) → the "linked" line.
    bot = _bot(monkeypatch, latest_data={"tari": {"connected": True, "active": True}})
    assert "Merge-mining: 🟢 Tari linked" in bot.reply_for("/status")
    # Node up but gRPC not ready (the exact gap that hid #313) → "not linked".
    bot2 = _bot(monkeypatch, latest_data={"tari": {"connected": False, "active": True}})
    assert "Merge-mining: ⏸ Tari not linked" in bot2.reply_for("/status")


def test_reply_for_pool_reads_share_snapshot(monkeypatch):
    data = {"proxy_summary": {"accepted": 999, "rejected": 1, "best": 555}}
    bot = _bot(monkeypatch, latest_data=data, pool_type="Mini")
    out = bot.reply_for("/pool")
    assert "Best share: 💎 555" in out and "999 ✓ / 1 ✗" in out


def test_reply_for_luck(monkeypatch):
    bot = _bot(monkeypatch, expected_share_sec=3600.0, luck_pct=100.0, own_pplns_weight=42.0)
    out = bot.reply_for("/luck")
    assert "Luck: 100%" in out and "Your PPLNS weight: 42" in out


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


def test_reply_for_earnings(monkeypatch):
    bot = _bot(monkeypatch, latest_data={"network": {"reward": 600_000_000_000}}, p2pool_1h=8000.0)
    assert "XMR/day" in bot.reply_for("/earnings")


def test_reply_for_hashrate_and_sync(monkeypatch):
    workers = [{"name": "z", "status": "online", "h15": 1000}]
    bot = _bot(monkeypatch, latest_data={"workers": workers})
    assert "Hashrate" in bot.reply_for("/hashrate")
    assert "Sync status" in bot.reply_for("/sync")


def test_safe_reply_for_swallows_errors(monkeypatch):
    # A formatting/read bug in reply_for must never kill the poll loop — it just goes quiet.
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    bot = tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1")

    def boom(_text):
        raise RuntimeError("kaboom")

    monkeypatch.setattr(bot, "reply_for", boom)
    assert bot._safe_reply_for("/status") is None


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
    monkeypatch.setattr(bot, "_send", sent.append)  # _send is sync now (run via to_thread)
    # chat_id 999 != configured 42 → dropped, nothing sent.
    await bot._handle_update({"message": {"chat": {"id": 999}, "text": "/help"}})
    assert sent == []


async def test_handle_update_replies_to_configured_chat(monkeypatch):
    bot = _bot(monkeypatch)
    sent = []
    monkeypatch.setattr(bot, "_send", sent.append)
    await bot._handle_update({"message": {"chat": {"id": 42}, "text": "/help"}})
    assert len(sent) == 1 and "/status" in sent[0]


# --- transport (stubbed requests, over Tor) -----------------------------------------------


class _Resp:
    """Minimal stand-in for a requests.Response."""

    def __init__(self, payload=None, raise_status=False):
        self._payload = payload or {}
        self._raise = raise_status

    def raise_for_status(self):
        if self._raise:
            raise RuntimeError("http error")

    def json(self):
        return self._payload


def _make_bot(tor_proxy="socks5h://tor:9050"):
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    return tc.TelegramCommandBot(
        ds, enabled=True, bot_token="tok", chat_id="42", tor_proxy=tor_proxy
    )


def test_get_updates_parses_results_over_tor(monkeypatch):
    bot = _make_bot()
    bot._offset = 7
    seen = {}

    def fake_get(url, params=None, timeout=None, proxies=None):
        seen.update(url=url, params=params, proxies=proxies)
        return _Resp({"ok": True, "result": [{"update_id": 8}]})

    monkeypatch.setattr(tc.requests, "get", fake_get)
    assert bot._get_updates(0) == [{"update_id": 8}]
    assert "bottok" in seen["url"] and seen["params"]["offset"] == 7  # token + offset forwarded
    assert seen["proxies"] == {"http": "socks5h://tor:9050", "https": "socks5h://tor:9050"}


def test_get_updates_not_ok_returns_empty(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(tc.requests, "get", lambda *a, **k: _Resp({"ok": False}))
    assert bot._get_updates(0) == []


def test_prime_offset_skips_backlog(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(
        tc.requests,
        "get",
        lambda *a, **k: _Resp({"ok": True, "result": [{"update_id": 3}, {"update_id": 9}]}),
    )
    bot._prime_offset()
    assert bot._offset == 10  # past the last pending update


def test_prime_offset_swallows_error(monkeypatch):
    bot = _make_bot()

    def boom(*a, **k):
        raise OSError("offline")

    monkeypatch.setattr(tc.requests, "get", boom)
    bot._prime_offset()  # must not raise
    assert bot._offset is None


def test_send_posts_over_tor(monkeypatch):
    bot = _make_bot()
    seen = {}

    def fake_post(url, json=None, timeout=None, proxies=None):
        seen.update(url=url, body=json, proxies=proxies)
        return _Resp({"ok": True})

    monkeypatch.setattr(tc.requests, "post", fake_post)
    bot._send("hi")
    assert (
        "bottok" in seen["url"] and seen["body"]["chat_id"] == "42" and seen["body"]["text"] == "hi"
    )
    assert seen["proxies"]["https"] == "socks5h://tor:9050"


def test_send_swallows_network_error(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(tc.requests, "post", lambda *a, **k: _Resp(raise_status=True))
    bot._send("hi")  # must not raise


async def test_run_processes_update_then_honours_cancel(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(bot, "_prime_offset", lambda: None)
    handled = []

    async def _fake_handle(update):
        handled.append(update)

    calls = {"n": 0}

    def _fake_get(poll_timeout):
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
    monkeypatch.setattr(bot, "_prime_offset", lambda: None)
    slept = []

    async def _sleep(secs):
        slept.append(secs)
        raise asyncio.CancelledError  # break out after the first backoff

    def _boom(poll_timeout):
        raise OSError("telegram unreachable")

    monkeypatch.setattr(tc.asyncio, "sleep", _sleep)
    monkeypatch.setattr(bot, "_get_updates", _boom)
    with pytest.raises(asyncio.CancelledError):
        await bot.run()
    assert slept == [tc.POLL_ERROR_BACKOFF_SECONDS]


class TestStatusWarnings:
    """/status surfaces the same warning/error badges as the dashboard top bar (#104), reusing
    build_badges so the two never drift; informational states ('Syncing…') are excluded."""

    def test_bad_and_flagged_warn_badges_included_stripped(self):
        # Low RAM (⚠ warn) + DB failing (bad) both surface; the leading ⚠ is stripped for the list.
        warnings = tc.status_warnings(
            {"system": {"memory": {"total_gb": 8}}}, _metrics(), db_healthy=False
        )
        assert "Low RAM (8 GB)" in warnings
        assert "DB write failing" in warnings
        assert not any(w.startswith("⚠") for w in warnings)

    def test_informational_states_excluded(self):
        # 'Syncing…' / 'Miner held' are warn-variant but informational (no ⚠) — not warnings.
        warnings = tc.status_warnings(
            {"miner_held": True}, _metrics(global_syncing=True), db_healthy=True
        )
        assert warnings == []

    def test_healthy_is_empty(self):
        assert tc.status_warnings({}, _metrics(), db_healthy=True) == []

    def test_format_status_lists_warnings(self):
        text = tc.format_status(
            _metrics(), True, warnings=["Low RAM (8 GB)", "HugePages not reserved"]
        )
        assert "⚠️ Warnings:" in text
        assert "• Low RAM (8 GB)" in text
        assert "• HugePages not reserved" in text

    def test_format_status_all_clear(self):
        text = tc.format_status(_metrics(), True, warnings=[])
        assert "✅ No warnings." in text


class TestInfo:
    """/info — the 'about this stack' card: build version, update availability, Monero DB mode,
    P2Pool sidechain, and privacy (egress) posture. All facts the stack already computes."""

    def test_release_up_to_date_pruned_tor(self):
        out = tc.format_info(
            {"text": "v1.1.0", "dev": False},
            {"available": False},
            _metrics(monero_mode="Pruned", pool_type="Mini"),
            {"all_tor": True},
        )
        assert "Version: v1.1.0" in out and "(dev build)" not in out
        assert "✅ Up to date" in out
        assert "Monero DB: Pruned" in out
        assert "Sidechain: P2Pool Mini" in out
        assert "🧅 Tor-only" in out

    def test_dev_update_available_full_clearnet(self):
        out = tc.format_info(
            {"text": "dev · main @ abc1234", "dev": True},
            {"available": True, "latest": "v1.2.0"},
            _metrics(monero_mode="Full"),
            {"all_tor": False, "label": "2 clearnet egress path(s) exposing your IP"},
        )
        assert "(dev build)" in out
        assert "🆕 v1.2.0 available" in out
        assert "Monero DB: Full" in out
        assert "⚠️ 2 clearnet egress path(s)" in out

    def test_unknown_db_mode_and_missing_update(self):
        # monero_mode "Unknown" (remote/early) → no false Pruned/Full; update None → up to date.
        out = tc.format_info(
            {"text": "v1.1.0"}, None, _metrics(monero_mode="Unknown"), {"all_tor": True}
        )
        assert "Monero DB: unknown" in out
        assert "✅ Up to date" in out

    def test_reply_for_info_routes(self, monkeypatch):
        monkeypatch.setattr(tc, "resolve_version", lambda: {"text": "v1.1.0", "dev": False})
        monkeypatch.setattr(
            tc, "egress_posture_from_config", lambda: {"summary": {"all_tor": True}}
        )
        bot = _bot(monkeypatch, latest_data={"update": {"available": False}}, monero_mode="Pruned")
        out = bot.reply_for("/info")
        assert "📟 Pithead info" in out and "Version: v1.1.0" in out and "🧅 Tor-only" in out
