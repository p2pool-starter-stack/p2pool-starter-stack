"""Unit tests for the chart/window hub (mining_dashboard/web/charts.py).

Moved verbatim out of tests/web/test_views.py with the hub itself (#1105); the only edit is the
module alias on the four marker-constant reads, which follow their constants.
"""

import time

import pytest

import mining_dashboard.web.charts as charts
from mining_dashboard.web.charts import (
    _chart_tension,
    _target_points,
    build_chart,
    parse_window,
)


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
            "payouts": [],
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
            {"x": int(now * 1000), "y": charts._EVENT_MARKER_Y, "kind": "loss", "label": "-62%"}
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
                "y": charts._RAFFLE_MARKER_Y,
                "label": "XvB raffle win — donor round at 4.20 MH/s",
            }
        ]

    def test_wins_filtered_by_range(self):
        now = time.time()
        wins = [self._win(now - 7200), self._win(now - 60)]
        pts = build_chart(self._hist(now), [], "1h", raffle_wins=wins)["raffle"]
        assert len(pts) == 1  # the 2h-old win is outside the 1h window


class TestChartPayouts:
    """Confirmed on-chain payout markers (#381) flow through build_chart's `payouts` kwarg: gold
    coins on the hidden 0-1 axis below the raffle stars, tooltip carrying the whole-XMR amount,
    range-filtered like events, and capped at the most-recent by _payout_points."""

    def _hist(self, now):
        return [{"timestamp": now, "v": 800, "v_p2pool": 800, "v_xvb": 0, "t": "a"}]

    def _payout(self, ts, atomic=1_500_000_000_000):  # 1.5 XMR in piconero
        return {"chain": "monero", "txid": "aa", "height": 100, "ts": ts, "amount_atomic": atomic}

    def test_absent_payouts_default_to_empty(self):
        # Feature off (build_state passes payouts=None) → empty marker list, estimate stands alone.
        now = time.time()
        assert build_chart(self._hist(now), [], "all")["payouts"] == []
        assert build_chart(self._hist(now), [], "all", payouts=None)["payouts"] == []

    def test_payout_point_shape_carries_formatted_amount(self):
        now = time.time()
        pt = build_chart(self._hist(now), [], "all", payouts=[self._payout(now)])["payouts"]
        assert len(pt) == 1
        assert pt[0]["x"] == int(now * 1000)
        assert pt[0]["y"] == charts._PAYOUT_MARKER_Y
        # The label carries the whole-XMR amount (atomic→XMR at the edge) — the load-bearing bit.
        assert pt[0]["label"].startswith("1.500000 XMR — ")

    def test_payouts_filtered_by_range(self):
        now = time.time()
        payouts = [self._payout(now - 7200), self._payout(now - 60)]
        pts = build_chart(self._hist(now), [], "1h", payouts=payouts)["payouts"]
        assert len(pts) == 1  # the 2h-old payout is outside the 1h window

    def test_markers_capped_at_most_recent(self):
        # More than the cap → only the newest _PAYOUT_MARKER_LIMIT are kept (never silently all,
        # and the NEWEST — not the oldest — survive). Input is newest-first (storage.get_payouts).
        now = time.time()
        limit = charts._PAYOUT_MARKER_LIMIT
        payouts = [self._payout(now - i) for i in range(limit + 5)]  # [0]=newest … [-1]=oldest
        pts = build_chart(self._hist(now), [], "all", payouts=payouts)["payouts"]
        assert len(pts) == limit
        kept_x = {p["x"] for p in pts}
        # The newest survives and the oldest 5 (beyond the cap) are the ones dropped.
        assert pts[0]["x"] == int(now * 1000)  # newest kept, first
        assert pts[-1]["x"] == int((now - (limit - 1)) * 1000)  # limit-th newest kept, last
        assert int((now - limit) * 1000) not in kept_x  # first over the cap → dropped
        assert int((now - (limit + 4)) * 1000) not in kept_x  # oldest → dropped
