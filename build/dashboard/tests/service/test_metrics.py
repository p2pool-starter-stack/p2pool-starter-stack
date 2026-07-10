"""Unit tests for the typed metrics/domain layer (mining_dashboard/service/metrics.py).

This is where the dashboard's *computed* values live (Issue #61) — effective hashrate,
P2Pool/XvB averages, XvB tier qualification, shares-in-PPLNS-window, worker counts, per-node
sync/down state. The web view layer and future consumers (#45 Telegram, #12 calculator) all
read these, so the logic is covered thoroughly here rather than through rendered output.
"""

import time
from unittest.mock import MagicMock

import mining_dashboard.service.metrics as metrics
from mining_dashboard.config.config import TIER_DEFAULTS, XVB_STATS_STALE_AFTER_S
from mining_dashboard.service.metrics import (
    _avg_p2pool_over_window,
    _avg_xvb_over_window,
    build_metrics,
)


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
        "shares": [],
        "workers": [],
        "global_sync": False,
        "total_live_h15": 0,
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


class TestAvgXvbOverWindow:
    """Routed XvB averaging from v_xvb history — mirrors P2Pool so the two sum to total (#156)."""

    def test_empty_history_returns_zero(self):
        assert _avg_xvb_over_window([], 3600) == 0.0

    def test_averages_v_xvb_in_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 0, "v_xvb": 1000},
            {"timestamp": now - 60, "v": 500, "v_p2pool": 0, "v_xvb": 500},
        ]
        assert _avg_xvb_over_window(history, 3600) == 750.0

    def test_excludes_samples_outside_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 0, "v_xvb": 1000},
            {"timestamp": now - 7200, "v": 200, "v_p2pool": 0, "v_xvb": 200},
        ]
        assert _avg_xvb_over_window(history, 3600) == 1000.0

    def test_legacy_rows_read_xvb_zero(self):
        # Pre-split rows (v>0 but v_p2pool==v_xvb==0) count as P2Pool, so XvB-routed reads 0 there.
        now = time.time()
        history = [{"timestamp": now - 30, "v": 800, "v_p2pool": 0, "v_xvb": 0}]
        assert _avg_xvb_over_window(history, 3600) == 0.0

    def test_complements_p2pool_to_total(self):
        # Routed XvB + routed P2Pool average over the SAME samples, so they sum to the total avg.
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 60, "v": 1000, "v_p2pool": 0, "v_xvb": 1000},
        ]
        assert _avg_xvb_over_window(history, 3600) == 500.0
        assert _avg_p2pool_over_window(history, 3600) == 500.0  # 500 + 500 == 1000 total


class TestHashrate:
    def test_total_and_stratum_passthrough(self):
        data = _data(
            total_live_h15=12345,
            stratum={"hashrate_15m": 100, "hashrate_1h": 200, "hashrate_24h": 300},
        )
        m = build_metrics(data, _mgr())
        assert m.total_h15 == 12345
        assert (m.stratum_h15, m.stratum_h1h, m.stratum_h24h) == (100, 200, 300)

    def test_p2pool_averages_from_history(self):
        now = time.time()
        history = [{"timestamp": now - 30, "v": 900, "v_p2pool": 900, "v_xvb": 0}]
        m = build_metrics(_data(), _mgr(history=history))
        assert m.p2pool_1h == 900.0
        assert m.p2pool_24h == 900.0

    def test_xvb_credited_averages_from_stats(self):
        # Credited (XvB API avg_1h/24h) is kept independent — controller input + Advanced card (#156).
        m = build_metrics(_data(), _mgr(xvb={"avg_1h": 2100, "avg_24h": 2300}))
        assert m.xvb_1h == 2100
        assert m.xvb_24h == 2300

    def test_xvb_routed_averages_from_history(self):
        # Routed = what the proxy ACTUALLY sent to XvB (v_xvb), time-weighted from DB history — not
        # the controller's donation_fraction. Credited (avg_1h/24h) stays independent (#156).
        now = time.time()
        history = [{"timestamp": now - 30, "v": 1000, "v_p2pool": 600, "v_xvb": 400}]
        m = build_metrics(_data(), _mgr(history=history, xvb={"avg_1h": 30_000, "avg_24h": 30_000}))
        assert m.xvb_routed_1h == 400.0
        assert m.xvb_routed_24h == 400.0
        assert m.xvb_1h == 30_000  # credited, independent of routed

    def test_xvb_routed_zero_without_history(self):
        m = build_metrics(_data(total_live_h15=40_000), _mgr())
        assert m.xvb_routed_1h == 0.0
        assert m.xvb_routed_24h == 0.0


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

    def test_current_tier_from_min_1h_24h(self):
        # Current tier qualifies on the lower of the 1h/24h credited averages (#157) — set both.
        m = build_metrics(_data(), _mgr(xvb={"avg_1h": 50_000_000, "avg_24h": 50_000_000}))
        assert m.current_tier != "None"  # some tier qualifies at 50 MH/s on both windows
        assert isinstance(m.target_threshold, float)

    def test_current_tier_uses_lower_of_1h_24h_on_drop(self):
        # The raffle qualifies on BOTH 1h and 24h; on a hashrate drop the 1h falls first while the
        # laggy 24h still reads the old (now-lost) tier. Current Tier must follow the LOWER avg (#157).
        high = build_metrics(_data(), _mgr(xvb={"avg_1h": 50_000_000, "avg_24h": 50_000_000}))
        dropped = build_metrics(_data(), _mgr(xvb={"avg_1h": 50_000, "avg_24h": 50_000_000}))
        only_1h = build_metrics(_data(), _mgr(xvb={"avg_1h": 50_000, "avg_24h": 50_000}))
        assert dropped.current_tier != high.current_tier  # the 1h drop lowered the tier
        assert dropped.current_tier == only_1h.current_tier  # tier follows the LOWER (1h) average

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

    def test_registration_status_surfaced(self):
        # #263: registered_at + registration_state flow from XvB state to the metrics (badge driver).
        m = build_metrics(
            _data(), _mgr(xvb={"registered_at": 1700000500, "registration_state": "registered"})
        )
        assert m.xvb_registered_at == 1700000500
        assert m.xvb_registration_state == "registered"

    def test_registration_status_defaults(self):
        # Absent from state (older DBs / fresh start) => safe zero/empty defaults, no badge.
        m = build_metrics(_data(), _mgr(xvb={}))
        assert m.xvb_registered_at == 0
        assert m.xvb_registration_state == ""

    def test_xvb_stale_flag_tracks_fetch_age(self, monkeypatch):
        # #311: surface a stale fetch so the UI can grey the credited figures.
        monkeypatch.setattr(metrics, "ENABLE_XVB", True)
        fresh = build_metrics(_data(), _mgr(xvb={"last_update": time.time()}))
        assert fresh.xvb_stale is False
        stale = build_metrics(
            _data(), _mgr(xvb={"last_update": time.time() - XVB_STATS_STALE_AFTER_S - 60})
        )
        assert stale.xvb_stale is True

    def test_xvb_stale_never_set_when_disabled(self, monkeypatch):
        # XvB off => no donation logic, so an old timestamp must not raise a stale flag.
        monkeypatch.setattr(metrics, "ENABLE_XVB", False)
        m = build_metrics(
            _data(), _mgr(xvb={"last_update": time.time() - XVB_STATS_STALE_AFTER_S - 60})
        )
        assert m.xvb_stale is False

    def test_xvb_stale_false_on_cold_start(self, monkeypatch):
        # Never fetched (last_update absent) => cold start, not stale (the ramp regime).
        monkeypatch.setattr(metrics, "ENABLE_XVB", True)
        assert build_metrics(_data(), _mgr(xvb={})).xvb_stale is False


class TestWorkers:
    def test_counts_online_and_total(self):
        data = _data(
            workers=[
                {"name": "a", "status": "online"},
                {"name": "b", "status": "offline"},
                {"name": "c", "status": "online"},
            ]
        )
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
            pool={"pool": {"pplns_window": 10}},  # 10 blocks * 10s (Main) = 100s
            shares=[{"ts": now - 5}, {"ts": now - 50}, {"ts": now - 10_000}],
        )
        m = build_metrics(data, _mgr())
        assert m.shares_in_window == 2
        assert m.block_time == 10
        assert m.pplns_window == 10

    def test_nano_block_time(self):
        data = _data(pool={"p2p": {"type": "Nano"}, "pool": {"pplns_window": 5}})
        assert build_metrics(data, _mgr()).block_time == 30


class TestCadenceAndLuck:
    """#84: pool cadence & luck — expected time-to-share, luck %, own PPLNS weight, last block."""

    @staticmethod
    def _hist(rate):
        # Two fresh samples at a constant v_p2pool so p2pool_1h averages to exactly `rate`.
        now = time.time()
        return [
            {"timestamp": now - 30, "v": rate, "v_p2pool": rate, "v_xvb": 0},
            {"timestamp": now - 60, "v": rate, "v_p2pool": rate, "v_xvb": 0},
        ]

    def test_expected_share_sec_is_diff_over_hashrate(self):
        data = _data(pool={"pool": {"difficulty": 100_000}})
        m = build_metrics(data, _mgr(history=self._hist(1000)))
        assert m.expected_share_sec == 100.0  # 100_000 H·s / 1000 H/s

    def test_zero_hashrate_or_difficulty_reads_zero(self):
        # A fresh start (no history → p2pool_1h == 0) or an unknown pool difficulty must read 0.0
        # so the view layer hides luck/tts instead of showing inf/0s.
        no_hist = build_metrics(_data(pool={"pool": {"difficulty": 100_000}}), _mgr())
        no_diff = build_metrics(_data(), _mgr(history=self._hist(1000)))
        for m in (no_hist, no_diff):
            assert m.expected_share_sec == 0.0
            assert m.luck_pct == 0.0

    def test_zero_pplns_window_reads_zero_not_raise(self):
        # A partially-written stats file can carry sidechainDifficulty without pplnsWindowSize —
        # the collector then defaults pplns_window to 0. Luck must read the unavailable state
        # (0.0, hidden by the view layer), not divide by an expected_shares of 0 and 500 every
        # /api/state until the next poll.
        data = _data(pool={"pool": {"difficulty": 100_000, "pplns_window": 0}})
        m = build_metrics(data, _mgr(history=self._hist(1000)))
        assert m.luck_pct == 0.0
        assert m.expected_share_sec == 0.0

    def test_luck_at_exactly_expected_is_100(self):
        # expected = 1000 H/s * (2160 * 10 s) / 21_600_000 H·s = 1 share; 1 actual share => 100 %.
        now = time.time()
        data = _data(
            pool={"pool": {"difficulty": 21_600_000}},
            shares=[{"ts": now - 5, "difficulty": 50}],
        )
        m = build_metrics(data, _mgr(history=self._hist(1000)))
        assert m.luck_pct == 100.0

    def test_no_shares_is_luck_zero(self):
        data = _data(pool={"pool": {"difficulty": 21_600_000}})
        assert build_metrics(data, _mgr(history=self._hist(1000))).luck_pct == 0.0

    def test_own_weight_sums_share_difficulty_in_window(self):
        now = time.time()
        data = _data(
            pool={"pool": {"pplns_window": 10}},  # 10 blocks * 10 s = 100 s window
            shares=[
                {"ts": now - 5, "difficulty": 100.0},
                {"ts": now - 50, "difficulty": 200.0},
                {"ts": now - 10_000, "difficulty": 999.0},  # outside the window
            ],
        )
        assert build_metrics(data, _mgr()).own_pplns_weight == 300.0

    def test_last_block_ts_passthrough_and_default(self):
        assert (
            build_metrics(_data(pool={"pool": {"last_block_ts": 1700000000}}), _mgr()).last_block_ts
            == 1700000000
        )
        assert build_metrics(_data(), _mgr()).last_block_ts == 0


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
            pool={
                "p2p": {"type": "Mini"},
                "pool": {"hashrate": 120_000_000, "difficulty": 250_000_000},
            },
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

    def test_tari_earnings_inputs(self):
        # #117: the Tari aux-chain difficulty and XTM block reward come off the collected tari
        # snapshot (p2pool's merge-mine stats, already µT→XTM converted by the collector).
        m = build_metrics(
            _data(tari={"active": True, "difficulty": 420_000_000_000, "reward": 13_000.5}),
            _mgr(),
        )
        assert m.tari_difficulty == 420_000_000_000
        assert m.tari_reward == 13_000.5

    def test_tari_earnings_inputs_zero_when_absent(self):
        # Tari inactive / still syncing: no tari snapshot → safe zeros (the "unavailable" signal).
        m = build_metrics(_data(), _mgr())
        assert m.tari_difficulty == 0
        assert m.tari_reward == 0


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
        m = build_metrics(_data(), sm)  # no history arg -> pulled from state_mgr
        sm.get_history.assert_called_once()
        assert m.p2pool_1h == 500.0

    def test_passed_history_avoids_refetch(self):
        sm = _mgr()
        build_metrics(_data(), sm, history=[])  # explicit history -> no get_history call
        sm.get_history.assert_not_called()
