"""Unit tests for the dashboard presentation layer (mining_dashboard/web/views.py).

These exercise the context builders in isolation — no aiohttp app, no request — which is
the whole point of having pulled them out of the request handler (Issue #38).
"""
import time

import mining_dashboard.web.views as views
from mining_dashboard.web.views import (
    _get_chart_context, _get_pool_network_context, _get_worker_rows,
    _get_tari_context, _get_system_context, build_sync_context, build_header_badges,
)
from mining_dashboard.service.storage_service import StateManager


class TestChartContext:
    def _history(self, n, base_ts):
        return [{"timestamp": base_ts + i, "v": i, "v_p2pool": 0, "v_xvb": 0,
                 "t": "x"} for i in range(n)]

    def test_range_filtering(self):
        now = time.time()
        history = [{"timestamp": now - 7200, "v": 1, "v_p2pool": 0, "v_xvb": 0, "t": "x"},
                   {"timestamp": now - 60, "v": 2, "v_p2pool": 0, "v_xvb": 0, "t": "x"}]
        ctx_all = _get_chart_context(history, [], "all")
        ctx_1h = _get_chart_context(history, [], "1h")
        # both return a context dict; 1h filtering drops the 2h-old point from the payload
        assert isinstance(ctx_all, dict) and isinstance(ctx_1h, dict)
        assert ctx_1h["cls_1h"] == "active"

    def test_downsampling_caps_points(self):
        now = time.time()
        big = self._history(2000, now - 2000)
        ctx = _get_chart_context(big, [], "all")
        # Downsampled to <= 800 comma-separated points.
        assert isinstance(ctx, dict)
        assert len(ctx["chart_data"].split(",")) <= 800

    def test_shares_mapped_to_nearest_history_point(self):
        # Each share is bucketed onto the closest history sample; the marker count/radius/
        # offset arrays line up with the history points (covers the share-overlay branch).
        history = [
            {"timestamp": 1000, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},
            {"timestamp": 1060, "v": 600, "v_p2pool": 600, "v_xvb": 0, "t": "b"},
        ]
        shares = [{"ts": 1005}, {"ts": 1058}]
        ctx = _get_chart_context(history, shares, "all")
        assert ctx["chart_shares_c"] == "1,1"
        # y offset is lifted 10% above the line value (500 -> 550.0, 600 -> 660.0).
        assert ctx["chart_shares_y"] == "550.0,660.0"
        assert ctx["chart_shares_r"] == "9,9"

    def test_share_offset_floor_when_value_zero(self):
        # A share landing on a zero-hashrate sample is floored to y=100 so the marker stays
        # visible instead of sitting on the axis.
        history = [{"timestamp": 1000, "v": 0, "v_p2pool": 0, "v_xvb": 0, "t": "a"}]
        ctx = _get_chart_context(history, [{"ts": 1000}], "all")
        assert ctx["chart_shares_y"] == "100"
        assert ctx["chart_shares_c"] == "1"


class TestAvgP2poolOverWindow:
    def test_empty_history_returns_zero(self):
        assert views._avg_p2pool_over_window([], 3600) == 0.0

    def test_averages_v_p2pool_in_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 60, "v": 500, "v_p2pool": 500, "v_xvb": 0},
        ]
        assert views._avg_p2pool_over_window(history, 3600) == 750.0

    def test_excludes_samples_outside_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 7200, "v": 200, "v_p2pool": 200, "v_xvb": 0},
        ]
        assert views._avg_p2pool_over_window(history, 3600) == 1000.0

    def test_legacy_rows_count_as_p2pool(self):
        now = time.time()
        history = [{"timestamp": now - 30, "v": 800, "v_p2pool": 0, "v_xvb": 0}]
        assert views._avg_p2pool_over_window(history, 3600) == 800.0

    def test_xvb_samples_drag_average_down(self):
        # Time spent donating to XvB reduces the P2Pool average (v_p2pool == 0 then).
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 60, "v": 1000, "v_p2pool": 0, "v_xvb": 1000},
        ]
        assert views._avg_p2pool_over_window(history, 3600) == 500.0


class TestAlgoContextColors:
    MUTED = "#8b949e"

    def _ctx(self, mode):
        sm = StateManager(db_path=":memory:")
        sm.update_xvb_stats(mode=mode)
        try:
            return views._get_algo_context({"total_live_h15": 100000}, sm, [])
        finally:
            sm.close()

    def test_p2pool_mode_grays_xvb(self):
        ctx = self._ctx("P2POOL")
        assert ctx["xvb_color"] == self.MUTED
        assert ctx["p2p_color"] != self.MUTED

    def test_xvb_mode_grays_p2pool(self):
        ctx = self._ctx("XVB")
        assert ctx["p2p_color"] == self.MUTED
        assert ctx["xvb_color"] != self.MUTED

    def test_split_mode_both_active(self):
        ctx = self._ctx("XVB (Split)")
        assert ctx["p2p_color"] != self.MUTED
        assert ctx["xvb_color"] != self.MUTED

    def test_xvb_disabled_grays_xvb(self, monkeypatch):
        monkeypatch.setattr(views, "ENABLE_XVB", False)
        ctx = self._ctx("XVB")
        assert ctx["xvb_color"] == self.MUTED
        assert "Disabled" in ctx["mode_name"]
        assert ctx["tier_name"] == "Disabled"


class TestLowHashrateWarning:
    def _ctx(self, monkeypatch, level, total_hr):
        monkeypatch.setattr(views, "XVB_DONATION_LEVEL", level)
        sm = StateManager(db_path=":memory:")
        sm.update_xvb_stats(mode="P2POOL")
        try:
            return views._get_algo_context({"total_live_h15": total_hr}, sm, [])
        finally:
            sm.close()

    def test_warns_when_selected_tier_unsustainable(self, monkeypatch):
        # 50k can't sustain Mega (1M) -> warning badge.
        ctx = self._ctx(monkeypatch, "mega", 50_000)
        assert ctx["low_hr_badge"]

    def test_no_warning_for_auto(self, monkeypatch):
        # auto only ever targets a sustainable tier -> no warning.
        ctx = self._ctx(monkeypatch, "auto", 50_000)
        assert ctx["low_hr_badge"] == ""

    def test_no_warning_when_sustainable(self, monkeypatch):
        # 50k easily sustains Donor (1k) -> no warning.
        ctx = self._ctx(monkeypatch, "donor", 50_000)
        assert ctx["low_hr_badge"] == ""


class TestMoneroMode:
    """Pruned/Full label + DB size in the Monero panel (Issue #32)."""

    def _ctx(self, db_size=0):
        return _get_pool_network_context({"monero_sync": {"db_size": db_size}})

    def test_local_pruned(self, monkeypatch):
        monkeypatch.setattr(views, "MONERO_NODE_HOST", "172.28.0.26")
        monkeypatch.setattr(views, "MONERO_PRUNE", True)
        ctx = self._ctx(db_size=85_000_000_000)
        assert ctx["monero_mode"] == "Pruned"
        assert ctx["monero_db_size"] == "85.0 GB"
        assert "XMR Pruned" in ctx["monero_prune_badge"]

    def test_local_full(self, monkeypatch):
        monkeypatch.setattr(views, "MONERO_NODE_HOST", "172.28.0.26")
        monkeypatch.setattr(views, "MONERO_PRUNE", False)
        ctx = self._ctx()
        assert ctx["monero_mode"] == "Full"
        assert "XMR Full" in ctx["monero_prune_badge"]

    def test_remote_unknown(self, monkeypatch):
        # A remote node's pruning state isn't something we probe — no badge.
        monkeypatch.setattr(views, "MONERO_NODE_HOST", "10.0.0.9")
        monkeypatch.setattr(views, "MONERO_PRUNE", True)
        ctx = self._ctx()
        assert ctx["monero_mode"] == "Unknown"
        assert ctx["monero_prune_badge"] == ""

    def test_db_size_dash_when_unknown(self, monkeypatch):
        monkeypatch.setattr(views, "MONERO_NODE_HOST", "172.28.0.26")
        monkeypatch.setattr(views, "MONERO_PRUNE", True)
        assert self._ctx(db_size=0)["monero_db_size"] == "—"


class TestWorkerRows:
    """HTML table rows for the worker list (badges, sorting, escaping)."""

    def test_online_p2pool_worker_rendered(self):
        rows = _get_worker_rows([
            {"name": "rig1", "ip": "10.0.0.1", "status": "online",
             "active_pool": "3333", "uptime": 60, "h10": 1000, "h60": 1000, "h15": 1000},
        ])
        assert "rig1" in rows
        assert "status-ok" in rows
        assert ">P2Pool<" in rows  # P2Pool badge for a 3333 (p2pool) port

    def test_offline_worker_marked_bad(self):
        rows = _get_worker_rows([
            {"name": "rig2", "ip": "10.0.0.2", "status": "offline",
             "active_pool": "3333"},
        ])
        assert "status-bad" in rows

    def test_xvb_badge_for_xvb_port(self):
        rows = _get_worker_rows([
            {"name": "rig3", "ip": "10.0.0.3", "status": "online", "active_pool": "3344"},
        ])
        assert ">XvB<" in rows

    def test_unknown_badge_when_no_active_pool(self):
        rows = _get_worker_rows([
            {"name": "rig4", "ip": "10.0.0.4", "status": "online", "active_pool": ""},
        ])
        assert ">Unknown<" in rows

    def test_worker_name_is_html_escaped(self):
        rows = _get_worker_rows([
            {"name": "<script>", "ip": "10.0.0.5", "status": "online", "active_pool": "3333"},
        ])
        assert "<script>" not in rows
        assert "&lt;script&gt;" in rows

    def test_online_sorted_before_offline(self):
        rows = _get_worker_rows([
            {"name": "zzz", "ip": "10.0.0.9", "status": "offline", "active_pool": "3333"},
            {"name": "aaa", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"},
        ])
        assert rows.index("aaa") < rows.index("zzz")  # online (aaa) comes first

    def test_malformed_worker_is_skipped(self):
        # A worker missing 'ip' raises inside the row build and is skipped (the good one
        # still renders) rather than blowing up the whole table.
        rows = _get_worker_rows([
            {"name": "good", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"},
            {"name": "skipme", "status": "online", "active_pool": "3333"},  # no 'ip'
        ])
        assert 'data-sort="good"' in rows
        assert "skipme" not in rows

    def test_bad_ip_sorts_to_zero(self):
        # A non-numeric IP can't be packed into a sort int -> falls back to 0, still renders.
        rows = _get_worker_rows([
            {"name": "rig", "ip": "not-an-ip", "status": "online", "active_pool": "3333"},
        ])
        assert 'data-sort="0"' in rows


class TestTariContext:
    def test_active_tari_shows_checkmark(self):
        ctx = _get_tari_context({"tari": {
            "active": True, "status": "Mining", "reward": 12.5, "height": 42,
            "difficulty": 1234567, "address": "addr",
        }})
        assert "✔" in ctx["tari_status"]
        assert ctx["tari_status_class"] == "status-ok"
        assert ctx["tari_reward"] == "12.50 TARI"
        assert ctx["tari_height"] == "42"
        assert ctx["tari_diff"] == "1,234,567"  # thousands separators

    def test_inactive_tari_waiting(self):
        ctx = _get_tari_context({"tari": {"active": False}})
        assert ctx["tari_status"] == "Waiting..."
        assert ctx["tari_status_class"] == ""

    def test_long_wallet_is_shortened(self):
        addr = "T" * 40
        ctx = _get_tari_context({"tari": {"active": True, "address": addr}})
        assert ctx["tari_wallet"] == addr            # full kept
        assert "..." in ctx["tari_wallet_short"]      # short elided
        assert len(ctx["tari_wallet_short"]) < len(addr)

    def test_missing_tari_block_uses_defaults(self):
        ctx = _get_tari_context({})
        assert ctx["tari_status"] == "Waiting..."
        assert ctx["tari_wallet"] == "Unknown"


class TestSystemContext:
    def test_high_usage_flags_badges(self):
        ctx = _get_system_context({"system": {
            "disk": {"percent": 95, "used_gb": 90, "total_gb": 100, "percent_str": "95%"},
            "memory": {"percent": 85, "used_gb": 13, "total_gb": 16, "percent_str": "85%"},
            "cpu_percent": "90.0%",
            "load": "0.5 0.4 0.3",
            "hugepages": ["Enabled", "status-ok", "1555/3072"],
        }})
        assert ctx["disk_fill_class"] == "critical"   # > 90
        assert ctx["disk_class"] == "status-bad"
        assert "High Usage" in ctx["disk_badge"]
        assert "High Usage" in ctx["mem_badge"]
        assert "High Usage" in ctx["cpu_badge"]
        assert ctx["cpu_load"] == "1m: 0.5 5m: 0.4 15m: 0.3"
        assert ctx["hp_status"] == "Enabled"

    def test_warning_fill_between_70_and_90(self):
        ctx = _get_system_context({"system": {"disk": {"percent": 75}}})
        assert ctx["disk_fill_class"] == "warning"

    def test_unparseable_cpu_defaults_to_zero(self):
        # A non-numeric cpu string must not raise; it degrades to 0% (no High-Usage badge).
        ctx = _get_system_context({"system": {"cpu_percent": "n/a"}})
        assert ctx["cpu_badge"] == ""
        assert ctx["cpu_label_class"] == "text-muted"

    def test_empty_system_uses_hugepages_default(self):
        ctx = _get_system_context({})
        assert ctx["hp_status"] == "Disabled"
        assert ctx["hp_val"] == "0/0"


class TestSyncContext:
    def test_loading_when_no_target(self):
        ctx = build_sync_context({"percent": 0, "target": 0}, {"percent": 0, "target": 0}, False)
        assert ctx["sync_percent"] == "…"
        assert ctx["tari_sync_percent"] == "…"
        assert ctx["sync_class"] == ""
        assert ctx["page_title"] == "Mining Dashboard"

    def test_checkmark_at_full_sync(self):
        ctx = build_sync_context({"percent": 100, "target": 10, "current": 10},
                                 {"percent": 100, "target": 5, "current": 5}, False)
        assert "✔" in ctx["sync_percent"]
        assert "✔" in ctx["tari_sync_percent"]

    def test_percent_and_remaining_mid_sync(self):
        ctx = build_sync_context({"percent": 42, "target": 100, "current": 42},
                                 {"percent": 10, "target": 100, "current": 10}, True)
        assert ctx["sync_percent"] == "42%"
        assert ctx["sync_remaining"] == 58
        assert ctx["sync_class"] == "mode-sync"
        assert ctx["page_title"] == "Mining Dashboard - Syncing"


class TestHeaderBadges:
    def _algo(self, **over):
        base = {"mode_color": "#238636", "mode_name": "P2POOL", "low_hr_badge": ""}
        base.update(over)
        return base

    def test_syncing_shows_syncing_badge_only(self):
        out = build_header_badges({}, True, self._algo(), {"p2p_type": "Main"})
        assert "Syncing..." in out
        assert "P2POOL" not in out  # mode badge suppressed during sync

    def test_operational_shows_mode_and_pool_type(self):
        out = build_header_badges({}, False, self._algo(), {"p2p_type": "Mini"})
        assert "P2POOL" in out
        assert "P2Pool Mini" in out

    def test_low_hashrate_badge_appended(self):
        out = build_header_badges({}, False, self._algo(low_hr_badge="<b>LOW</b>"),
                                  {"p2p_type": "Main"})
        assert "<b>LOW</b>" in out

    def test_node_down_and_rejected_badges(self):
        data = {
            "monero_sync": {"down": True}, "tari_sync": {"down": True},
            "workers_rejected": True,
        }
        out = build_header_badges(data, False, self._algo(), {"p2p_type": "Main"})
        assert "monerod DOWN" in out
        assert "Tari DOWN" in out
        assert "Workers rejected" in out

    def test_miner_held_badge(self):
        out = build_header_badges({"miner_held": True}, True, self._algo(), {})
        assert "Miner held (sync)" in out

    def test_passive_tari_badge_with_and_without_percent(self):
        with_pct = build_header_badges(
            {"tari_syncing_passive": True, "tari_sync": {"percent": 42}},
            False, self._algo(), {"p2p_type": "Main"})
        assert "Tari syncing 42%" in with_pct

        no_pct = build_header_badges(
            {"tari_syncing_passive": True, "tari_sync": {"percent": 0}},
            False, self._algo(), {"p2p_type": "Main"})
        assert "Tari syncing<" in no_pct  # bare label, no percentage
