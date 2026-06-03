"""Unit tests for the typed metrics/domain layer (mining_dashboard/service/metrics.py).

This is where the dashboard's *computed* values live (Issue #61) — effective hashrate,
P2Pool/XvB averages, XvB tier qualification, shares-in-PPLNS-window, worker counts, per-node
sync/down state. The web view layer and future consumers (#45 Telegram, #12 calculator) all
read these, so the logic is covered thoroughly here rather than through rendered output.
"""
import time

from unittest.mock import MagicMock

import mining_dashboard.service.metrics as metrics
from mining_dashboard.service.metrics import build_metrics, _avg_p2pool_over_window
from mining_dashboard.config.config import TIER_DEFAULTS


def _mgr(history=None, mode="P2POOL", xvb=None, tiers=None):
    # Mirror the real StateManager: get_tiers() returns the configured tiers (TIER_DEFAULTS).
    sm = MagicMock()
    sm.get_history.return_value = history if history is not None else []
    stats = {"current_mode": mode}
    if xvb:
        stats.update(xvb)
    sm.get_xvb_stats.return_value = stats
    sm.get_tiers.return_value = TIER_DEFAULTS if tiers is None else tiers
    return sm


def _data(**over):
    d = {
        "shares": [], "workers": [], "global_sync": False, "total_live_h15": 0,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
    }
    d.update(over)
    return d


class TestAvgP2poolOverWindow:
    def test_empty_history_returns_zero(self):
        assert _avg_p2pool_over_window([], 3600) == 0.0

    def test_averages_v_p2pool_in_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 60, "v": 500, "v_p2pool": 500, "v_xvb": 0},
        ]
        assert _avg_p2pool_over_window(history, 3600) == 750.0

    def test_excludes_samples_outside_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 7200, "v": 200, "v_p2pool": 200, "v_xvb": 0},
        ]
        assert _avg_p2pool_over_window(history, 3600) == 1000.0

    def test_legacy_rows_count_as_p2pool(self):
        now = time.time()
        history = [{"timestamp": now - 30, "v": 800, "v_p2pool": 0, "v_xvb": 0}]
        assert _avg_p2pool_over_window(history, 3600) == 800.0

    def test_xvb_samples_drag_average_down(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 60, "v": 1000, "v_p2pool": 0, "v_xvb": 1000},
        ]
        assert _avg_p2pool_over_window(history, 3600) == 500.0


class TestHashrate:
    def test_total_and_stratum_passthrough(self):
        data = _data(total_live_h15=12345,
                     stratum={"hashrate_15m": 100, "hashrate_1h": 200, "hashrate_24h": 300})
        m = build_metrics(data, _mgr())
        assert m.total_h15 == 12345
        assert (m.stratum_h15, m.stratum_h1h, m.stratum_h24h) == (100, 200, 300)

    def test_p2pool_averages_from_history(self):
        now = time.time()
        history = [{"timestamp": now - 30, "v": 900, "v_p2pool": 900, "v_xvb": 0}]
        m = build_metrics(_data(), _mgr(history=history))
        assert m.p2pool_1h == 900.0
        assert m.p2pool_24h == 900.0

    def test_xvb_averages_from_stats(self):
        m = build_metrics(_data(), _mgr(xvb={"avg_1h": 2100, "avg_24h": 2300}))
        assert m.xvb_1h == 2100
        assert m.xvb_24h == 2300

    def test_xvb_routed_is_fraction_of_hashrate(self):
        # Routed = controller's donation fraction * our hashrate (what we send),
        # distinct from the credited averages XvB reports.
        m = build_metrics(_data(total_live_h15=40_000),
                          _mgr(xvb={"avg_1h": 30_000, "donation_fraction": 0.25}))
        assert m.xvb_routed == 10_000  # 0.25 * 40k
        assert m.xvb_1h == 30_000      # credited stays independent

    def test_xvb_routed_zero_without_fraction(self):
        m = build_metrics(_data(total_live_h15=40_000), _mgr())
        assert m.xvb_routed == 0


class TestModeAndTiers:
    def test_mode_default(self):
        assert build_metrics(_data(), _mgr(mode="XVB (Split)")).mode == "XVB (Split)"

    def test_xvb_disabled_overrides_mode_and_tiers(self, monkeypatch):
        monkeypatch.setattr(metrics, "ENABLE_XVB", False)
        m = build_metrics(_data(total_live_h15=100000), _mgr(mode="XVB"))
        assert m.mode == "P2POOL (XvB Disabled)"
        assert m.xvb_enabled is False
        assert m.current_tier == "Disabled"
        assert m.target_tier == "Disabled"
        assert m.low_hr_warning is False

    def test_current_tier_from_xvb_24h(self):
        # 24h XvB average qualifies the *current* tier.
        m = build_metrics(_data(), _mgr(xvb={"avg_24h": 50_000_000}))
        assert m.current_tier != "None"   # some tier qualifies at 50 MH/s
        assert isinstance(m.target_threshold, float)

    def test_low_hr_warning_for_unsustainable_explicit_tier(self, monkeypatch):
        monkeypatch.setattr(metrics, "ENABLE_XVB", True)
        monkeypatch.setattr(metrics, "XVB_DONATION_LEVEL", "mega")
        m = build_metrics(_data(total_live_h15=50_000), _mgr())
        assert m.low_hr_warning is True
        assert m.target_sustainable is False

    def test_no_warning_for_auto(self, monkeypatch):
        monkeypatch.setattr(metrics, "ENABLE_XVB", True)
        monkeypatch.setattr(metrics, "XVB_DONATION_LEVEL", "auto")
        assert build_metrics(_data(total_live_h15=50_000), _mgr()).low_hr_warning is False

    def test_no_warning_when_sustainable(self, monkeypatch):
        monkeypatch.setattr(metrics, "ENABLE_XVB", True)
        monkeypatch.setattr(metrics, "XVB_DONATION_LEVEL", "donor")
        assert build_metrics(_data(total_live_h15=50_000), _mgr()).low_hr_warning is False

    def test_fail_count_and_last_update(self):
        m = build_metrics(_data(), _mgr(xvb={"fail_count": 4, "last_update": 1700000000}))
        assert m.xvb_fail_count == 4
        assert m.xvb_last_update == 1700000000


class TestWorkers:
    def test_counts_online_and_total(self):
        data = _data(workers=[
            {"name": "a", "status": "online"},
            {"name": "b", "status": "offline"},
            {"name": "c", "status": "online"},
        ])
        m = build_metrics(data, _mgr())
        assert m.workers_online == 2
        assert m.workers_total == 3

    def test_empty(self):
        m = build_metrics(_data(workers=[]), _mgr())
        assert m.workers_online == 0 and m.workers_total == 0


class TestSharesWindow:
    def test_counts_recent_within_pplns_window(self):
        now = time.time()
        data = _data(
            pool={"pool": {"pplns_window": 10}},          # 10 blocks * 10s (Main) = 100s
            shares=[{"ts": now - 5}, {"ts": now - 50}, {"ts": now - 10_000}],
        )
        m = build_metrics(data, _mgr())
        assert m.shares_in_window == 2
        assert m.block_time == 10
        assert m.pplns_window == 10

    def test_nano_block_time(self):
        data = _data(pool={"p2p": {"type": "Nano"}, "pool": {"pplns_window": 5}})
        assert build_metrics(data, _mgr()).block_time == 30


class TestSyncMetrics:
    def test_loading_when_no_target(self):
        m = build_metrics(_data(monero_sync={"percent": 0, "target": 0}), _mgr())
        assert m.monero.has_target is False
        assert m.monero.done is False

    def test_done_when_full(self):
        m = build_metrics(_data(monero_sync={"percent": 100, "current": 10, "target": 10}), _mgr())
        assert m.monero.done is True
        assert m.monero.remaining == 0

    def test_mid_sync_remaining(self):
        m = build_metrics(_data(tari_sync={"percent": 40, "current": 40, "target": 100}), _mgr())
        assert m.tari.has_target is True
        assert m.tari.done is False
        assert m.tari.remaining == 60

    def test_down_flag(self):
        m = build_metrics(_data(monero_sync={"percent": 0, "target": 0, "down": True}), _mgr())
        assert m.monero.down is True

    def test_global_syncing(self):
        assert build_metrics(_data(global_sync=True), _mgr()).global_syncing is True


class TestMoneroMode:
    def test_local_pruned(self, monkeypatch):
        monkeypatch.setattr(metrics, "MONERO_NODE_HOST", "172.28.0.26")
        monkeypatch.setattr(metrics, "MONERO_PRUNE", True)
        assert build_metrics(_data(), _mgr()).monero_mode == "Pruned"

    def test_local_full(self, monkeypatch):
        monkeypatch.setattr(metrics, "MONERO_NODE_HOST", "172.28.0.26")
        monkeypatch.setattr(metrics, "MONERO_PRUNE", False)
        assert build_metrics(_data(), _mgr()).monero_mode == "Full"

    def test_remote_unknown(self, monkeypatch):
        monkeypatch.setattr(metrics, "MONERO_NODE_HOST", "10.0.0.9")
        assert build_metrics(_data(), _mgr()).monero_mode == "Unknown"


class TestCalculatorInputs:
    def test_pool_and_network_figures(self):
        data = _data(
            pool={"p2p": {"type": "Mini"},
                  "pool": {"hashrate": 120_000_000, "difficulty": 250_000_000}},
            network={"difficulty": 380_000_000_000, "height": 3210001},
        )
        m = build_metrics(data, _mgr())
        assert m.pool_type == "Mini"
        assert m.pool_hashrate == 120_000_000
        assert m.pool_difficulty == 250_000_000
        assert m.network_difficulty == 380_000_000_000
        assert m.network_height == 3210001

    def test_tari_mining_flag(self):
        assert build_metrics(_data(tari={"active": True}), _mgr()).tari_mining is True
        assert build_metrics(_data(tari={"active": False}), _mgr()).tari_mining is False


class TestRobustness:
    def test_empty_snapshot_does_not_crash(self):
        # A bare/partial snapshot (early startup) must still produce a Metrics with safe zeros.
        m = build_metrics({}, _mgr())
        assert m.total_h15 == 0
        assert m.workers_total == 0
        assert m.shares_in_window == 0
        assert m.monero.has_target is False

    def test_history_fetched_when_not_passed(self):
        now = time.time()
        sm = _mgr(history=[{"timestamp": now - 10, "v": 500, "v_p2pool": 500, "v_xvb": 0}])
        m = build_metrics(_data(), sm)   # no history arg -> pulled from state_mgr
        sm.get_history.assert_called_once()
        assert m.p2pool_1h == 500.0

    def test_passed_history_avoids_refetch(self):
        sm = _mgr()
        build_metrics(_data(), sm, history=[])   # explicit history -> no get_history call
        sm.get_history.assert_not_called()
