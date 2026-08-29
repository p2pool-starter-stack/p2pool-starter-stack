"""Unit tests for the time-series sections (mining_dashboard/web/series_views.py).

Moved out of tests/web/test_views.py with the sections themselves (#1105). The test bodies are
verbatim; the only edits are the twelve module-alias reads that follow their target from ``views``
to ``series_views``.

The shared builders — ``_SYNC_DONE``/``_BASE`` and the ``_metrics``, ``_sync``, ``_hashrate``,
``_state_mgr`` and ``_data`` factories — are pytest fixtures in ``tests/web/conftest.py`` as of
#1459. Each test that needs one takes it as a parameter; the call itself reads as it always did.
What is deliberately NOT shared, and why, is written in that file.
"""

import time
from unittest.mock import MagicMock

from mining_dashboard.web import series_views
from mining_dashboard.web.charts import _MAX_CHART_POINTS
from mining_dashboard.web.series_views import (
    _window_reject_pct,
    build_blocks,
    build_cadence,
    build_disk_growth,
    build_share_stats,
    build_xvb_history,
)
from mining_dashboard.web.views import build_state

# --- Hashrate / mode / tier formatting ------------------------------------------------


class TestHashrate:
    def test_formats_hashrates(self, _hashrate, _metrics):
        hr = _hashrate(_metrics(total_h15=10500, p2pool_1h=8000, xvb_1h=2100))
        assert hr["total"] == "10.50 kH/s"
        assert hr["p2p_1h"] == "8.00 kH/s"
        assert hr["xvb_1h"] == "2.10 kH/s"

    def test_routed_distinct_from_credited(self, _hashrate, _metrics):
        # Routed (proxy v_xvb) is shown in the header/Simple and alongside credited in the Advanced
        # card so the live credit factor is visible — distinct from credited avg_1h/24h (#156).
        hr = _hashrate(_metrics(xvb_routed_1h=2000, xvb_24h=6500, xvb_1h=6000))
        assert hr["xvb_routed_1h"] == "2.00 kH/s"
        assert hr["xvb_1h"] == "6.00 kH/s"

    def test_p2pool_mode_grays_xvb(self, _hashrate, _metrics):
        hr = _hashrate(_metrics(mode="P2POOL"))
        assert hr["mode_variant"] == "ok"
        assert hr["p2p_variant"] == "ok"
        assert hr["xvb_variant"] == "muted"

    def test_xvb_mode_grays_p2pool(self, _hashrate, _metrics):
        hr = _hashrate(_metrics(mode="XVB"))
        assert hr["mode_variant"] == "purple"
        assert hr["p2p_variant"] == "muted"
        assert hr["xvb_variant"] == "purple"

    def test_split_mode_both_active(self, _hashrate, _metrics):
        hr = _hashrate(_metrics(mode="XVB (Split)"))
        assert hr["mode_variant"] == "accent"
        assert hr["p2p_variant"] == "ok"
        assert hr["xvb_variant"] == "purple"

    def test_low_hr_badge_present_only_when_warned(self, _hashrate, _metrics):
        assert _hashrate(_metrics(low_hr_warning=False))["low_hr"] is None
        warned = _hashrate(_metrics(low_hr_warning=True))["low_hr"]
        assert warned and "low for tier" in warned["text"] and warned["title"]

    def test_tiers_and_fail_count_passthrough(self, _hashrate, _metrics):
        hr = _hashrate(_metrics(current_tier="Vip (X)", target_tier="Whale (Y)", xvb_fail_count=3))
        assert hr["tier"] == "Vip (X)"
        assert hr["target_tier"] == "Whale (Y)"
        assert hr["xvb_fail_count"] == 3


class TestShareStatsSeries:
    """#116: the persisted per-poll share-health deltas surfaced in /api/state."""

    def _rows(self, now):
        return [
            {"ts": now - 3 * 24 * 3600, "accepted": 50, "rejected": 9, "invalid": 0, "expired": 0},
            {"ts": now - 3600, "accepted": 90, "rejected": 10, "invalid": 1, "expired": 2},
            {"ts": now - 60, "accepted": 10, "rejected": 0, "invalid": 0, "expired": 0},
        ]

    def test_points_shape_and_ms_epoch(self):
        now = time.time()
        pts = build_share_stats(self._rows(now), "all")
        assert len(pts) == 3
        assert pts[1] == {"x": int((now - 3600) * 1000), "a": 90, "r": 10, "i": 1, "e": 2}

    def test_range_filters_old_rows(self):
        # The 24h preset drops the 3-day-old row, same bounds as the chart's event filter.
        assert len(build_share_stats(self._rows(time.time()), "24h")) == 2

    def test_unknown_range_keeps_everything(self):
        assert len(build_share_stats(self._rows(time.time()), "bogus")) == 3

    def test_custom_window_bounds_both_ends(self):
        now = time.time()
        pts = build_share_stats(self._rows(now), "all", window=(now - 7200, now - 600))
        assert len(pts) == 1 and pts[0]["a"] == 90

    def test_window_reject_pct(self):
        now = time.time()
        # Trailing 24h: 100 accepted + 10 rejected -> 9.09%; the 3-day-old row is excluded.
        assert _window_reject_pct(self._rows(now), 24 * 3600) == "9.09%"

    def test_window_reject_pct_dash_when_no_shares(self):
        # Zero submitted shares in the window must read "—", not a falsely-healthy 0%.
        assert _window_reject_pct([], 24 * 3600) == "—"
        idle = [{"ts": time.time(), "accepted": 0, "rejected": 0, "invalid": 3, "expired": 0}]
        assert _window_reject_pct(idle, 24 * 3600) == "—"

    def test_long_series_is_bounded_and_bucket_summed(self):
        # 30 days of 30s polls ≈ 86k rows; /api/state must ship at most _MAX_CHART_POINTS,
        # like the hashrate chart. The deltas are additive, so bucket-summing keeps the
        # series' totals exact through the thinning.
        now = time.time()
        rows = [
            {"ts": now - i * 30, "accepted": 2, "rejected": 1, "invalid": 0, "expired": 0}
            for i in range(86_400, 0, -1)  # ascending ts, like the DB returns them
        ]
        pts = build_share_stats(rows, "all")
        assert len(pts) <= _MAX_CHART_POINTS
        assert sum(p["a"] for p in pts) == 2 * 86_400
        assert sum(p["r"] for p in pts) == 86_400
        # Timestamps stay ordered ms-epoch positions from within the data.
        xs = [p["x"] for p in pts]
        assert xs == sorted(xs)

    def test_reject_pct_24h_stays_exact_on_long_series(self):
        # The trailing 24h reject rate is computed from the RAW rows, never the thinned
        # series — thinning the chart must not move the number.
        now = time.time()
        rows = [
            {"ts": now - i * 30, "accepted": 9, "rejected": 1, "invalid": 0, "expired": 0}
            for i in range(86_400)
        ]
        assert _window_reject_pct(rows, 24 * 3600) == "10.00%"

    def test_short_series_is_untouched(self):
        pts = build_share_stats(self._rows(time.time()), "all")
        assert len(pts) == 3  # under the cap -> native resolution, no bucketing


class TestBlocksDiskGrowthXvbHistorySeries:
    """#196 Tier-1: the persisted blocks/disk_growth/xvb_history backbone surfaced on
    /api/state. network_history and worker_history are Tier-2 and out of scope here."""

    def test_build_blocks_shape_and_ms_epoch(self):
        now = time.time()
        rows = [{"ts": now - 60, "height": 42, "difficulty": 123.0}]
        pts = build_blocks(rows, "all")
        assert pts == [{"x": int((now - 60) * 1000), "height": 42, "difficulty": 123.0}]

    def test_build_blocks_range_filters_old_rows(self):
        now = time.time()
        rows = [
            {"ts": now - 8 * 24 * 3600, "height": 1, "difficulty": 1.0},
            {"ts": now - 60, "height": 2, "difficulty": 2.0},
        ]
        assert len(build_blocks(rows, "1w")) == 1

    def test_build_blocks_empty(self):
        assert build_blocks([], "all") == []

    def _payout_mgr(self, rows_by_chain):
        mgr = MagicMock()
        mgr.get_payouts.side_effect = lambda chain: rows_by_chain.get(chain, [])
        return mgr

    def test_build_payouts_shape_ms_epoch_and_atomic_amount(self, monkeypatch):
        monkeypatch.setattr(series_views.config, "PAYOUT_CONFIRM_ENABLED", True)
        monkeypatch.setattr(series_views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
        now = time.time()
        mgr = self._payout_mgr(
            {
                "monero": [{"ts": now - 60, "amount_atomic": 12_345}],
                "tari": [{"ts": now - 120, "amount_atomic": 999}],
            }
        )
        out = series_views.build_payouts(mgr, "all")
        assert out["monero"] == [{"x": int((now - 60) * 1000), "amount": 12_345}]
        assert out["tari"] == [{"x": int((now - 120) * 1000), "amount": 999}]

    def test_build_payouts_range_filters_like_blocks(self, monkeypatch):
        monkeypatch.setattr(series_views.config, "PAYOUT_CONFIRM_ENABLED", True)
        monkeypatch.setattr(series_views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
        now = time.time()
        mgr = self._payout_mgr(
            {
                "tari": [
                    {"ts": now - 8 * 24 * 3600, "amount_atomic": 1},
                    {"ts": now - 60, "amount_atomic": 2},
                ]
            }
        )
        assert len(series_views.build_payouts(mgr, "1w")["tari"]) == 1

    def test_build_payouts_gates_per_chain_and_none_mgr(self, monkeypatch):
        # A disabled chain stays an empty list even when rows exist — the payload never leaks
        # payout data while the operator has confirmation off for that chain.
        monkeypatch.setattr(series_views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(series_views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
        now = time.time()
        mgr = self._payout_mgr(
            {
                "monero": [{"ts": now, "amount_atomic": 1}],
                "tari": [{"ts": now, "amount_atomic": 2}],
            }
        )
        out = series_views.build_payouts(mgr, "all")
        assert out["monero"] == []
        assert len(out["tari"]) == 1
        mgr.get_payouts.assert_called_once_with("tari")  # disabled chain never queried
        assert series_views.build_payouts(None, "all") == {"monero": [], "tari": []}

    def test_payouts_ride_build_state_end_to_end(self, _data, _state_mgr, monkeypatch):
        # The wiring, not just the builder: with confirmation on, a stored payout row surfaces
        # in the top-level payload the client polls (the mine cart train reads state.payouts).
        # The shared _state_mgr() MagicMock auto-mocks get_payouts, so point it at real rows.
        monkeypatch.setattr(series_views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(series_views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
        sm = _state_mgr()
        sm.get_payouts.return_value = [
            {"chain": "tari", "txid": "t1", "height": 9, "ts": time.time(), "amount_atomic": 4552}
        ]
        st = build_state(_data(), sm, "all")
        assert st["payouts"]["monero"] == []
        assert len(st["payouts"]["tari"]) == 1
        assert st["payouts"]["tari"][0]["amount"] == 4552
        # Only x + amount ship — no txid in the payload the browser sees.
        assert set(st["payouts"]["tari"][0]) == {"x", "amount"}
        # The earnings card's confirmed summaries gate on the SAME flags in the same request —
        # the timeline (mine cart) and the card can never disagree about whether payout
        # confirmation is on for a chain.
        assert st["earnings"]["tari_confirmed"]["enabled"] is True
        assert st["earnings"]["confirmed"] == {"enabled": False}

    def test_build_disk_growth_shape_and_ms_epoch(self):
        now = time.time()
        rows = [
            {
                "ts": now - 3600,
                "monero_db_bytes": 85_000_000_000,
                "disk_used_gb": 120.5,
                "disk_total_gb": 500.0,
            }
        ]
        pts = build_disk_growth(rows, "all")
        assert pts == [
            {
                "x": int((now - 3600) * 1000),
                "monero_db_bytes": 85_000_000_000,
                "disk_used_gb": 120.5,
                "disk_total_gb": 500.0,
            }
        ]

    def test_build_disk_growth_range_filters_old_rows(self):
        now = time.time()
        rows = [
            {
                "ts": now - 8 * 24 * 3600,
                "monero_db_bytes": 1,
                "disk_used_gb": 1,
                "disk_total_gb": 1,
            },
            {"ts": now - 60, "monero_db_bytes": 2, "disk_used_gb": 2, "disk_total_gb": 2},
        ]
        assert len(build_disk_growth(rows, "1w")) == 1

    def test_build_disk_growth_long_series_is_bounded_and_bucket_averaged(self):
        # Hourly, permanent (no retention prune) -> a long-lived install can pass the cap.
        now = time.time()
        rows = [
            {
                "ts": now - i * 3600,
                "monero_db_bytes": 100,
                "disk_used_gb": 10.0,
                "disk_total_gb": 500.0,
            }
            for i in range(10_000, 0, -1)  # ascending ts, like the DB returns them
        ]
        pts = build_disk_growth(rows, "all")
        assert len(pts) <= _MAX_CHART_POINTS
        # Every source row carries the same constant values, so the bucket average is exact.
        assert all(p["monero_db_bytes"] == 100 and p["disk_used_gb"] == 10.0 for p in pts)

    def test_build_xvb_history_shape_and_ms_epoch(self):
        now = time.time()
        rows = [
            {
                "ts": now - 300,
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
                "donation_fraction": 0.5,
            }
        ]
        pts = build_xvb_history(rows, "all")
        assert pts == [
            {
                "x": int((now - 300) * 1000),
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
                "donation_fraction": 0.5,
            }
        ]

    def test_build_xvb_history_range_filters_old_rows(self):
        now = time.time()
        rows = [
            {
                "ts": now - 40 * 24 * 3600,
                "avg_1h": 1,
                "avg_24h": 1,
                "fail_count": 0,
                "donation_fraction": 0,
            },
            {
                "ts": now - 300,
                "avg_1h": 2,
                "avg_24h": 2,
                "fail_count": 0,
                "donation_fraction": 0,
            },
        ]
        assert len(build_xvb_history(rows, "1m")) == 1

    def test_build_xvb_history_long_series_is_bounded_and_bucket_averaged(self):
        # 30 days at ~5-min cadence is ~8.6k rows, well past the chart cap.
        now = time.time()
        rows = [
            {
                "ts": now - i * 300,
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
                "donation_fraction": 0.5,
            }
            for i in range(8_640, 0, -1)  # ascending ts, like the DB returns them
        ]
        pts = build_xvb_history(rows, "all")
        assert len(pts) <= _MAX_CHART_POINTS
        assert all(p["avg_1h"] == 1000.0 for p in pts)


# --- Pool cadence & luck (#84) ---------------------------------------------------------


class TestCadence:
    def test_formats_available_figures(self, _metrics):
        c = build_cadence(
            _metrics(
                last_block_ts=time.time() - 90,
                expected_share_sec=3600.0,
                luck_pct=123.4,
                own_pplns_weight=1_234_567.0,
            )
        )
        assert c["available"] is True
        assert c["since_block"] == "1m 30s"
        assert c["tts"] == "1h 0m"
        assert c["luck"] == "123%"
        assert c["weight"] == "1,234,567"

    def test_dash_fallbacks_when_unavailable(self, _metrics):
        # No hashrate history / pool difficulty yet (#84 pitfall): everything reads "—", never
        # inf/0s, and available gates the card's luck + time-to-share.
        c = build_cadence(_metrics())  # _BASE leaves the cadence fields at their 0.0 defaults
        assert c["available"] is False
        assert c["since_block"] == "—"
        assert c["tts"] == "—"
        assert c["luck"] == "—"
        assert c["weight"] == "0"
        assert c["last_block"] == "Never"
