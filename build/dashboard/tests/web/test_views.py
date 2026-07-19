"""Unit tests for the dashboard view/presentation layer (mining_dashboard/web/views.py).

The view layer formats the computed :class:`Metrics` (and a little passthrough from the raw
snapshot) into the structured ``/api/state`` payload the Preact client renders. Domain logic is
tested in tests/service/test_metrics.py; here we test the *display* mapping (formatting +
presentation tokens), the chart series (Issue #65), and the full ``build_state`` contract.
"""

import json
import time
from dataclasses import replace
from unittest.mock import MagicMock, patch

import pytest

import mining_dashboard.web.views as views
from mining_dashboard.config import config as egress_config
from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    HASHRATE_WINDOWS,
    XVB_STATS_STALE_AFTER_S,
)
from mining_dashboard.service.metrics import Metrics, SyncMetric, _sync_metric
from mining_dashboard.web.views import (
    _MAX_CHART_POINTS,
    _chart_tension,
    _mode_palette,
    _reject_flag,
    _rigforge_display,
    _target_points,
    _window_reject_pct,
    build_badges,
    build_cadence,
    build_chart,
    build_earnings,
    build_energy,
    build_hashrate,
    build_pool_network,
    build_proxy_summary,
    build_raffle_eligibility,
    build_share_stats,
    build_state,
    build_sync,
    build_system,
    build_tari,
    build_worker_detail,
    build_workers,
    build_xvb_calc,
    canonical_window,
    get_shell_html,
    host_display_addr,
    parse_window,
    recent_wallet_change,
    visible_update,
)

# --- Metrics fixtures for the presentation builders -----------------------------------

_SYNC_DONE = SyncMetric(
    percent=100, current=10, target=10, remaining=0, has_target=True, done=True, down=False
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
    current_tier="Donor (1.00 kH/s+)",
    target_tier="Donor (1.00 kH/s+)",
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
    monero=_SYNC_DONE,
    tari=_SYNC_DONE,
    monero_mode="Unknown",
    tari_mining=True,
)


def _metrics(**over):
    return replace(_BASE, **over)


def _sync(**over):
    return replace(_SYNC_DONE, **over)


def _hashrate(metrics):
    """build_hashrate with palette tokens derived as build_state does."""
    return build_hashrate(metrics, *_mode_palette(metrics.mode))


# --- Chart (Issue #65: real-time x-axis, outage gaps as breaks) -----------------------


class TestChart:
    def _line(self, n, start_ts, step=30):
        return [
            {
                "timestamp": start_ts + i * step,
                "v": 100 + i,
                "v_p2pool": 100 + i,
                "v_xvb": 0,
                "t": "x",
            }
            for i in range(n)
        ]

    def test_point_shape_is_xy_with_epoch_ms(self):
        chart = build_chart(
            [{"timestamp": 1000, "v": 800, "v_p2pool": 500, "v_xvb": 300, "t": "a"}], [], "all"
        )
        assert chart["p2pool"] == [{"x": 1_000_000, "y": 500}]
        assert chart["xvb"] == [{"x": 1_000_000, "y": 300}]

    def test_legacy_rows_attributed_to_p2pool(self):
        chart = build_chart(
            [{"timestamp": 1, "v": 800, "v_p2pool": 0, "v_xvb": 0, "t": "a"}], [], "all"
        )
        assert chart["p2pool"][0]["y"] == 800
        assert chart["xvb"][0]["y"] == 0

    def test_range_filtering(self):
        now = time.time()
        history = [
            {"timestamp": now - 7200, "v": 1, "v_p2pool": 1, "v_xvb": 0, "t": "x"},
            {"timestamp": now - 60, "v": 2, "v_p2pool": 2, "v_xvb": 0, "t": "x"},
        ]
        chart = build_chart(history, [], "1h")
        assert len(chart["p2pool"]) == 1  # the 2h-old point is dropped

    def test_downsampling_caps_points(self):
        now = time.time()
        chart = build_chart(self._line(2000, now - 60000), [], "all")
        # Adaptive cap (Issue #47): never more than the ceiling, and actually downsampled.
        real = [p for p in chart["p2pool"] if p["y"] is not None]
        assert len(real) <= 700
        assert len(real) < 2000

    def test_outage_inserts_null_break(self):
        # 10 regular 30s samples, a 2-hour outage, then 5 more.
        hist = self._line(10, 1_000_000)
        t = hist[-1]["timestamp"] + 7200
        hist += [
            {"timestamp": t + i * 30, "v": 200, "v_p2pool": 200, "v_xvb": 0, "t": "x"}
            for i in range(5)
        ]
        chart = build_chart(hist, [], "all")
        nulls = [p for p in chart["p2pool"] if p["y"] is None]
        assert len(nulls) == 1  # exactly one break, in the gap
        xs = [p["x"] for p in chart["p2pool"]]
        assert xs == sorted(xs)  # still chronological
        # both series break at the same place
        assert sum(1 for p in chart["xvb"] if p["y"] is None) == 1

    def test_regular_data_has_no_breaks(self):
        chart = build_chart(self._line(50, 1_000_000), [], "all")
        assert all(p["y"] is not None for p in chart["p2pool"])

    def test_single_missing_sample_does_not_break(self):
        # One dropped sample (a ~60s gap in 30s data) is below the outage threshold — a brief
        # blip shouldn't fragment the line, only a real outage should.
        ts = [1_000_000 + i * 30 for i in range(10)]
        del ts[5]
        hist = [{"timestamp": t, "v": 100, "v_p2pool": 100, "v_xvb": 0, "t": "x"} for t in ts]
        assert all(p["y"] is not None for p in build_chart(hist, [], "all")["p2pool"])

    def test_break_sits_inside_the_gap(self):
        # The break marker must land between the two surrounding samples (so it renders inside
        # the empty span, making the gap visible) — not at an endpoint.
        hist = self._line(5, 1_000_000)
        t = hist[-1]["timestamp"] + 7200
        hist += [
            {"timestamp": t + i * 30, "v": 200, "v_p2pool": 200, "v_xvb": 0, "t": "x"}
            for i in range(5)
        ]
        pts = build_chart(hist, [], "all")["p2pool"]
        i = next(k for k, p in enumerate(pts) if p["y"] is None)
        assert pts[i - 1]["x"] < pts[i]["x"] < pts[i + 1]["x"]

    def test_threshold_adapts_to_spacing(self):
        # Uniformly *wide* spacing (as after downsampling a long range): a fixed 90s threshold
        # would break on every interval; the adaptive (median-based) one must not break regular
        # data at all, no matter how wide the spacing.
        chart = build_chart(self._line(30, 1_000_000, step=600), [], "all")
        assert all(p["y"] is not None for p in chart["p2pool"])

    def test_downsampled_outage_still_breaks(self):
        # The real #65 scenario: a long range that gets downsampled, with an outage in it. The
        # break must survive downsampling (gap detected on the post-downsample timestamps).
        now = time.time()
        hist = self._line(1000, now - 100000, step=30)  # dense, will downsample
        gap_start = hist[-1]["timestamp"] + 6 * 3600  # 6h outage
        hist += self._line(1000, gap_start, step=30)
        chart = build_chart(hist, [], "all")
        assert any(p["y"] is None for p in chart["p2pool"])

    def test_single_point_no_break(self):
        chart = build_chart(
            [{"timestamp": 1, "v": 5, "v_p2pool": 5, "v_xvb": 0, "t": "a"}], [], "all"
        )
        assert len(chart["p2pool"]) == 1

    def test_share_points_sparse_and_top_pinned(self):
        # Markers ride a dedicated 0–1 axis pinned near the top, independent of hashrate, so they
        # don't inflate the y-range and bury a flat line (Issue #145). Radius still scales by count.
        history = [
            {"timestamp": 1000, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},
            {"timestamp": 1030, "v": 600, "v_p2pool": 600, "v_xvb": 0, "t": "b"},
        ]
        shares = [{"ts": 1001}, {"ts": 1029}]  # one near each sample
        pts = build_chart(history, shares, "all")["shares"]
        assert pts == [
            {"x": 1_000_000, "y": 0.93, "r": 9, "c": 1},  # fixed top position, radius 6+3
            {"x": 1_030_000, "y": 0.93, "r": 9, "c": 1},
        ]

    def test_share_marker_top_pinned_when_value_zero(self):
        # Same fixed position even at zero hashrate — the marker stays visible without a floor hack.
        pts = build_chart(
            [{"timestamp": 1000, "v": 0, "v_p2pool": 0, "v_xvb": 0, "t": "a"}],
            [{"ts": 1000}],
            "all",
        )["shares"]
        assert pts == [{"x": 1_000_000, "y": 0.93, "r": 9, "c": 1}]

    def test_no_shares_no_points(self):
        assert (
            build_chart([{"timestamp": 1, "v": 5, "v_p2pool": 5, "v_xvb": 0, "t": "a"}], [], "all")[
                "shares"
            ]
            == []
        )

    def test_unknown_range_keeps_everything(self):
        # An unrecognized range value falls through to "no filtering" (same as 'all').
        now = time.time()
        history = self._line(3, now - 90)
        assert len(build_chart(history, [], "bogus")["p2pool"]) == 3

    def test_empty_history(self):
        assert build_chart([], [], "all") == {
            "p2pool": [],
            "xvb": [],
            "shares": [],
            "events": [],
            "raffle": [],
            "tension": 0.0,
        }

    # --- Issue #47: custom zoom window + duration-adaptive resolution/smoothing ---------

    def test_custom_window_filters_both_bounds(self):
        # A preset bounds only the lower end; a custom window clips BOTH ends.
        hist = self._line(10, 1000)  # timestamps 1000..1270 (step 30)
        chart = build_chart(hist, [], "all", window=(1060, 1150))
        xs = [p["x"] for p in chart["p2pool"]]
        assert xs == [1060_000, 1090_000, 1120_000, 1150_000]  # only ts in [1060, 1150]

    def test_window_overrides_range(self):
        # When both a window and a range are given, the window wins.
        hist = self._line(10, 1000)
        windowed = build_chart(hist, [], "1h", window=(1060, 1150))
        assert len(windowed["p2pool"]) == 4

    def test_short_window_kept_at_native_resolution(self):
        # A <=1h window is never downsampled — full 30s detail (the "more detail zoomed in" goal).
        now = time.time()
        hist = self._line(120, now - 119 * 30, step=30)  # ~1h of 30s samples, ending now
        chart = build_chart(hist, [], "1h")
        assert len([p for p in chart["p2pool"] if p["y"] is not None]) == 120

    def test_long_window_downsamples_to_tier(self):
        now = time.time()
        # ~1 week of 30s data (20160 pts) -> capped at the <=1w tier (600).
        chart = build_chart(self._line(20160, now - 604800, step=30), [], "1w")
        assert len([p for p in chart["p2pool"] if p["y"] is not None]) <= 600

    def test_target_points_tiers(self):
        assert _target_points(3600) == 0  # <= 1h: native
        assert _target_points(3601) == 360  # <= 6h
        assert _target_points(86400) == 480  # <= 24h
        assert _target_points(604800) == 600  # <= 1w
        assert _target_points(604801) == 700  # > 1w
        assert _target_points(30 * 86400) == 700  # ceiling

    def test_chart_tension_tiers(self):
        assert _chart_tension(3600) == 0.0
        assert _chart_tension(86400) == 0.2
        assert _chart_tension(604800) == 0.35
        assert _chart_tension(604801) == 0.4
        # The payload carries the duration-derived tension the client applies.
        assert build_chart(self._line(5, 1000), [], "1h")["tension"] == 0.0

    def test_stacked_series_sum_to_the_total(self):
        # The client stacks P2Pool + XvB so the top edge is the total. That's correct only
        # because at each sample the full hashrate goes to one pool (v_p2pool + v_xvb == v).
        # Guard that invariant on the emitted points so a future data change can't silently
        # break the stack (Issue #47).
        hist = [
            {"timestamp": 1000, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},  # P2Pool sample
            {"timestamp": 1030, "v": 700, "v_p2pool": 0, "v_xvb": 700, "t": "b"},  # XvB sample
            {"timestamp": 1060, "v": 600, "v_p2pool": 600, "v_xvb": 0, "t": "c"},
        ]
        chart = build_chart(hist, [], "all")
        for p2p, xvb, row in zip(chart["p2pool"], chart["xvb"], hist, strict=False):
            assert p2p["y"] + xvb["y"] == row["v"]  # stack top == total at every point

    def test_zoom_reveals_more_detail(self):
        # Core intent (Issue #47): zooming into a sub-window shows finer data than the wide view
        # of the same history. 8h of dense 30s samples — a ~1h window stays native resolution
        # while the full 8h downsamples, so the narrow window has more points per hour.
        now = time.time()
        dense = self._line(960, now - 8 * 3600, step=30)  # 8h @ 30s
        wide = build_chart(dense, [], "all", window=(dense[0]["timestamp"], dense[-1]["timestamp"]))
        narrow = build_chart(
            dense, [], "all", window=(dense[-120]["timestamp"], dense[-1]["timestamp"])
        )
        wide_pts = len([p for p in wide["p2pool"] if p["y"] is not None])
        narrow_pts = len([p for p in narrow["p2pool"] if p["y"] is not None])
        assert narrow_pts == 120  # 1h window: native, untouched
        assert narrow_pts / 1 > wide_pts / 8  # more points per hour zoomed in

    def test_all_range_adapts_density_to_data_extent(self):
        # With "all" (no preset length, no window) the adaptive density keys off the actual data
        # extent (_window_duration). A ~2-week span lands in the widest tier and downsamples.
        now = time.time()
        dense = self._line(5000, now - 14 * 86400, step=int(14 * 86400 / 5000))
        real = [p for p in build_chart(dense, [], "all")["p2pool"] if p["y"] is not None]
        assert len(real) <= 700 and len(real) < 5000


class TestChartWindow:
    """The averaging-window toggle (#168): build_chart plots the selected window's columns, and the
    `avg` param is validated. 10m (default) keeps the legacy un-split fallback; the others don't."""

    def _row(self):
        # One row carrying both the original 10m split and the per-window columns.
        return {
            "timestamp": 1000,
            "t": "a",
            "v": 1000,
            "v_p2pool": 1000,
            "v_xvb": 0,
            "v_p2pool_1m": 900,
            "v_xvb_1m": 0,
            "v_p2pool_1h": 1100,
            "v_xvb_1h": 0,
            "v_p2pool_12h": 50,
            "v_xvb_12h": 0,
            "v_p2pool_24h": 10,
            "v_xvb_24h": 0,
        }

    def test_default_window_is_10m(self):
        # No avg_window arg -> the original v_p2pool/v_xvb pair (today's headline series).
        chart = build_chart([self._row()], [], "all")
        assert chart["p2pool"][0]["y"] == 1000

    @pytest.mark.parametrize(
        "win,expected",
        [
            ("1m", 900),
            ("10m", 1000),
            ("1h", 1100),
            ("12h", 50),
            ("24h", 10),
        ],
    )
    def test_each_window_selects_its_columns(self, win, expected):
        chart = build_chart([self._row()], [], "all", None, win)
        assert chart["p2pool"][0]["y"] == expected

    def test_legacy_fallback_only_on_default_window(self):
        # A pre-#168 row has only v/v_p2pool/v_xvb. On 10m the un-split total falls back to p2pool;
        # on another window there's no per-window data, so it reads 0 (forward-only) — NOT the total.
        legacy = {"timestamp": 1, "t": "a", "v": 800, "v_p2pool": 0, "v_xvb": 0}
        assert build_chart([legacy], [], "all", None, "10m")["p2pool"][0]["y"] == 800
        assert build_chart([legacy], [], "all", None, "1h")["p2pool"][0]["y"] == 0

    def test_canonical_window_validates(self):
        for w in HASHRATE_WINDOWS:
            assert canonical_window(w) == w
        assert canonical_window("bogus") == DEFAULT_HASHRATE_WINDOW
        assert canonical_window(None) == DEFAULT_HASHRATE_WINDOW
        assert canonical_window("") == DEFAULT_HASHRATE_WINDOW

    def test_downsample_preserves_per_window_columns(self):
        # Regression: bucket-averaged rows must keep EVERY per-window column (#168). The old
        # downsampler dropped all but v/v_p2pool/v_xvb, so non-default Avg windows read 0 on any
        # range wide enough to downsample (24h/1w/1mo).
        base = self._row()
        rows = [{**base, "timestamp": i} for i in range(600)]  # 600 > target(480) for a 24h span
        out = views._downsample_history(rows, 86400)
        assert len(out) < len(rows)  # actually downsampled
        assert out[0]["v_p2pool_1m"] == 900 and out[-1]["v_p2pool_1m"] == 900
        assert out[0]["v_p2pool_1h"] == 1100 and out[0]["v_p2pool_24h"] == 10

    def test_wide_range_keeps_nondefault_avg_nonzero(self):
        # End to end: a 24h chart at the 1m Avg window must NOT collapse to a flat-zero line.
        base = self._row()
        history = [{**base, "timestamp": i * 30} for i in range(600)]
        chart = build_chart(history, [], "24h", (0, 86400), "1m")
        ys = [p["y"] for p in chart["p2pool"] if p["y"] is not None]
        assert len(chart["p2pool"]) < 600  # downsampled
        assert ys and all(y == 900 for y in ys)  # 1m series preserved (was 0 before the fix)

    def test_build_state_echoes_selected_window(self):
        state = build_state(_data(), _state_mgr(history=[self._row()]), "all", None, "1h")
        assert state["avg_window"] == "1h"
        assert state["avg_windows"] == HASHRATE_WINDOWS
        assert state["chart"]["p2pool"][0]["y"] == 1100  # the 1h column, end to end

    def test_build_state_defaults_to_10m(self):
        state = build_state(_data(), _state_mgr(history=[self._row()]), "all")
        assert state["avg_window"] == DEFAULT_HASHRATE_WINDOW
        assert state["chart"]["p2pool"][0]["y"] == 1000  # the original 10m series

    def test_build_state_exposes_control_flag_for_upgrade_button(self, monkeypatch):
        # Off by default; flipping the module attribute flips the state key (#59 button gating).
        import mining_dashboard.config.config as cfg

        state = build_state(_data(), _state_mgr(history=[self._row()]), "all")
        assert state["control_enabled"] is False
        monkeypatch.setattr(cfg, "DASHBOARD_CONTROL_ENABLED", True)
        state = build_state(_data(), _state_mgr(history=[self._row()]), "all")
        assert state["control_enabled"] is True


# --- Hashrate / mode / tier formatting ------------------------------------------------


class TestHashrate:
    def test_formats_hashrates(self):
        hr = _hashrate(_metrics(total_h15=10500, p2pool_1h=8000, xvb_1h=2100))
        assert hr["total"] == "10.50 kH/s"
        assert hr["p2p_1h"] == "8.00 kH/s"
        assert hr["xvb_1h"] == "2.10 kH/s"

    def test_routed_distinct_from_credited(self):
        # Routed (proxy v_xvb) is shown in the header/Simple and alongside credited in the Advanced
        # card so the live credit factor is visible — distinct from credited avg_1h/24h (#156).
        hr = _hashrate(_metrics(xvb_routed_1h=2000, xvb_24h=6500, xvb_1h=6000))
        assert hr["xvb_routed_1h"] == "2.00 kH/s"
        assert hr["xvb_1h"] == "6.00 kH/s"

    def test_p2pool_mode_grays_xvb(self):
        hr = _hashrate(_metrics(mode="P2POOL"))
        assert hr["mode_variant"] == "ok"
        assert hr["p2p_variant"] == "ok"
        assert hr["xvb_variant"] == "muted"

    def test_xvb_mode_grays_p2pool(self):
        hr = _hashrate(_metrics(mode="XVB"))
        assert hr["mode_variant"] == "purple"
        assert hr["p2p_variant"] == "muted"
        assert hr["xvb_variant"] == "purple"

    def test_split_mode_both_active(self):
        hr = _hashrate(_metrics(mode="XVB (Split)"))
        assert hr["mode_variant"] == "accent"
        assert hr["p2p_variant"] == "ok"
        assert hr["xvb_variant"] == "purple"

    def test_low_hr_badge_present_only_when_warned(self):
        assert _hashrate(_metrics(low_hr_warning=False))["low_hr"] is None
        warned = _hashrate(_metrics(low_hr_warning=True))["low_hr"]
        assert warned and "low for tier" in warned["text"] and warned["title"]

    def test_tiers_and_fail_count_passthrough(self):
        hr = _hashrate(_metrics(current_tier="Vip (X)", target_tier="Whale (Y)", xvb_fail_count=3))
        assert hr["tier"] == "Vip (X)"
        assert hr["target_tier"] == "Whale (Y)"
        assert hr["xvb_fail_count"] == 3


# --- Sync display state mapping -------------------------------------------------------


class TestSync:
    def test_loading_done_syncing_states(self):
        m = _metrics(
            monero=_sync(has_target=False, done=False),
            tari=_sync(
                has_target=True, done=False, percent=40, current=40, target=100, remaining=60
            ),
        )
        sync = build_sync(m, "85.0 GB")
        assert sync["monero"]["state"] == "loading"
        assert sync["tari"]["state"] == "syncing"
        assert sync["tari"]["remaining"] == 60

    def test_done_state(self):
        sync = build_sync(_metrics(), "1.0 GB")
        assert sync["monero"]["state"] == "done"

    def test_synced_node_with_no_target_shows_done(self):
        # Regression for the bug found in the #180 live validation: a fully-synced monerod reports
        # target_height: 0 (so has_target is False) and is_syncing: False. Through the real
        # _sync_metric + build_sync it must read "done" — previously it stuck at "loading" forever,
        # because _sync_metric derived `done` purely from percent>=100 (which needs a target) and
        # build_sync gated on has_target first.
        m = _metrics(monero=_sync_metric({"is_syncing": False, "reachable": True}))
        assert build_sync(m, "1.0 GB")["monero"]["state"] == "done"

    def test_no_target_but_not_caught_up_is_not_done(self):
        # The same no-target shape, but NOT caught up, must not read "done".
        m_loading = _metrics(monero=_sync_metric({}))  # no status yet
        m_syncing = _metrics(
            monero=_sync_metric(
                {"is_syncing": True, "reachable": True, "current": 5, "target": 10, "percent": 50}
            )
        )
        assert build_sync(m_loading, "1.0 GB")["monero"]["state"] == "loading"
        assert build_sync(m_syncing, "1.0 GB")["monero"]["state"] == "syncing"

    def test_monero_mode_and_db_passthrough(self):
        sync = build_sync(_metrics(monero_mode="Pruned"), "85.0 GB")
        assert sync["monero"]["mode"] == "Pruned"
        assert sync["monero"]["db_size"] == "85.0 GB"


# --- Badges ---------------------------------------------------------------------------


class TestBadges:
    def _texts(self, badges):
        return [b["text"] for b in badges]

    def test_syncing_shows_syncing_only(self):
        out = build_badges({}, _metrics(global_syncing=True), "ok")
        assert "Syncing..." in self._texts(out)
        assert not any("P2POOL" in t for t in self._texts(out))

    def test_operational_shows_mode_and_pool(self):
        out = build_badges({}, _metrics(mode="P2POOL", pool_type="Mini"), "ok")
        assert "P2POOL" in self._texts(out)
        assert "P2Pool Mini" in self._texts(out)

    def test_low_hr_badge(self):
        out = build_badges({}, _metrics(low_hr_warning=True), "ok")
        assert any(b["variant"] == "warn" and "low for tier" in b["text"] for b in out)

    def test_no_share_badge_when_donating_without_a_share(self):
        # XvB enabled + no PPLNS share => wins are skipped + a fail, regardless of tier (#158).
        out = build_badges({}, _metrics(xvb_enabled=True, shares_in_window=0), "ok")
        assert any("No PPLNS share" in b["text"] for b in out)

    def test_no_share_badge_absent_when_has_share_or_xvb_off(self):
        # Has a share => no badge; XvB off => raffle moot, no badge.
        assert not any(
            "No PPLNS share" in t
            for t in self._texts(
                build_badges({}, _metrics(xvb_enabled=True, shares_in_window=3), "ok")
            )
        )
        assert not any(
            "No PPLNS share" in t
            for t in self._texts(
                build_badges({}, _metrics(xvb_enabled=False, shares_in_window=0), "ok")
            )
        )

    def test_xvb_registered_badge(self):
        # registered_at set + clean state => a muted "✓" confirmation badge (#263).
        out = build_badges({}, _metrics(xvb_enabled=True, xvb_registered_at=1.0), "ok")
        assert any(b["text"] == "XvB raffle ✓" and b["variant"] == "outline" for b in out)

    def test_xvb_invalid_wallet_badge(self):
        # Endpoint rejected the wallet => loud "bad" badge so the user fixes MONERO_WALLET_ADDRESS.
        out = build_badges({}, _metrics(xvb_enabled=True, xvb_registration_state="invalid"), "ok")
        assert any(b["variant"] == "bad" and "wallet rejected" in b["text"] for b in out)

    def test_xvb_failing_badge_takes_priority_over_checkmark(self):
        # A real problem must not be masked by a stale registered_at.
        out = build_badges(
            {},
            _metrics(xvb_enabled=True, xvb_registration_state="failing", xvb_registered_at=1.0),
            "ok",
        )
        assert any(b["variant"] == "bad" and "failing" in b["text"] for b in out)
        assert not any("✓" in b["text"] for b in out)

    def test_no_xvb_registration_badge_when_disabled(self):
        out = build_badges({}, _metrics(xvb_enabled=False, xvb_registered_at=1.0), "ok")
        assert not any("XvB raffle" in b["text"] for b in out)

    def test_node_down_and_rejected(self):
        m = _metrics(monero=_sync(down=True), tari=_sync(down=True))
        out = build_badges({"workers_rejected": True}, m, "ok")
        t = self._texts(out)
        assert "monerod DOWN" in t and "Tari DOWN" in t and "Workers rejected" in t

    def test_miner_held(self):
        out = build_badges({"miner_held": True}, _metrics(global_syncing=True), "ok")
        assert "Miner held (sync)" in self._texts(out)

    def test_passive_tari_with_and_without_percent(self):
        with_pct = build_badges(
            {"tari_syncing_passive": True}, _metrics(tari=_sync(percent=42)), "ok"
        )
        assert "Tari syncing 42%" in self._texts(with_pct)
        no_pct = build_badges({"tari_syncing_passive": True}, _metrics(tari=_sync(percent=0)), "ok")
        assert "Tari syncing" in self._texts(no_pct)

    def test_monero_pruned_badge(self):
        out = build_badges({}, _metrics(monero_mode="Pruned"), "ok")
        assert any(b["text"] == "XMR Pruned" and b["variant"] == "outline" for b in out)

    def test_monero_full_badge(self):
        out = build_badges({}, _metrics(monero_mode="Full"), "ok")
        assert any(b["text"] == "XMR Full" and b["variant"] == "outline" for b in out)

    def test_no_prune_badge_when_unknown(self):
        out = build_badges({}, _metrics(monero_mode="Unknown"), "ok")
        assert not any("XMR" in b["text"] for b in out)

    def test_disk_badge_critical(self):
        out = build_badges({"system": {"disk": {"percent": 96}}}, _metrics(), "ok")
        assert any(b["variant"] == "bad" and "Disk 96% full" in b["text"] for b in out)

    def test_disk_badge_warn(self):
        out = build_badges({"system": {"disk": {"percent": 88}}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Disk 88% full" in b["text"] for b in out)

    def test_no_disk_badge_when_ample(self):
        out = build_badges({"system": {"disk": {"percent": 50}}}, _metrics(), "ok")
        assert not any("Disk" in b["text"] for b in out)

    def test_no_disk_badge_when_missing(self):
        # No system/disk data (e.g. an early poll) must not emit a spurious or crashing badge.
        out = build_badges({}, _metrics(), "ok")
        assert not any("Disk" in b["text"] for b in out)

    # --- Host-perf badges (#104): AVX2 / HugePages / low RAM, from live metrics -------------
    def test_hugepages_disabled_badge(self):
        out = build_badges(
            {"system": {"hugepages": ["Disabled", "status-bad", "0/0"]}}, _metrics(), "ok"
        )
        assert any(b["variant"] == "warn" and "HugePages off" in b["text"] for b in out)

    def test_no_hugepages_badge_when_reserved(self):
        for status in ("Allocated", "Enabled", "Unknown"):  # only "Disabled" is a problem
            out = build_badges({"system": {"hugepages": [status, "", "1/2"]}}, _metrics(), "ok")
            assert not any("HugePages" in b["text"] for b in out), status

    def test_low_ram_badge(self):
        out = build_badges({"system": {"memory": {"total_gb": 8}}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Low RAM (8 GB)" in b["text"] for b in out)

    def test_no_low_ram_badge_at_or_above_threshold_or_unknown(self):
        assert not any(
            "Low RAM" in b["text"]
            for b in build_badges({"system": {"memory": {"total_gb": 16}}}, _metrics(), "ok")
        )
        # total 0 = couldn't read /proc/meminfo (not "0 GB of RAM") — no false badge.
        assert not any(
            "Low RAM" in b["text"]
            for b in build_badges({"system": {"memory": {"total_gb": 0}}}, _metrics(), "ok")
        )

    def test_avx2_missing_badge(self):
        out = build_badges({"system": {"avx2": False}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "No AVX2" in b["text"] for b in out)

    def test_no_avx2_badge_when_present_or_unknown(self):
        assert not any(
            "AVX2" in b["text"] for b in build_badges({"system": {"avx2": True}}, _metrics(), "ok")
        )
        # None = couldn't determine (non-Linux / unreadable) — stay silent, don't cry wolf.
        assert not any(
            "AVX2" in b["text"] for b in build_badges({"system": {"avx2": None}}, _metrics(), "ok")
        )


# --- Payout-wallet tripwire banner (#375) ----------------------------------------------


class TestWalletChangedBadge:
    _NEW = "4B" + "b" * 93

    def _kv_mgr(self, **kv):
        sm = MagicMock()
        sm.get_kv.side_effect = kv.get
        return sm

    def test_recent_change_within_72h(self):
        sm = self._kv_mgr(
            payout_wallet_changed_ts="1000",
            payout_wallet=self._NEW,
            payout_wallet_prev8="4Aaaaaaa",
        )
        wc = recent_wallet_change(sm, now=1000 + 71 * 3600)
        assert wc == {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}

    def test_expired_after_72h(self):
        sm = self._kv_mgr(payout_wallet_changed_ts="1000", payout_wallet=self._NEW)
        assert recent_wallet_change(sm, now=1000 + 72 * 3600) is None

    def test_no_change_recorded(self):
        assert recent_wallet_change(self._kv_mgr()) is None

    def test_unreadable_ts_is_no_change(self):
        assert recent_wallet_change(self._kv_mgr(payout_wallet_changed_ts="junk")) is None

    def test_badge_rendered_and_truncated(self):
        wc = {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}
        out = build_badges({}, _metrics(), "ok", wallet_change=wc)
        badge = next(b for b in out if "Payout wallet changed" in b["text"])
        assert badge["variant"] == "warn"
        assert "4Aaaaaaa…" in badge["title"] and f"{self._NEW[:8]}…" in badge["title"]
        assert self._NEW not in badge["title"]  # never the full address

    def test_shown_even_while_syncing(self):
        wc = {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}
        out = build_badges({}, _metrics(global_syncing=True), "ok", wallet_change=wc)
        assert any("Payout wallet changed" in b["text"] for b in out)

    def test_no_badge_without_recent_change(self):
        out = build_badges({}, _metrics(), "ok", wallet_change=None)
        assert not any("Payout wallet" in b["text"] for b in out)

    def test_build_state_surfaces_the_badge_from_kv(self):
        sm = _state_mgr()
        sm.get_kv.side_effect = {
            "payout_wallet_changed_ts": str(time.time() - 60),
            "payout_wallet": self._NEW,
            "payout_wallet_prev8": "4Aaaaaaa",
        }.get
        st = build_state(_data(), sm, "all")
        assert any("Payout wallet changed" in b["text"] for b in st["badges"])


# --- System (presentation thresholds) -------------------------------------------------


class TestSystem:
    def test_high_usage_levels_and_fill(self):
        s = build_system(
            {
                "system": {
                    "disk": {"percent": 95, "used_gb": 90, "total_gb": 100, "percent_str": "95%"},
                    "memory": {"percent": 85, "used_gb": 13, "total_gb": 16, "percent_str": "85%"},
                    "cpu_percent": "90.0%",
                    "load": "0.5 0.4 0.3",
                    "hugepages": ["Enabled", "status-ok", "1555/3072"],
                }
            }
        )
        assert s["disk"]["fill"] == "critical"
        assert s["disk"]["level"] == "high"
        assert s["mem"]["level"] == "high"
        assert s["cpu"]["level"] == "high"
        assert s["cpu"]["load"] == "1m: 0.5 5m: 0.4 15m: 0.3"
        assert s["hugepages"]["variant"] == "ok"

    def test_warning_fill_between_70_and_90(self):
        assert build_system({"system": {"disk": {"percent": 75}}})["disk"]["fill"] == "warning"

    def test_unparseable_cpu_is_ok(self):
        assert build_system({"system": {"cpu_percent": "n/a"}})["cpu"]["level"] == "ok"

    def test_empty_system_defaults(self):
        s = build_system({})
        assert s["hugepages"]["status"] == "Disabled"
        assert s["hugepages"]["variant"] == "bad"
        assert s["disk"]["fill"] == ""


# --- Workers --------------------------------------------------------------------------


class TestWorkers:
    def test_pool_tokens(self):
        assert (
            build_workers(
                [{"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}]
            )[0]["pool"]
            == "p2pool"
        )
        assert (
            build_workers(
                [{"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": "3344"}]
            )[0]["pool"]
            == "xvb"
        )
        assert (
            build_workers([{"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": ""}])[
                0
            ]["pool"]
            == "unknown"
        )

    def test_formatted_and_raw_fields(self):
        row = build_workers(
            [
                {
                    "name": "r",
                    "ip": "10.0.0.1",
                    "status": "online",
                    "active_pool": "3333",
                    "uptime": 3600,
                    "h10": 5000,
                    "h60": 5100,
                    "h15": 5200,
                }
            ]
        )[0]
        assert row["uptime"] == 3600 and row["uptime_str"]
        assert row["h60"] == 5100 and "kH/s" in row["h60_str"]
        assert row["h15"] == 5200 and "kH/s" in row["h15_str"]
        assert "h10" not in row  # dropped from the payload — the table shows 1m/10m (#387)

    def test_api_ok_passes_through(self):
        # The probe verdict reaches the client so it can badge a misconfigured worker API; a worker
        # we never probed (no api_ok) stays None and is left unflagged.
        base = {"name": "r", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"}
        assert build_workers([{**base, "api_ok": False}])[0]["api_ok"] is False
        assert build_workers([{**base, "api_ok": True}])[0]["api_ok"] is True
        assert build_workers([base])[0]["api_ok"] is None

    def test_online_sorted_before_offline(self):
        rows = build_workers(
            [
                {"name": "zzz", "ip": "10.0.0.9", "status": "offline", "active_pool": "3333"},
                {"name": "aaa", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"},
            ]
        )
        assert [r["name"] for r in rows] == ["aaa", "zzz"]

    def test_malformed_worker_skipped(self):
        rows = build_workers(
            [
                {"name": "good", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"},
                {"name": "skipme", "status": "online", "active_pool": "3333"},  # no 'ip'
            ]
        )
        assert [r["name"] for r in rows] == ["good"]

    def test_bad_ip_sorts_to_zero(self):
        assert (
            build_workers([{"name": "r", "ip": "nope", "status": "online", "active_pool": "3333"}])[
                0
            ]["ip_sort"]
            == 0
        )

    def test_name_passthrough(self):
        # Raw name as data; the client text-escapes it on render.
        assert (
            build_workers(
                [{"name": "<rig>", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}]
            )[0]["name"]
            == "<rig>"
        )

    def test_share_counts_raw_and_formatted(self):
        # Per-worker accepted/rejected/invalid: raw counts (sort keys) + display strings (#82).
        row = build_workers(
            [
                {
                    "name": "r",
                    "ip": "10.0.0.1",
                    "status": "online",
                    "active_pool": "3333",
                    "accepted": 1234,
                    "rejected": 5,
                    "invalid": 0,
                }
            ]
        )[0]
        assert row["accepted"] == 1234 and row["accepted_str"] == "1,234"
        assert row["rejected"] == 5 and row["rejected_str"] == "5"
        assert row["invalid"] == 0

    def test_invalid_appended_to_rejected_string_only_when_nonzero(self):
        with_inv = build_workers(
            [
                {
                    "name": "r",
                    "ip": "1.1.1.1",
                    "status": "online",
                    "active_pool": "3333",
                    "rejected": 3,
                    "invalid": 2,
                }
            ]
        )[0]
        assert with_inv["rejected_str"] == "3 (+2 inv)"

    def test_missing_share_fields_default_to_zero(self):
        # Workers restored from an old snapshot (pre-#82) lack the share fields entirely.
        row = build_workers(
            [{"name": "r", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}]
        )[0]
        assert (row["accepted"], row["rejected"], row["invalid"]) == (0, 0, 0)
        assert row["reject_flag"] is None

    def test_reject_flag_set_on_high_reject_rate(self):
        row = build_workers(
            [
                {
                    "name": "r",
                    "ip": "1.1.1.1",
                    "status": "online",
                    "active_pool": "3333",
                    "accepted": 90,
                    "rejected": 10,
                    "invalid": 0,
                }
            ]
        )[0]
        assert row["reject_flag"] and row["reject_flag"]["text"] == "⚠"
        assert "10.0%" in row["reject_flag"]["title"]


class TestRejectFlag:
    """The per-worker reject-rate flag (Issue #82)."""

    def test_none_without_rejects(self):
        assert _reject_flag(1000, 0) is None

    def test_none_below_noise_floor(self):
        # A couple of rejects out of a few shares is noise, even at a high rate.
        assert _reject_flag(2, 1) is None  # 33% but only 1 reject
        assert _reject_flag(0, 2) is None  # 100% but below the 3-reject floor

    def test_none_when_rate_low(self):
        assert _reject_flag(1000, 5) is None  # 5 rejects but only 0.5%

    def test_flags_high_rate_above_floor(self):
        flag = _reject_flag(90, 10)  # 10% with 10 rejects
        assert flag["text"] == "⚠"
        assert "10.0%" in flag["title"] and "10 rejected" in flag["title"]

    def test_flags_all_rejects_at_floor(self):
        # A worker submitting only rejects trips the floor immediately (rate 100%).
        assert _reject_flag(0, 3) is not None


class TestRigForgeDisplay:
    """The RigForge enriched-feed builder (#235). Parsed block in → {version, chips, stats} out;
    each metric emitted only when its data is present, so nothing renders for a plain-xmrig worker.
    ``chips`` feeds the compact badge row; ``stats`` is the same metrics split into label/value for
    the Worker Inspect detail table (#507). Both come from one pass, so they stay row-for-row."""

    def _chip_texts(self, disp):
        return [c["text"] for c in disp["chips"]]

    def _stats(self, disp):
        return {s["label"]: s for s in disp["stats"]}

    def test_none_for_plain_xmrig(self):
        assert _rigforge_display(None) is None

    def test_build_workers_passes_none_for_plain_xmrig(self):
        # A worker with no parsed rigforge block carries `rigforge: None` — the client renders
        # nothing extra, exactly as before the enriched feed existed.
        row = build_workers(
            [{"name": "r", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}]
        )[0]
        assert row["rigforge"] is None

    def test_full_block_emits_version_and_chips(self):
        parsed = {
            "version": "1.7.0",
            "miner_down": False,
            "power": {"watts": 142.0, "hs_per_watt": 86.9},
            "tune": {"target": "perf", "autotune_enabled": True, "autotune_next": "Sun 03:00"},
            "health": {
                "governor": "performance",
                "throttling": False,
                "board": "ProArt X670E",
                "hugepages_total": 1280,
            },
            "watchdog": {"enabled": True, "thermal_hold": False, "temp_c": 62, "max_temp_c": 85},
        }
        disp = _rigforge_display(parsed)
        assert disp["version"] == "1.7.0"
        texts = self._chip_texts(disp)
        assert "gov: performance" in texts
        assert "HP 1280" in texts
        assert "ProArt X670E" in texts
        assert "142 W · 86.9 H/s·W" in texts
        assert "tune: perf" in texts
        assert "autotune → Sun 03:00" in texts
        assert "62°C / 85°C" in texts
        # Nothing alarming here: no bad-variant chips.
        assert all(c["variant"] != "bad" for c in disp["chips"])

        # The detail table (#507) carries the same metrics as label/value pairs, row-for-row with
        # the chips, so the two renderers can't drift.
        assert len(disp["stats"]) == len(disp["chips"])
        stats = self._stats(disp)
        assert stats["Governor"]["value"] == "performance"
        assert stats["Governor"]["variant"] == "ok"
        assert stats["HugePages"]["value"] == "1280"
        assert stats["Mainboard"]["value"] == "ProArt X670E"
        assert stats["Power / efficiency"]["value"] == "142 W · 86.9 H/s·W"
        assert stats["Tuning target"]["value"] == "perf"
        assert stats["Autotune"]["value"] == "Sun 03:00"
        assert stats["Temp / max"]["value"] == "62°C / 85°C"

    def test_stats_split_label_from_value_and_colour_warn_states(self):
        # The label/value split powers the detail table; a bad/warn metric colours its own value.
        disp = _rigforge_display(
            {
                "version": "1.7.0",
                "miner_down": True,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": "powersave",
                    "throttling": True,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False},
            }
        )
        stats = self._stats(disp)
        assert stats["Miner"]["value"] == "down" and stats["Miner"]["variant"] == "bad"
        assert stats["CPU"]["value"] == "throttling" and stats["CPU"]["variant"] == "bad"
        assert stats["Governor"]["value"] == "powersave"
        assert stats["Governor"]["variant"] == "warn"

    def test_stats_empty_when_no_metrics_present(self):
        disp = _rigforge_display(
            {
                "version": None,
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False, "thermal_hold": None, "temp_c": None},
            }
        )
        assert disp["stats"] == []

    def test_throttling_and_bad_governor_flag(self):
        disp = _rigforge_display(
            {
                "version": "1.7.0",
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": "powersave",
                    "throttling": True,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False},
            }
        )
        chips = {c["text"]: c["variant"] for c in disp["chips"]}
        assert chips["throttling"] == "bad"
        assert chips["gov: powersave"] == "warn"

    def test_nullable_fields_emit_no_chip(self):
        # No RAPL, no governor, disabled watchdog, no tune → only the fields that exist render.
        disp = _rigforge_display(
            {
                "version": None,
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False, "thermal_hold": None, "temp_c": None},
            }
        )
        assert disp["version"] is None
        assert disp["chips"] == []

    def test_miner_down_chip(self):
        disp = _rigforge_display(
            {
                "version": "1.7.0",
                "miner_down": True,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": False},
            }
        )
        assert disp["miner_down"] is True
        assert disp["chips"][0]["text"] == "miner down"
        assert disp["chips"][0]["variant"] == "bad"

    def test_thermal_hold_wins_over_temp_chip(self):
        disp = _rigforge_display(
            {
                "version": "1.7.0",
                "miner_down": False,
                "power": {"watts": None, "hs_per_watt": None},
                "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
                "health": {
                    "governor": None,
                    "throttling": None,
                    "board": None,
                    "hugepages_total": None,
                },
                "watchdog": {"enabled": True, "thermal_hold": True, "temp_c": 90, "max_temp_c": 85},
            }
        )
        texts = self._chip_texts(disp)
        assert "thermal hold" in texts
        assert not any("°C" in t for t in texts)  # the hold chip replaces the temp chip


# --- Tari -----------------------------------------------------------------------------


class TestTari:
    def test_active(self):
        t = build_tari(
            {
                "tari": {
                    "active": True,
                    "connected": True,
                    "status": "READY",
                    "reward": 12.5,
                    "height": 42,
                    "difficulty": 1234567,
                    "address": "addr",
                }
            }
        )
        assert t["active"] is True
        assert t["connected"] is True  # gates the ✔ on the client
        assert t["status"] == "READY"
        assert t["reward"] == "12.50 TARI"
        assert t["diff"] == "1,234,567"

    def test_active_but_disconnected_has_no_check(self):
        # Configured but the gRPC channel is down: active stays True (panel shows) but connected is
        # False, so the client renders the raw state with no ✔ — never "TRANSIENT_FAILURE ✔".
        t = build_tari(
            {"tari": {"active": True, "connected": False, "status": "TRANSIENT_FAILURE"}}
        )
        assert t["active"] is True
        assert t["connected"] is False
        assert t["status"] == "TRANSIENT_FAILURE"

    def test_inactive_defaults(self):
        t = build_tari({"tari": {"active": False}})
        assert t["active"] is False and t["connected"] is False and t["status"] == "Waiting..."

    def test_active_without_status_falls_back_to_waiting(self):
        # #295: effective status is derived here (not data_service). Active but the channel state is
        # absent => the "Waiting..." fallback still applies, so the panel is never blank.
        t = build_tari({"tari": {"active": True}})
        assert t["status"] == "Waiting..."

    def test_connected_requires_active(self):
        # #295: a stray connected=True while inactive must not render as connected, and an inactive
        # chain's status is always "Waiting..." regardless of any raw status it carries.
        t = build_tari({"tari": {"active": False, "connected": True, "status": "READY"}})
        assert t["connected"] is False
        assert t["status"] == "Waiting..."

    def test_long_wallet_shortened(self):
        t = build_tari({"tari": {"active": True, "address": "T" * 40}})
        assert "..." in t["wallet_short"] and t["wallet"] == "T" * 40


# --- Proxy summary (Issue #82) --------------------------------------------------------


class TestProxySummary:
    def test_formats_totals_and_best(self):
        ps = build_proxy_summary(
            {
                "proxy_summary": {
                    "accepted": 12345,
                    "rejected": 67,
                    "invalid": 2,
                    "expired": 1,
                    "best": 9876543,
                }
            }
        )
        assert ps["accepted"] == "12,345"
        assert ps["rejected"] == "67"
        assert ps["invalid"] == "2"
        assert ps["expired"] == "1"
        assert ps["best"] == "9,876,543"
        assert ps["has_data"] is True

    def test_reject_pct_and_level(self):
        # 5 rejected of 105 submitted -> ~4.76%, below the 5% highlight threshold.
        ok = build_proxy_summary({"proxy_summary": {"accepted": 100, "rejected": 5}})
        assert ok["reject_pct"] == "4.76%" and ok["reject_level"] == "ok"
        # 10 of 100 -> 10%, highlighted.
        high = build_proxy_summary({"proxy_summary": {"accepted": 90, "rejected": 10}})
        assert high["reject_pct"] == "10.00%" and high["reject_level"] == "high"

    def test_best_dash_when_unknown(self):
        assert build_proxy_summary({"proxy_summary": {"accepted": 1, "best": 0}})["best"] == "—"

    def test_empty_summary_has_no_data(self):
        ps = build_proxy_summary({})
        assert ps["has_data"] is False
        assert ps["reject_pct"] == "0.00%"
        assert ps["best"] == "—"


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


# --- pool/network passthrough ---------------------------------------------------------


class TestPoolNetwork:
    def test_formats_from_metrics_and_data(self):
        data = {
            "stratum": {
                "hashrate_15m": 0,
                "shares_found": 5,
                "shares_failed": 1,
                "wallet": "W" * 40,
            },
            "pool": {"pool": {"sidechain_height": 100}},
            "network": {"reward": 600_000_000_000, "hash": "abc", "timestamp": 0},
            "monero_sync": {"db_size": 85_000_000_000},
        }
        pn = build_pool_network(
            data,
            _metrics(
                pool_hashrate=120_000_000,
                pool_difficulty=250_000_000,
                network_difficulty=380_000_000_000,
                network_height=42,
                pplns_window=2160,
                block_time=10,
                monero_mode="Pruned",
            ),
        )
        assert pn["pool"]["hr"] == "120.00 MH/s"
        assert pn["pool"]["diff"] == "250.00 M"
        assert pn["network"]["diff"] == "380.00 G"
        assert pn["network"]["height"] == 42
        assert pn["stratum"]["shares"] == "5 / 1"
        assert pn["monero"]["mode"] == "Pruned"
        assert pn["monero"]["db_size"] == "85.0 GB"
        assert pn["shares_window"]["count"] == 5  # from _BASE metrics
        assert pn["shares_window"]["ok"] is True

    def test_db_size_dash_when_unknown(self):
        pn = build_pool_network({"monero_sync": {"db_size": 0}}, _metrics())
        assert pn["monero"]["db_size"] == "—"


# --- Pool cadence & luck (#84) ---------------------------------------------------------


class TestCadence:
    def test_formats_available_figures(self):
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

    def test_dash_fallbacks_when_unavailable(self):
        # No hashrate history / pool difficulty yet (#84 pitfall): everything reads "—", never
        # inf/0s, and available gates the card's luck + time-to-share.
        c = build_cadence(_metrics())  # _BASE leaves the cadence fields at their 0.0 defaults
        assert c["available"] is False
        assert c["since_block"] == "—"
        assert c["tts"] == "—"
        assert c["luck"] == "—"
        assert c["weight"] == "0"
        assert c["last_block"] == "Never"


# --- Host address beside the hostname (Issue #119) ------------------------------------


class TestHostDisplayAddr:
    def test_resolves_ip_for_a_hostname(self):
        with patch.object(views, "detect_host_ipv4", return_value="192.168.1.42"):
            assert host_display_addr("pithead.local") == "192.168.1.42"

    def test_none_when_host_is_already_an_ip(self):
        # Nothing to add beside a literal address — don't call detection at all.
        with patch.object(views, "detect_host_ipv4") as detect:
            assert host_display_addr("192.168.1.42") is None
            detect.assert_not_called()

    def test_none_when_ip_undetectable(self):
        with patch.object(views, "detect_host_ipv4", return_value=None):
            assert host_display_addr("pithead.local") is None

    def test_none_when_detected_ip_equals_host(self):
        with patch.object(views, "detect_host_ipv4", return_value="my-rig"):
            assert host_display_addr("my-rig") is None


# --- Earnings calculator (Issue #12) --------------------------------------------------


class TestEarnings:
    _NET = {"network": {"reward": 600_000_000_000}}  # 0.6 XMR block reward (atomic units)

    def test_publishes_rate_and_inputs(self):
        # The server sends the daily XMR-per-H/s *rate* + the raw inputs the client scales/inverts
        # (the P2Pool hashrate, P2Pool share difficulty) — not pre-formatted earnings.
        e = build_earnings(
            self._NET,
            _metrics(
                p2pool_1h=10500, network_difficulty=400_000_000_000, pool_difficulty=250_000_000
            ),
        )
        assert e["available"] is True
        assert e["p2pool_hr"] == 10500
        assert e["p2pool_hr_str"] == "10.50 kH/s"
        assert e["pool_difficulty"] == 250_000_000
        assert e["block_reward"] == "0.6000 XMR"
        # The disclaimer makes the P2Pool-only scope explicit (not XvB / not Tari).
        assert e["disclaimer"] and "P2Pool mining only" in e["disclaimer"]
        # Rate matches reward_xmr / difficulty * 86400.
        assert e["coeff_day"] == pytest.approx(0.6 / 400_000_000_000 * 86_400)

    def test_default_hashrate_is_the_displayed_p2pool_1h(self):
        # Consistency: the calculator's default must be the *same* P2Pool 1h average shown in the
        # header / Overview (metrics.p2pool_1h) — not the total, and not a bespoke total-minus-routed
        # figure. That recorded average already excludes the XvB-donated slice, so the value here
        # (and its display string) matches build_hashrate's "p2p_1h" exactly.
        m = _metrics(total_h15=46_300, xvb_routed_1h=10_000, p2pool_1h=35_000)
        e = build_earnings(self._NET, m)
        assert e["p2pool_hr"] == 35_000  # p2pool_1h, independent of total/routed
        assert (
            e["p2pool_hr_str"] == _hashrate(m)["p2p_1h"]
        )  # identical display string to the header

    def test_no_p2pool_hashrate_when_average_is_zero(self):
        # E.g. fresh start (no history) or full-XvB: p2pool_1h is 0 -> client shows 0 / "—" (honest).
        e = build_earnings(self._NET, _metrics(p2pool_1h=0))
        assert e["p2pool_hr"] == 0.0

    def test_unavailable_when_network_reward_missing(self):
        # No reward collected yet -> rate is unavailable; the card degrades to "—" (no crash).
        e = build_earnings({}, _metrics(network_difficulty=400_000_000_000))
        assert e["available"] is False
        assert e["coeff_day"] == 0.0
        assert e["block_reward"] == "0.0000 XMR"

    def test_unavailable_when_difficulty_missing(self):
        e = build_earnings(self._NET, _metrics(network_difficulty=0))
        assert e["available"] is False
        assert e["coeff_day"] == 0.0

    def test_p2pool_hr_passthrough_is_raw(self):
        # The what-if default must be the exact P2Pool H/s (not the rounded display string), so
        # the client's default estimate isn't skewed by display rounding.
        e = build_earnings(self._NET, _metrics(p2pool_1h=10543.7))
        assert e["p2pool_hr"] == 10543.7

    def test_tari_rate_published_when_merge_mining(self):
        # #117: with live Tari figures + merge-mining active, the payload carries the XTM rate
        # (reward_xtm / difficulty * 86400) for the client to scale — same shape as coeff_day.
        e = build_earnings(
            self._NET,
            _metrics(tari_mining=True, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        )
        assert e["tari_available"] is True
        assert e["tari_coeff_day"] == pytest.approx(13_000.0 / 420_000_000_000 * 86_400)
        # Solo merge-mining headline (#117 v1.3.1): the seconds-to-block-per-H/s figure (== the
        # Tari difficulty, so the client does diff / hashrate) and the full per-block reward.
        assert e["tari_difficulty"] == pytest.approx(420_000_000_000)
        assert e["tari_reward"] == pytest.approx(13_000.0)

    def test_tari_unavailable_without_figures_or_mining(self):
        # No difficulty collected (inactive/syncing) → unavailable; and a positive rate with
        # merge-mining OFF must also read unavailable (a dead channel earns no phantom XTM).
        e = build_earnings(self._NET, _metrics(tari_mining=True, tari_reward=13_000.0))
        assert e["tari_available"] is False
        assert e["tari_coeff_day"] == 0.0
        e = build_earnings(
            self._NET,
            _metrics(tari_mining=False, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        )
        assert e["tari_available"] is False

    def test_tari_unavailability_leaves_xmr_estimate_intact(self):
        # Tari degrading to "—" must not drag the XMR side down: available stays True.
        e = build_earnings(self._NET, _metrics(tari_mining=False))
        assert e["available"] is True
        assert e["coeff_day"] > 0

    def test_confirmed_disabled_by_default(self):
        # No payouts passed (feature off) → the confirmed block reports disabled; UI shows only estimate.
        e = build_earnings(self._NET, _metrics())
        assert e["confirmed"] == {"enabled": False}

    def test_confirmed_totals_windowed(self):
        # #381: 24h / 7d / all-time XMR sums from stored confirmed payouts, atomic→XMR at the edge.
        now = 1_000_000.0
        payouts = [
            {"txid": "a", "ts": now - 100, "amount_atomic": 250_000_000_000},  # in 24h
            {"txid": "b", "ts": now - 3 * 86_400, "amount_atomic": 500_000_000_000},  # in 7d
            {
                "txid": "c",
                "ts": now - 30 * 86_400,
                "amount_atomic": 1_000_000_000_000,
            },  # all-time only
        ]
        from mining_dashboard.web.views import _confirmed_payouts_summary

        s = _confirmed_payouts_summary(payouts, now=now)
        assert s["enabled"] is True and s["count"] == 3
        assert s["xmr_24h"] == pytest.approx(0.25)
        assert s["xmr_7d"] == pytest.approx(0.75)
        assert s["xmr_all"] == pytest.approx(1.75)
        assert s["last_ts"] == now - 100

    def test_confirmed_enabled_but_empty(self):
        # Feature on, nothing confirmed yet → enabled with zeroed totals (shows 0.000000, not "—").
        e = build_earnings(self._NET, _metrics(), payouts=[])
        assert e["confirmed"] == {
            "enabled": True,
            "count": 0,
            "xmr_24h": 0.0,
            "xmr_7d": 0.0,
            "xmr_all": 0.0,
            "last_ts": 0,
        }

    def test_tari_confirmed_disabled_by_default(self):
        # No tari_payouts passed (Tari feature off) → tari_confirmed reports disabled.
        e = build_earnings(self._NET, _metrics())
        assert e["tari_confirmed"] == {"enabled": False}

    def test_tari_confirmed_totals_windowed_in_xtm(self):
        # #462: XTM sums (microTari ÷1e6) with xtm_* keys, distinct from the monero xmr_* block.
        now = 1_000_000.0
        tari_payouts = [
            {"txid": "a", "ts": now - 100, "amount_atomic": 250_000},  # in 24h
            {"txid": "b", "ts": now - 3 * 86_400, "amount_atomic": 500_000},  # in 7d
            {"txid": "c", "ts": now - 30 * 86_400, "amount_atomic": 1_000_000},  # all-time only
        ]
        from mining_dashboard.web.views import MICRO_PER_XTM, _confirmed_payouts_summary

        s = _confirmed_payouts_summary(tari_payouts, now=now, divisor=MICRO_PER_XTM, unit="xtm")
        assert s["enabled"] is True and s["count"] == 3
        assert s["xtm_24h"] == pytest.approx(0.25)
        assert s["xtm_7d"] == pytest.approx(0.75)
        assert s["xtm_all"] == pytest.approx(1.75)
        assert s["last_ts"] == now - 100

    def test_tari_confirmed_enabled_but_empty(self):
        e = build_earnings(self._NET, _metrics(), tari_payouts=[])
        assert e["tari_confirmed"] == {
            "enabled": True,
            "count": 0,
            "xtm_24h": 0.0,
            "xtm_7d": 0.0,
            "xtm_all": 0.0,
            "last_ts": 0,
        }


# --- XvB tier / raffle calculator (Issue #118) -----------------------------------------


class TestXvbCalc:
    # Includes a zero-threshold entry to prove it's filtered out of the published table.
    _TIERS = {
        "donor_mega": 1_000_000,
        "donor_whale": 100_000,
        "donor_vip": 10_000,
        "donor": 1_000,
        "off": 0,
    }

    # XvB's published per-tier expected rewards, keyed by round-type == tier key (#118).
    _ESTIMATES = {"donor": 0.06, "donor_vip": 0.81, "donor_whale": 6.17, "donor_mega": 56.9}

    def _sm(self, estimates=None, last_update=None):
        sm = MagicMock()
        sm.get_tiers.return_value = self._TIERS
        est = self._ESTIMATES if estimates is None else estimates
        ts = time.time() if last_update is None else last_update
        sm.get_xvb_reward_estimates.return_value = {"estimates": est, "last_update": ts}
        return sm

    def test_disabled_returns_enabled_false_only(self):
        # XvB off → nothing to calculate; the whole payload is the single flag.
        assert build_xvb_calc(_metrics(xvb_enabled=False), self._sm()) == {"enabled": False}

    def test_tier_table_sorted_ascending_and_zero_thresholds_dropped(self):
        out = build_xvb_calc(_metrics(), self._sm())
        assert [t["threshold"] for t in out["tiers"]] == [1_000, 10_000, 100_000, 1_000_000]
        # Names come from get_tier_info, threshold already embedded — same string as everywhere.
        assert out["tiers"][1]["name"] == "Vip (10.00 kH/s+)"

    def test_mirrors_metrics_and_config(self):
        # Current/target state is passed straight through from Metrics — no tier math re-derived
        # here — and max_fraction is the configured sustainability headroom rule.
        m = _metrics(
            current_tier="Donor (1.00 kH/s+)",
            target_tier="Vip (10.00 kH/s+)",
            target_threshold=10_000.0,
            target_sustainable=False,
        )
        out = build_xvb_calc(m, self._sm())
        assert out["enabled"] is True
        assert out["current_tier"] == "Donor (1.00 kH/s+)"
        assert out["target_tier"] == "Vip (10.00 kH/s+)"
        assert out["target_threshold"] == 10_000.0
        assert out["sustainable"] is False
        assert out["max_fraction"] == views.XVB_MAX_DONATION_FRACTION
        # The labelling the issue demands: tier = raffle status, never a payout.
        assert "not an XMR payout" in out["note"]

    def test_sidechain_mode_note_only_off_main(self):
        # #33 context: off the Main sidechain, a pool switch resets PPLNS shares (and with them
        # XvB win collectability) — display-only text, absent on Main.
        assert build_xvb_calc(_metrics(pool_type="Main"), self._sm())["mode_note"] is None
        note = build_xvb_calc(_metrics(pool_type="Mini"), self._sm())["mode_note"]
        assert "PPLNS" in note

    def test_fresh_estimates_expose_per_tier_expected_reward(self):
        # #118: each tier carries XvB's own published XMR/year figure, mapped by the tier key
        # (== round-type), and the estimates_available flag is set on a fresh fetch.
        out = build_xvb_calc(_metrics(), self._sm())
        assert out["estimates_available"] is True
        assert out["estimates_stale"] is False
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == 0.06  # donor
        assert by_threshold[10_000] == 0.81  # donor_vip
        assert by_threshold[100_000] == 6.17  # donor_whale
        assert by_threshold[1_000_000] == 56.9  # donor_mega

    def test_stale_estimates_flagged_and_reward_nulled(self):
        # A stale fetch must degrade: no per-tier number implied fresh, estimates_available False.
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is True
        assert all(t["expected_reward_year"] is None for t in out["tiers"])

    def test_empty_estimates_available_false_no_crash(self):
        # Never fetched / unparseable cache: available False, not "stale" (last_update 0), rewards None.
        sm = self._sm(estimates={}, last_update=0.0)
        out = build_xvb_calc(_metrics(), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is False
        assert all(t["expected_reward_year"] is None for t in out["tiers"])


# --- build_state integration ----------------------------------------------------------


# ponytail: this _state_mgr()/_data() pair looks near-duplicated with the ones in test_metrics.py,
# but the per-module defaults differ on purpose (e.g. tari_sync, the get_tiers/xvb shapes). A shared
# builder would need enough params that it reads worse than the local copy — left duplicated.
def _state_mgr(history=None, mode="P2POOL", share_stats=None):
    sm = MagicMock()
    sm.get_history.return_value = history or []
    sm.get_xvb_stats.return_value = {"current_mode": mode}
    sm.get_tiers.return_value = {}
    sm.get_xvb_reward_estimates.return_value = {"estimates": {}, "last_update": 0.0}
    sm.get_share_stats.return_value = share_stats or []
    sm.get_raffle_wins.return_value = []
    sm.is_db_healthy.return_value = True
    return sm


def _data(**over):
    data = {
        "shares": [],
        "workers": [],
        "global_sync": False,
        "total_live_h15": 0,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 50, "current": 5, "target": 10},
    }
    data.update(over)
    return data


class TestBuildState:
    def test_has_all_sections(self):
        st = build_state(_data(), _state_mgr(), "all")
        for key in (
            "syncing",
            "page_title",
            "host_ip",
            "host_addr",
            "version",
            "last_update",
            "range",
            "window",
            "badges",
            "hashrate",
            "system",
            "sync",
            "stratum",
            "pool",
            "network",
            "monero",
            "shares_window",
            "cadence",
            "proxy_workers",
            "earnings",
            "xvb_calc",
            "tari",
            "workers",
            "proxy_summary",
            "share_stats",
            "reject_pct_24h",
            "egress",
            "topology",
            "chart",
        ):
            assert key in st, f"missing section: {key}"

    def test_version_section_shape(self):
        # The header version badge (Issue #58) is part of the shared payload, so it rides on both
        # the syncing and main screens. Shape only — resolution rules live in tests/test_version.py.
        v = build_state(_data(), _state_mgr(), "all")["version"]
        assert set(v) == {"text", "title", "dev"}
        assert isinstance(v["text"], str) and v["text"]
        assert isinstance(v["dev"], bool)

    def test_update_section_surfaced_and_defaults_none(self):
        # The new-release badge (#224) rides on the shared payload; a genuinely-newer result
        # passes through, and absence defaults to None (no badge).
        upd = {"available": True, "latest": "v9.9.9", "url": "https://x/releases/tag/v9.9.9"}
        assert build_state(_data(update=upd), _state_mgr(), "all")["update"] == upd
        assert build_state(_data(), _state_mgr(), "all")["update"] is None

    def test_update_badge_never_advertises_the_running_version(self, monkeypatch):
        # #664: a restored snapshot can resurrect a pre-upgrade badge right after the upgrade it
        # advertised — "new release X available" while RUNNING X must be unrepresentable at the
        # render seam, whatever put it in the state.
        monkeypatch.setattr(
            "mining_dashboard.web.views.resolve_version",
            lambda: {"text": "v1.9.1", "title": "Release build", "dev": False},
        )
        stale = {"available": True, "latest": "v1.9.1", "url": "https://x/releases/tag/v1.9.1"}
        assert build_state(_data(update=stale), _state_mgr(), "all")["update"] is None
        older = {"available": True, "latest": "v1.8.0", "url": "https://x/releases/tag/v1.8.0"}
        assert build_state(_data(update=older), _state_mgr(), "all")["update"] is None
        newer = {"available": True, "latest": "v2.0.0", "url": "https://x/releases/tag/v2.0.0"}
        assert build_state(_data(update=newer), _state_mgr(), "all")["update"] == newer


class TestVisibleUpdate:
    """#664: the pure self-consistency guard on the new-release badge."""

    UPD = {"available": True, "latest": "v1.9.1", "url": "https://x/releases/tag/v1.9.1"}

    def test_suppressed_when_latest_equals_running(self):
        assert visible_update(self.UPD, running="v1.9.1") is None
        assert visible_update(self.UPD, running="1.9.1") is None  # bare VERSION form too

    def test_suppressed_when_latest_is_older_than_running(self):
        assert visible_update(self.UPD, running="v1.10.0") is None

    def test_kept_when_latest_is_newer(self):
        assert visible_update(self.UPD, running="v1.9.0") == self.UPD

    def test_dev_build_keeps_the_badge(self):
        # An unparseable running version (dev build) cannot prove the badge stale — keep it,
        # mirroring compute_update's own semantics.
        assert visible_update(self.UPD, running="pithead@main abc1234 (dev)") == self.UPD

    def test_none_and_malformed_latest_pass_through(self):
        assert visible_update(None, running="v1.9.1") is None
        odd = {"available": True, "latest": "nightly", "url": "u"}
        assert visible_update(odd, running="v1.9.1") == odd  # unprovable -> unchanged

    def test_is_json_serializable(self):
        json.dumps(build_state(_data(), _state_mgr(), "all"))

    def test_share_stats_series_and_24h_rate_surfaced(self):
        # #116: the persisted delta series rides on /api/state with a trailing-24h reject rate;
        # proxy_summary keeps its cumulative shape untouched.
        rows = [{"ts": time.time() - 60, "accepted": 95, "rejected": 5, "invalid": 0, "expired": 0}]
        st = build_state(_data(), _state_mgr(share_stats=rows), "all")
        assert st["share_stats"][0]["a"] == 95 and st["share_stats"][0]["r"] == 5
        assert st["reject_pct_24h"] == "5.00%"
        assert "reject_pct_24h" not in st["proxy_summary"]
        # No rows (fresh install / proxy idle) -> empty series and an honest dash.
        empty = build_state(_data(), _state_mgr(), "all")
        assert empty["share_stats"] == [] and empty["reject_pct_24h"] == "—"

    def test_db_unhealthy_surfaces_field_and_badge(self):
        # When persistence is broken, /api/state must carry db_healthy=False and a loud badge (#131).
        sm = _state_mgr()
        sm.is_db_healthy.return_value = False
        st = build_state(_data(), sm, "all")
        assert st["db_healthy"] is False
        assert any("DB write failing" in b["text"] for b in st["badges"])

    def test_db_healthy_no_badge(self):
        st = build_state(_data(), _state_mgr(), "all")
        assert st["db_healthy"] is True
        assert not any("DB write failing" in b["text"] for b in st["badges"])

    def test_range_echoed(self):
        assert build_state(_data(), _state_mgr(), "24h")["range"] == "24h"

    def test_window_null_on_preset(self):
        assert build_state(_data(), _state_mgr(), "24h")["window"] is None

    def test_last_update_reflects_snapshot_timestamp_not_now(self):
        # #559: a restored stale snapshot (dashboard was down) must report its own age, not the
        # current time -- otherwise stale workers/hashrate read as "just now" until the first
        # post-restart collection cycle completes.
        old_ts = time.time() - 6 * 3600
        st = build_state(_data(timestamp=old_ts), _state_mgr(), "all")
        assert st["last_update"] == views.format_time_abs(old_ts)
        assert st["last_update"] != views.format_time_abs(time.time())

    def test_last_update_falls_back_to_now_when_timestamp_missing(self):
        # No "timestamp" key (or the pre-first-collection default of 0) -> fall back to now
        # rather than showing "Never".
        with patch("mining_dashboard.web.views.time.time", return_value=12345.0):
            assert build_state(_data(), _state_mgr(), "all")["last_update"] == (
                views.format_time_abs(12345.0)
            )
            assert build_state(_data(timestamp=0), _state_mgr(), "all")["last_update"] == (
                views.format_time_abs(12345.0)
            )

    def test_window_echoed_when_zoomed(self):
        # A custom zoom window is echoed so the client can render Reset / re-request on refresh.
        st = build_state(_data(), _state_mgr(), "all", window=(1000.0, 2000.0))
        assert st["window"] == {"from": 1000.0, "to": 2000.0}

    def test_syncing_flag_and_title(self):
        st = build_state(_data(global_sync=True), _state_mgr(), "all")
        assert st["syncing"] is True
        assert st["page_title"] == "Pithead Dashboard - Syncing"

    def test_proxy_workers_from_metrics(self):
        data = _data(
            workers=[
                {"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"},
                {"name": "b", "ip": "1.1.1.2", "status": "offline", "active_pool": "3333"},
            ]
        )
        assert build_state(data, _state_mgr(), "all")["proxy_workers"] == 1

    def test_chart_uses_timestamps(self):
        history = [
            {"timestamp": 100, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},
            {"timestamp": 160, "v": 600, "v_p2pool": 300, "v_xvb": 300, "t": "b"},
        ]
        chart = build_state(_data(), _state_mgr(history=history), "all")["chart"]
        assert chart["p2pool"] == [{"x": 100_000, "y": 500}, {"x": 160_000, "y": 300}]
        assert chart["xvb"][1] == {"x": 160_000, "y": 300}

    def test_propagates_state_errors(self):
        bad_sm = MagicMock()
        bad_sm.get_history.side_effect = RuntimeError("boom")
        with pytest.raises(RuntimeError):
            build_state(_data(), bad_sm, "all")


def _set_egress_config(monkeypatch, **over):
    """Pin the live egress knobs so the #170 panel is deterministic regardless of the test env.

    Defaults are the privacy-safe resting config (firewall on, everything over Tor, local node);
    pass overrides to model a leak. ``egress_posture_from_config`` / ``topology_from_config`` read
    these off the config module at call time, so patching them steers ``build_state``'s payload.
    """
    safe = {
        "TOR_EGRESS_FIREWALL": True,
        "P2POOL_CLEARNET": False,
        "ENABLE_XVB": True,
        "XVB_TOR_ENABLED": True,
        "MONERO_CLEARNET_SYNC": False,
        "TARI_CLEARNET_SYNC": False,
        "MONERO_NODE_HOST": "127.0.0.1",
        "LOCAL_MONERO_HOST": "127.0.0.1",
    }
    for name, value in {**safe, **over}.items():
        monkeypatch.setattr(egress_config, name, value)


class TestEgressTopology:
    """The #170 egress posture + topology ride on /api/state and feed the header badge. These
    cover the *wiring* (build_state → payload → badge); the derivation itself is unit-tested in
    tests/service/test_egress.py."""

    def test_both_sections_present_and_share_one_summary(self, monkeypatch):
        _set_egress_config(monkeypatch)
        st = build_state(_data(), _state_mgr(), "all")
        assert st["egress"]["components"]
        assert st["topology"]["nodes"] and st["topology"]["edges"]
        # The badge can never contradict the map: identical summary in both sections.
        assert st["topology"]["summary"] == st["egress"]["summary"]

    def test_safe_config_emits_a_tor_only_header_badge(self, monkeypatch):
        _set_egress_config(monkeypatch)
        st = build_state(_data(), _state_mgr(), "all")
        badge = st["badges"][-1]  # _egress_badge is appended last in build_state
        assert badge["variant"] == "ok"
        assert "Tor-only" in badge["text"]
        assert st["egress"]["summary"]["all_tor"] is True

    def test_host_dashboard_clearnet_leak_emits_a_warning_badge(self, monkeypatch):
        # The host-networked dashboard's XvB stats fetch over clearnet leaks despite the firewall —
        # the payload must flip the badge to a loud warning and the topology summary to "warn".
        _set_egress_config(monkeypatch, XVB_TOR_ENABLED=False)
        st = build_state(_data(), _state_mgr(), "all")
        badge = st["badges"][-1]
        assert badge["variant"] == "bad"
        assert "clearnet egress" in badge["text"]
        assert st["topology"]["summary"]["level"] == "warn"
        assert st["egress"]["summary"]["leaks"] >= 1

    def test_remote_monerod_is_reflected_in_the_payload(self, monkeypatch):
        # A remote (non-local) monerod RPC host is a clearnet hop; with the firewall on it's blocked,
        # not leaked, so the badge stays green but the blocked count rises — end to end.
        _set_egress_config(monkeypatch, MONERO_NODE_HOST="10.0.0.9", LOCAL_MONERO_HOST="127.0.0.1")
        st = build_state(_data(), _state_mgr(), "all")
        assert st["egress"]["summary"]["all_tor"] is True
        assert st["egress"]["summary"]["blocked_by_firewall"] >= 1
        assert any(
            e["from"] == "p2pool" and e["to"] == "monerod" and e["route"] == "clearnet"
            for e in st["topology"]["edges"]
        )

    def test_payload_stays_json_serializable_with_a_leak(self, monkeypatch):
        _set_egress_config(monkeypatch, XVB_TOR_ENABLED=False, P2POOL_CLEARNET=True)
        json.dumps(build_state(_data(), _state_mgr(), "all"))


class TestParseWindow:
    def test_valid_pair(self):
        assert parse_window("1000", "2000") == (1000.0, 2000.0)

    def test_absent_is_none(self):
        assert parse_window(None, None) is None
        assert parse_window("1000", None) is None

    @pytest.mark.parametrize(
        "frm,to",
        [
            ("bad", "2000"),  # non-numeric
            ("2000", "1000"),  # from >= to
            ("1000", "1000"),  # zero-width
            ("-5", "2000"),  # non-positive
            ("nan", "2000"),  # not finite
            ("inf", "2000"),
        ],
    )
    def test_malformed_falls_back_to_none(self, frm, to):
        assert parse_window(frm, to) is None


class TestShell:
    def test_returns_html_referencing_module(self):
        shell = get_shell_html()
        assert "<!DOCTYPE html>" in shell
        assert "/static/dashboard.js" in shell
        assert 'id="app"' in shell

    def test_error_fallback(self, monkeypatch):
        views._SHELL_CACHE = None
        monkeypatch.setattr(views.os.path, "getmtime", lambda p: (_ for _ in ()).throw(OSError()))
        assert get_shell_html() == "<h1>Dashboard shell error</h1>"


class TestRaffleEligible:
    """Raffle-eligibility (#158): Yes only with a donor-tier credited donation AND a PPLNS share."""

    def test_yes_when_in_tier_and_has_share(self):
        m = _metrics(xvb_enabled=True, current_tier="Donor (1.00 kH/s+)", shares_in_window=5)
        assert build_raffle_eligibility(m) == {"applies": True, "eligible": True, "label": "Yes"}

    def test_no_when_below_tier_even_with_a_share(self):
        # Has a PPLNS share but credited donation hasn't cleared the lowest tier (current_tier "None").
        m = _metrics(xvb_enabled=True, current_tier="None", shares_in_window=5)
        assert build_raffle_eligibility(m) == {"applies": True, "eligible": False, "label": "No"}

    def test_no_when_in_tier_but_no_share(self):
        m = _metrics(xvb_enabled=True, current_tier="Donor (1.00 kH/s+)", shares_in_window=0)
        assert build_raffle_eligibility(m) == {"applies": True, "eligible": False, "label": "No"}

    def test_na_when_xvb_off(self):
        m = _metrics(xvb_enabled=False, current_tier="Donor (1.00 kH/s+)", shares_in_window=5)
        assert build_raffle_eligibility(m) == {
            "applies": False,
            "eligible": False,
            "label": "N/A (XvB off)",
        }


class TestChartEvents:
    """Degradation/recovery markers (#99) flow through build_chart's new `events` kwarg: shaped as
    xy points on the hidden 0-1 event axis, carrying kind+label, and window-filtered like history."""

    def _hist(self, now):
        return [{"timestamp": now, "v": 800, "v_p2pool": 800, "v_xvb": 0, "t": "a"}]

    def test_absent_events_default_to_empty(self):
        now = time.time()
        assert build_chart(self._hist(now), [], "all")["events"] == []

    def test_event_point_shape(self):
        now = time.time()
        events = [{"ts": now, "type": "loss", "detail": "-62%"}]
        pt = build_chart(self._hist(now), [], "all", events=events)["events"]
        assert pt == [
            {"x": int(now * 1000), "y": views._EVENT_MARKER_Y, "kind": "loss", "label": "-62%"}
        ]

    def test_label_falls_back_to_type(self):
        now = time.time()
        events = [{"ts": now, "type": "recovered", "detail": ""}]
        assert build_chart(self._hist(now), [], "all", events=events)["events"][0]["label"] == (
            "recovered"
        )

    def test_events_filtered_by_range(self):
        now = time.time()
        events = [
            {"ts": now - 7200, "type": "loss", "detail": "old"},  # 2h ago
            {"ts": now - 60, "type": "recovered", "detail": "recent"},
        ]
        labels = [
            e["label"] for e in build_chart(self._hist(now), [], "1h", events=events)["events"]
        ]
        assert labels == ["recent"]  # the 2h-old marker is outside the 1h window


class TestChartRaffle:
    """XvB raffle-win markers flow through build_chart's `raffle_wins` kwarg: gold-star points on
    the hidden 0-1 event axis, tooltip carrying tier + credited rate, window-filtered like events."""

    def _hist(self, now):
        return [{"timestamp": now, "v": 800, "v_p2pool": 800, "v_xvb": 0, "t": "a"}]

    def _win(self, ts):
        return {"ts": ts, "hashrate": 4.2e6, "height": 100, "block_id": "aa11", "tier": "donor"}

    def test_absent_wins_default_to_empty(self):
        now = time.time()
        assert build_chart(self._hist(now), [], "all")["raffle"] == []

    def test_raffle_point_shape(self):
        now = time.time()
        pt = build_chart(self._hist(now), [], "all", raffle_wins=[self._win(now)])["raffle"]
        assert pt == [
            {
                "x": int(now * 1000),
                "y": views._RAFFLE_MARKER_Y,
                "label": "XvB raffle win — donor round at 4.20 MH/s",
            }
        ]

    def test_wins_filtered_by_range(self):
        now = time.time()
        wins = [self._win(now - 7200), self._win(now - 60)]
        pts = build_chart(self._hist(now), [], "1h", raffle_wins=wins)["raffle"]
        assert len(pts) == 1  # the 2h-old win is outside the 1h window


class TestBuildRaffleLog:
    """The XvB card's raffle-wins log: newest first, display-formatted, capped at 20 rows."""

    def _win(self, ts, tier="donor"):
        return {"ts": ts, "hashrate": 4.2e6, "height": int(ts), "block_id": f"b{ts}", "tier": tier}

    def test_formats_newest_first(self):
        rows = views.build_raffle_log([self._win(1000.0), self._win(2000.0, "donor_whale")])
        assert [r["tier"] for r in rows] == ["donor_whale", "donor"]  # storage is oldest-first
        assert rows[0]["hashrate"] == "4.20 MH/s"
        assert rows[0]["height"] == 2000
        assert rows[0]["time"]  # display-formatted timestamp, non-empty

    def test_capped_at_limit(self):
        rows = views.build_raffle_log([self._win(float(i)) for i in range(30)])
        assert len(rows) == views._RAFFLE_LOG_LIMIT
        assert rows[0]["height"] == 29  # newest kept, oldest dropped

    def test_empty_is_empty(self):
        assert views.build_raffle_log([]) == []


class TestBuildEnergy:
    """Fleet energy totals for the Energy tab (#260). Sums measured watts (RigForge feed) with the
    operator's per-worker `watts` fallback, excludes workers with neither (marking the total
    incomplete), and publishes the operator-set prices for the client to turn into cost/net."""

    def _worker(self, name, watts=None, hs=1000, active_pool="3333"):
        rf = {"power": {"watts": watts, "hs_per_watt": None}} if watts is not None else None
        return {
            "name": name,
            "ip": "1.1.1.1",
            "status": "online",
            "active_pool": active_pool,
            "h60": hs,
            "rigforge": rf,
        }

    def _energy(self, monkeypatch, workers, energy=None, descriptors=None, prices=None):
        from mining_dashboard.web import views

        monkeypatch.setattr(
            views.config,
            "DASHBOARD_ENERGY",
            {
                "cost_per_kwh": 0.0,
                "xmr_price": 0.0,
                "tari_price": 0.0,
                "currency": "USD",
                "price_feed": False,
                **(energy or {}),
            },
        )
        monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", descriptors or [])
        return build_energy(workers, prices)

    def test_no_power_anywhere_is_unavailable(self, monkeypatch):
        got = self._energy(monkeypatch, [self._worker("r1"), self._worker("r2")])
        assert got["available"] is False
        assert got["total_watts"] is None
        assert got["incomplete"] is True

    def test_measured_watts_sum_and_efficiency(self, monkeypatch):
        got = self._energy(
            monkeypatch,
            [self._worker("r1", watts=100, hs=2000), self._worker("r2", watts=50, hs=1000)],
        )
        assert got["available"] is True
        assert got["total_watts"] == 150.0
        assert got["incomplete"] is False
        assert got["hs_per_watt"] == 20.0  # 3000 H/s / 150 W

    def test_config_watts_fallback_marked_estimated(self, monkeypatch):
        # r2 reports no measured watts but has a configured estimate — counted, flagged estimated.
        got = self._energy(
            monkeypatch,
            [self._worker("r1", watts=100), self._worker("r2")],
            descriptors=[{"name": "r2", "watts": 60}],
        )
        assert got["total_watts"] == 160.0
        assert got["incomplete"] is False
        by_name = {w["name"]: w for w in got["per_worker"]}
        assert by_name["r1"]["estimated"] is False
        assert by_name["r2"]["estimated"] is True

    def test_worker_with_no_power_and_no_estimate_excluded_but_counted_incomplete(
        self, monkeypatch
    ):
        got = self._energy(monkeypatch, [self._worker("r1", watts=100), self._worker("dark")])
        assert got["total_watts"] == 100.0  # dark excluded
        assert got["incomplete"] is True

    def test_prices_pass_through(self, monkeypatch):
        got = self._energy(
            monkeypatch,
            [self._worker("r1", watts=100)],
            energy={
                "cost_per_kwh": 0.2,
                "xmr_price": 150.0,
                "tari_price": 2.5,
                "currency": "EUR",
            },
        )
        assert got["cost_per_kwh"] == 0.2
        assert got["xmr_price"] == 150.0
        assert got["tari_price"] == 2.5
        assert got["currency"] == "EUR"
        # Static config prices: the calculator says so (#520 — a fiat figure is never unattributed).
        assert got["price_source"] == {"feed": False, "live": False, "age_sec": None}

    def test_live_feed_prices_replace_static(self, monkeypatch):
        # Feed on + a fetch landed: live prices stand in for the static numbers, with their age.
        now = time.time()
        got = self._energy(
            monkeypatch,
            [self._worker("r1", watts=100)],
            energy={"xmr_price": 150.0, "tari_price": 2.5, "price_feed": True},
            prices={"xmr": 333.97, "tari": 0.0004, "currency": "USD", "fetched_at": now - 60},
        )
        assert got["xmr_price"] == 333.97
        assert got["tari_price"] == 0.0004
        assert got["price_source"]["feed"] is True
        assert got["price_source"]["live"] is True
        assert 59 <= got["price_source"]["age_sec"] <= 62

    def test_feed_waiting_falls_back_to_static(self, monkeypatch):
        # Feed on but no fetch yet (Tor down / first minutes): static prices stand, honestly labeled.
        got = self._energy(
            monkeypatch,
            [self._worker("r1", watts=100)],
            energy={"xmr_price": 150.0, "price_feed": True},
            prices=None,
        )
        assert got["xmr_price"] == 150.0
        assert got["price_source"] == {"feed": True, "live": False, "age_sec": None}

    def test_feed_off_ignores_stray_prices(self, monkeypatch):
        # A prices payload with the feed off must not override the operator's static numbers.
        got = self._energy(
            monkeypatch,
            [self._worker("r1", watts=100)],
            energy={"xmr_price": 150.0},
            prices={"xmr": 333.97, "tari": 0.0004, "currency": "USD", "fetched_at": time.time()},
        )
        assert got["xmr_price"] == 150.0
        assert got["price_source"]["live"] is False


class TestBuildWorkerDetail:
    """Per-worker Inspect payload (#185): current telemetry + last-applied prefill + history."""

    def _detail(self, monkeypatch, name, workers=None, descriptors=None):
        from mining_dashboard.web import views

        monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", descriptors or [])
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        try:
            return build_worker_detail(name, {"workers": workers or []}, sm), sm
        finally:
            pass

    def test_editable_when_operator_set_host(self, monkeypatch):
        d, sm = self._detail(
            monkeypatch,
            "rig1",
            workers=[{"name": "rig1", "status": "online", "h60": 5100, "rigforge": None}],
            descriptors=[{"name": "rig1", "host": "10.0.0.9", "control_port": 8082}],
        )
        sm.close()
        assert d["found"] is True and d["editable"] is True
        assert "DONATION" in d["writable_keys"]

    def test_not_editable_without_host(self, monkeypatch):
        # A worker with no operator-set host can't be a write target (SSRF safety, #122).
        d, sm = self._detail(
            monkeypatch,
            "rig1",
            workers=[{"name": "rig1", "status": "online", "h60": 0}],
            descriptors=[{"name": "rig1", "port": 8081}],
        )
        sm.close()
        assert d["editable"] is False

    def test_not_found_worker_absent_from_snapshot(self, monkeypatch):
        d, sm = self._detail(monkeypatch, "ghost", workers=[])
        sm.close()
        assert d["found"] is False and d["editable"] is False
        assert d["history"] == []

    def test_history_and_last_applied_from_db(self, monkeypatch):
        d, sm = self._detail(
            monkeypatch,
            "rig1",
            workers=[{"name": "rig1", "status": "online", "h60": 0}],
            descriptors=[{"name": "rig1", "host": "10.0.0.9"}],
        )
        sm.add_worker_config_version("rig1", "cid1", "applied", {"DONATION": 2}, None, ts=1000.0)
        sm.add_worker_config_version(
            "rig1", "cid2", "rejected", {"max_temp_c": 999}, "bad", ts=2000.0
        )
        d = build_worker_detail("rig1", {"workers": [{"name": "rig1", "status": "online"}]}, sm)
        sm.close()
        assert [h["status"] for h in d["history"]] == ["rejected", "applied"]  # newest first
        assert d["history"][0]["applied_at"]  # formatted timestamp present
        assert d["last_applied"] == {"DONATION": 2}  # only the applied change prefills

    def test_hashrate_by_config_correlates_samples_to_versions(self, monkeypatch):
        # #492: worker_history samples aggregated per applied worker_config version.
        d, sm = self._detail(
            monkeypatch,
            "rig1",
            workers=[{"name": "rig1", "status": "online", "h60": 0}],
            descriptors=[{"name": "rig1", "host": "10.0.0.9"}],
        )
        sm.add_worker_config_version("rig1", "cid1", "applied", {"DONATION": 2}, None, ts=100.0)
        sm.add_worker_history(
            [{"ts": 150.0, "name": "rig1", "h15": 1000.0, "accepted": 0, "rejected": 0}]
        )
        d = build_worker_detail("rig1", {"workers": [{"name": "rig1", "status": "online"}]}, sm)
        sm.close()
        assert len(d["hashrate_by_config"]) == 1
        row = d["hashrate_by_config"][0]
        assert row["change_id"] == "cid1"
        assert row["applied_at"]  # formatted timestamp present
        assert row["avg_h15"] == "1.00 kH/s"  # human-formatted, matching detail["hashrate"]
        assert row["sample_count"] == 1

    def test_hashrate_by_config_empty_with_no_applied_versions(self, monkeypatch):
        d, sm = self._detail(
            monkeypatch,
            "rig1",
            workers=[{"name": "rig1", "status": "online", "h60": 0}],
            descriptors=[{"name": "rig1", "host": "10.0.0.9"}],
        )
        sm.close()
        assert d["hashrate_by_config"] == []
