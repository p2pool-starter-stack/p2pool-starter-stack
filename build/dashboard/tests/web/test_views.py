"""Unit tests for the dashboard view/presentation layer (mining_dashboard/web/views.py).

The view layer formats the computed :class:`Metrics` (and a little passthrough from the raw
snapshot) into the structured ``/api/state`` payload the Preact client renders. Domain logic is
tested in tests/service/test_metrics.py; here we test the *display* mapping (formatting +
presentation tokens), the chart series (Issue #65), and the full ``build_state`` contract.
"""
import json
import time
from dataclasses import replace
from unittest.mock import MagicMock

import pytest

import mining_dashboard.web.views as views
from mining_dashboard.web.views import (
    build_chart, build_hashrate, build_pool_network, build_workers, build_tari,
    build_system, build_sync, build_badges, build_earnings, build_state, get_shell_html,
    _mode_palette, parse_window, _target_points, _chart_tension,
    build_proxy_summary, _reject_flag,
)
from mining_dashboard.service.metrics import Metrics, SyncMetric


# --- Metrics fixtures for the presentation builders -----------------------------------

_SYNC_DONE = SyncMetric(percent=100, current=10, target=10, remaining=0,
                        has_target=True, done=True, down=False)

_BASE = Metrics(
    total_h15=10500.0, p2pool_1h=8000.0, p2pool_24h=8100.0, xvb_1h=2100.0, xvb_24h=2300.0,
    xvb_routed=2000.0,
    stratum_h15=10300.0, stratum_h1h=10400.0, stratum_h24h=10200.0,
    mode="P2POOL", xvb_enabled=True, current_tier="Donor (1.00 kH/s+)",
    target_tier="Donor (1.00 kH/s+)", target_threshold=1000.0, target_sustainable=True,
    low_hr_warning=False, xvb_fail_count=0, xvb_last_update=0,
    workers_online=2, workers_total=3, shares_in_window=5, pplns_window=2160, block_time=10,
    pool_type="Mini", pool_hashrate=120_000_000.0, pool_difficulty=250_000_000.0,
    network_difficulty=380_000_000_000.0, network_height=3210001,
    global_syncing=False, monero=_SYNC_DONE, tari=_SYNC_DONE, monero_mode="Unknown",
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
        return [{"timestamp": start_ts + i * step, "v": 100 + i, "v_p2pool": 100 + i,
                 "v_xvb": 0, "t": "x"} for i in range(n)]

    def test_point_shape_is_xy_with_epoch_ms(self):
        chart = build_chart([{"timestamp": 1000, "v": 800, "v_p2pool": 500, "v_xvb": 300, "t": "a"}],
                            [], "all")
        assert chart["p2pool"] == [{"x": 1_000_000, "y": 500}]
        assert chart["xvb"] == [{"x": 1_000_000, "y": 300}]

    def test_legacy_rows_attributed_to_p2pool(self):
        chart = build_chart([{"timestamp": 1, "v": 800, "v_p2pool": 0, "v_xvb": 0, "t": "a"}], [], "all")
        assert chart["p2pool"][0]["y"] == 800
        assert chart["xvb"][0]["y"] == 0

    def test_range_filtering(self):
        now = time.time()
        history = [{"timestamp": now - 7200, "v": 1, "v_p2pool": 1, "v_xvb": 0, "t": "x"},
                   {"timestamp": now - 60, "v": 2, "v_p2pool": 2, "v_xvb": 0, "t": "x"}]
        chart = build_chart(history, [], "1h")
        assert len(chart["p2pool"]) == 1   # the 2h-old point is dropped

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
        hist += [{"timestamp": t + i * 30, "v": 200, "v_p2pool": 200, "v_xvb": 0, "t": "x"} for i in range(5)]
        chart = build_chart(hist, [], "all")
        nulls = [p for p in chart["p2pool"] if p["y"] is None]
        assert len(nulls) == 1                                  # exactly one break, in the gap
        xs = [p["x"] for p in chart["p2pool"]]
        assert xs == sorted(xs)                                 # still chronological
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
        hist += [{"timestamp": t + i * 30, "v": 200, "v_p2pool": 200, "v_xvb": 0, "t": "x"} for i in range(5)]
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
        hist = self._line(1000, now - 100000, step=30)            # dense, will downsample
        gap_start = hist[-1]["timestamp"] + 6 * 3600              # 6h outage
        hist += self._line(1000, gap_start, step=30)
        chart = build_chart(hist, [], "all")
        assert any(p["y"] is None for p in chart["p2pool"])

    def test_single_point_no_break(self):
        chart = build_chart([{"timestamp": 1, "v": 5, "v_p2pool": 5, "v_xvb": 0, "t": "a"}], [], "all")
        assert len(chart["p2pool"]) == 1

    def test_share_points_sparse_and_lifted(self):
        history = [
            {"timestamp": 1000, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},
            {"timestamp": 1030, "v": 600, "v_p2pool": 600, "v_xvb": 0, "t": "b"},
        ]
        shares = [{"ts": 1001}, {"ts": 1029}]   # one near each sample
        pts = build_chart(history, shares, "all")["shares"]
        assert pts == [
            {"x": 1_000_000, "y": 550.0, "r": 9, "c": 1},   # 500 * 1.1, radius 6+3
            {"x": 1_030_000, "y": 660.0, "r": 9, "c": 1},
        ]

    def test_share_offset_floor_when_value_zero(self):
        pts = build_chart([{"timestamp": 1000, "v": 0, "v_p2pool": 0, "v_xvb": 0, "t": "a"}],
                          [{"ts": 1000}], "all")["shares"]
        assert pts == [{"x": 1_000_000, "y": 100, "r": 9, "c": 1}]

    def test_no_shares_no_points(self):
        assert build_chart([{"timestamp": 1, "v": 5, "v_p2pool": 5, "v_xvb": 0, "t": "a"}], [], "all")["shares"] == []

    def test_unknown_range_keeps_everything(self):
        # An unrecognized range value falls through to "no filtering" (same as 'all').
        now = time.time()
        history = self._line(3, now - 90)
        assert len(build_chart(history, [], "bogus")["p2pool"]) == 3

    def test_empty_history(self):
        assert build_chart([], [], "all") == {"p2pool": [], "xvb": [], "shares": [], "tension": 0.0}

    # --- Issue #47: custom zoom window + duration-adaptive resolution/smoothing ---------

    def test_custom_window_filters_both_bounds(self):
        # A preset bounds only the lower end; a custom window clips BOTH ends.
        hist = self._line(10, 1000)   # timestamps 1000..1270 (step 30)
        chart = build_chart(hist, [], "all", window=(1060, 1150))
        xs = [p["x"] for p in chart["p2pool"]]
        assert xs == [1060_000, 1090_000, 1120_000, 1150_000]   # only ts in [1060, 1150]

    def test_window_overrides_range(self):
        # When both a window and a range are given, the window wins.
        hist = self._line(10, 1000)
        windowed = build_chart(hist, [], "1h", window=(1060, 1150))
        assert len(windowed["p2pool"]) == 4

    def test_short_window_kept_at_native_resolution(self):
        # A <=1h window is never downsampled — full 30s detail (the "more detail zoomed in" goal).
        now = time.time()
        hist = self._line(120, now - 119 * 30, step=30)   # ~1h of 30s samples, ending now
        chart = build_chart(hist, [], "1h")
        assert len([p for p in chart["p2pool"] if p["y"] is not None]) == 120

    def test_long_window_downsamples_to_tier(self):
        now = time.time()
        # ~1 week of 30s data (20160 pts) -> capped at the <=1w tier (600).
        chart = build_chart(self._line(20160, now - 604800, step=30), [], "1w")
        assert len([p for p in chart["p2pool"] if p["y"] is not None]) <= 600

    def test_target_points_tiers(self):
        assert _target_points(3600) == 0          # <= 1h: native
        assert _target_points(3601) == 360        # <= 6h
        assert _target_points(86400) == 480       # <= 24h
        assert _target_points(604800) == 600      # <= 1w
        assert _target_points(604801) == 700      # > 1w
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
            {"timestamp": 1000, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},   # P2Pool sample
            {"timestamp": 1030, "v": 700, "v_p2pool": 0, "v_xvb": 700, "t": "b"},   # XvB sample
            {"timestamp": 1060, "v": 600, "v_p2pool": 600, "v_xvb": 0, "t": "c"},
        ]
        chart = build_chart(hist, [], "all")
        for p2p, xvb, row in zip(chart["p2pool"], chart["xvb"], hist):
            assert p2p["y"] + xvb["y"] == row["v"]      # stack top == total at every point

    def test_zoom_reveals_more_detail(self):
        # Core intent (Issue #47): zooming into a sub-window shows finer data than the wide view
        # of the same history. 8h of dense 30s samples — a ~1h window stays native resolution
        # while the full 8h downsamples, so the narrow window has more points per hour.
        now = time.time()
        dense = self._line(960, now - 8 * 3600, step=30)          # 8h @ 30s
        wide = build_chart(dense, [], "all", window=(dense[0]["timestamp"], dense[-1]["timestamp"]))
        narrow = build_chart(dense, [], "all", window=(dense[-120]["timestamp"], dense[-1]["timestamp"]))
        wide_pts = len([p for p in wide["p2pool"] if p["y"] is not None])
        narrow_pts = len([p for p in narrow["p2pool"] if p["y"] is not None])
        assert narrow_pts == 120                                  # 1h window: native, untouched
        assert narrow_pts / 1 > wide_pts / 8                      # more points per hour zoomed in

    def test_all_range_adapts_density_to_data_extent(self):
        # With "all" (no preset length, no window) the adaptive density keys off the actual data
        # extent (_window_duration). A ~2-week span lands in the widest tier and downsamples.
        now = time.time()
        dense = self._line(5000, now - 14 * 86400, step=int(14 * 86400 / 5000))
        real = [p for p in build_chart(dense, [], "all")["p2pool"] if p["y"] is not None]
        assert len(real) <= 700 and len(real) < 5000


# --- Hashrate / mode / tier formatting ------------------------------------------------

class TestHashrate:
    def test_formats_hashrates(self):
        hr = _hashrate(_metrics(total_h15=10500, p2pool_1h=8000, xvb_1h=2100))
        assert hr["total"] == "10.50 kH/s"
        assert hr["p2p_1h"] == "8.00 kH/s"
        assert hr["xvb_1h"] == "2.10 kH/s"

    def test_routed_distinct_from_credited(self):
        # Routed (what we send) is shown alongside the credited averages so the
        # live credit factor is visible.
        hr = _hashrate(_metrics(xvb_routed=2000, xvb_1h=6000))
        assert hr["xvb_routed"] == "2.00 kH/s"
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
        m = _metrics(monero=_sync(has_target=False, done=False),
                     tari=_sync(has_target=True, done=False, percent=40, current=40, target=100, remaining=60))
        sync = build_sync(m, "85.0 GB")
        assert sync["monero"]["state"] == "loading"
        assert sync["tari"]["state"] == "syncing"
        assert sync["tari"]["remaining"] == 60

    def test_done_state(self):
        sync = build_sync(_metrics(), "1.0 GB")
        assert sync["monero"]["state"] == "done"

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

    def test_node_down_and_rejected(self):
        m = _metrics(monero=_sync(down=True), tari=_sync(down=True))
        out = build_badges({"workers_rejected": True}, m, "ok")
        t = self._texts(out)
        assert "monerod DOWN" in t and "Tari DOWN" in t and "Workers rejected" in t

    def test_miner_held(self):
        out = build_badges({"miner_held": True}, _metrics(global_syncing=True), "ok")
        assert "Miner held (sync)" in self._texts(out)

    def test_passive_tari_with_and_without_percent(self):
        with_pct = build_badges({"tari_syncing_passive": True}, _metrics(tari=_sync(percent=42)), "ok")
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


# --- System (presentation thresholds) -------------------------------------------------

class TestSystem:
    def test_high_usage_levels_and_fill(self):
        s = build_system({"system": {
            "disk": {"percent": 95, "used_gb": 90, "total_gb": 100, "percent_str": "95%"},
            "memory": {"percent": 85, "used_gb": 13, "total_gb": 16, "percent_str": "85%"},
            "cpu_percent": "90.0%", "load": "0.5 0.4 0.3",
            "hugepages": ["Enabled", "status-ok", "1555/3072"],
        }})
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
        assert build_workers([{"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}])[0]["pool"] == "p2pool"
        assert build_workers([{"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": "3344"}])[0]["pool"] == "xvb"
        assert build_workers([{"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": ""}])[0]["pool"] == "unknown"

    def test_formatted_and_raw_fields(self):
        row = build_workers([{"name": "r", "ip": "10.0.0.1", "status": "online",
                              "active_pool": "3333", "uptime": 3600, "h10": 5000, "h60": 5100, "h15": 5200}])[0]
        assert row["uptime"] == 3600 and row["uptime_str"]
        assert row["h10"] == 5000 and "kH/s" in row["h10_str"]

    def test_online_sorted_before_offline(self):
        rows = build_workers([
            {"name": "zzz", "ip": "10.0.0.9", "status": "offline", "active_pool": "3333"},
            {"name": "aaa", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"},
        ])
        assert [r["name"] for r in rows] == ["aaa", "zzz"]

    def test_malformed_worker_skipped(self):
        rows = build_workers([
            {"name": "good", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"},
            {"name": "skipme", "status": "online", "active_pool": "3333"},  # no 'ip'
        ])
        assert [r["name"] for r in rows] == ["good"]

    def test_bad_ip_sorts_to_zero(self):
        assert build_workers([{"name": "r", "ip": "nope", "status": "online", "active_pool": "3333"}])[0]["ip_sort"] == 0

    def test_name_passthrough(self):
        # Raw name as data; the client text-escapes it on render.
        assert build_workers([{"name": "<rig>", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}])[0]["name"] == "<rig>"

    def test_share_counts_raw_and_formatted(self):
        # Per-worker accepted/rejected/invalid: raw counts (sort keys) + display strings (#82).
        row = build_workers([{"name": "r", "ip": "10.0.0.1", "status": "online", "active_pool": "3333",
                              "accepted": 1234, "rejected": 5, "invalid": 0}])[0]
        assert row["accepted"] == 1234 and row["accepted_str"] == "1,234"
        assert row["rejected"] == 5 and row["rejected_str"] == "5"
        assert row["invalid"] == 0

    def test_invalid_appended_to_rejected_string_only_when_nonzero(self):
        with_inv = build_workers([{"name": "r", "ip": "1.1.1.1", "status": "online",
                                   "active_pool": "3333", "rejected": 3, "invalid": 2}])[0]
        assert with_inv["rejected_str"] == "3 (+2 inv)"

    def test_missing_share_fields_default_to_zero(self):
        # Workers restored from an old snapshot (pre-#82) lack the share fields entirely.
        row = build_workers([{"name": "r", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"}])[0]
        assert (row["accepted"], row["rejected"], row["invalid"]) == (0, 0, 0)
        assert row["reject_flag"] is None

    def test_reject_flag_set_on_high_reject_rate(self):
        row = build_workers([{"name": "r", "ip": "1.1.1.1", "status": "online", "active_pool": "3333",
                              "accepted": 90, "rejected": 10, "invalid": 0}])[0]
        assert row["reject_flag"] and row["reject_flag"]["text"] == "⚠"
        assert "10.0%" in row["reject_flag"]["title"]


class TestRejectFlag:
    """The per-worker reject-rate flag (Issue #82)."""

    def test_none_without_rejects(self):
        assert _reject_flag(1000, 0) is None

    def test_none_below_noise_floor(self):
        # A couple of rejects out of a few shares is noise, even at a high rate.
        assert _reject_flag(2, 1) is None     # 33% but only 1 reject
        assert _reject_flag(0, 2) is None     # 100% but below the 3-reject floor

    def test_none_when_rate_low(self):
        assert _reject_flag(1000, 5) is None  # 5 rejects but only 0.5%

    def test_flags_high_rate_above_floor(self):
        flag = _reject_flag(90, 10)           # 10% with 10 rejects
        assert flag["text"] == "⚠"
        assert "10.0%" in flag["title"] and "10 rejected" in flag["title"]

    def test_flags_all_rejects_at_floor(self):
        # A worker submitting only rejects trips the floor immediately (rate 100%).
        assert _reject_flag(0, 3) is not None


# --- Tari -----------------------------------------------------------------------------

class TestTari:
    def test_active(self):
        t = build_tari({"tari": {"active": True, "status": "Mining", "reward": 12.5, "height": 42,
                                 "difficulty": 1234567, "address": "addr"}})
        assert t["active"] is True
        assert t["status"] == "Mining"
        assert t["reward"] == "12.50 TARI"
        assert t["diff"] == "1,234,567"

    def test_inactive_defaults(self):
        t = build_tari({"tari": {"active": False}})
        assert t["active"] is False and t["status"] == "Waiting..."

    def test_long_wallet_shortened(self):
        t = build_tari({"tari": {"active": True, "address": "T" * 40}})
        assert "..." in t["wallet_short"] and t["wallet"] == "T" * 40


# --- Proxy summary (Issue #82) --------------------------------------------------------

class TestProxySummary:
    def test_formats_totals_and_best(self):
        ps = build_proxy_summary({"proxy_summary": {
            "accepted": 12345, "rejected": 67, "invalid": 2, "expired": 1, "best": 9876543}})
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


# --- pool/network passthrough ---------------------------------------------------------

class TestPoolNetwork:
    def test_formats_from_metrics_and_data(self):
        data = {
            "stratum": {"hashrate_15m": 0, "shares_found": 5, "shares_failed": 1, "wallet": "W" * 40},
            "pool": {"pool": {"sidechain_height": 100}},
            "network": {"reward": 600_000_000_000, "hash": "abc", "timestamp": 0},
            "monero_sync": {"db_size": 85_000_000_000},
        }
        pn = build_pool_network(data, _metrics(pool_hashrate=120_000_000, pool_difficulty=250_000_000,
                                               network_difficulty=380_000_000_000, network_height=42,
                                               pplns_window=2160, block_time=10, monero_mode="Pruned"))
        assert pn["pool"]["hr"] == "120.00 MH/s"
        assert pn["pool"]["diff"] == "250.00 M"
        assert pn["network"]["diff"] == "380.00 G"
        assert pn["network"]["height"] == 42
        assert pn["stratum"]["shares"] == "5 / 1"
        assert pn["monero"]["mode"] == "Pruned"
        assert pn["monero"]["db_size"] == "85.0 GB"
        assert pn["shares_window"]["count"] == 5      # from _BASE metrics
        assert pn["shares_window"]["ok"] is True

    def test_db_size_dash_when_unknown(self):
        pn = build_pool_network({"monero_sync": {"db_size": 0}}, _metrics())
        assert pn["monero"]["db_size"] == "—"


# --- Earnings calculator (Issue #12) --------------------------------------------------

class TestEarnings:
    _NET = {"network": {"reward": 600_000_000_000}}   # 0.6 XMR block reward (atomic units)

    def test_publishes_rate_and_inputs(self):
        # The server sends the daily XMR-per-H/s *rate* + the raw inputs the client scales/inverts
        # (the P2Pool hashrate, P2Pool share difficulty) — not pre-formatted earnings.
        e = build_earnings(self._NET, _metrics(p2pool_1h=10500,
                                               network_difficulty=400_000_000_000,
                                               pool_difficulty=250_000_000))
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
        m = _metrics(total_h15=46_300, xvb_routed=10_000, p2pool_1h=35_000)
        e = build_earnings(self._NET, m)
        assert e["p2pool_hr"] == 35_000                       # p2pool_1h, independent of total/routed
        assert e["p2pool_hr_str"] == _hashrate(m)["p2p_1h"]   # identical display string to the header

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


# --- build_state integration ----------------------------------------------------------

def _state_mgr(history=None, mode="P2POOL"):
    sm = MagicMock()
    sm.get_history.return_value = history or []
    sm.get_xvb_stats.return_value = {"current_mode": mode}
    sm.get_tiers.return_value = {}
    return sm


def _data(**over):
    data = {
        "shares": [], "workers": [], "global_sync": False, "total_live_h15": 0,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 50, "current": 5, "target": 10},
    }
    data.update(over)
    return data


class TestBuildState:
    def test_has_all_sections(self):
        st = build_state(_data(), _state_mgr(), "all")
        for key in ("syncing", "page_title", "host_ip", "last_update", "range", "window", "badges",
                    "hashrate", "system", "sync", "stratum", "pool", "network", "monero",
                    "shares_window", "proxy_workers", "earnings", "tari", "workers",
                    "proxy_summary", "chart"):
            assert key in st, f"missing section: {key}"

    def test_is_json_serializable(self):
        json.dumps(build_state(_data(), _state_mgr(), "all"))

    def test_range_echoed(self):
        assert build_state(_data(), _state_mgr(), "24h")["range"] == "24h"

    def test_window_null_on_preset(self):
        assert build_state(_data(), _state_mgr(), "24h")["window"] is None

    def test_window_echoed_when_zoomed(self):
        # A custom zoom window is echoed so the client can render Reset / re-request on refresh.
        st = build_state(_data(), _state_mgr(), "all", window=(1000.0, 2000.0))
        assert st["window"] == {"from": 1000.0, "to": 2000.0}

    def test_syncing_flag_and_title(self):
        st = build_state(_data(global_sync=True), _state_mgr(), "all")
        assert st["syncing"] is True
        assert st["page_title"] == "Mining Dashboard - Syncing"

    def test_proxy_workers_from_metrics(self):
        data = _data(workers=[{"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"},
                              {"name": "b", "ip": "1.1.1.2", "status": "offline", "active_pool": "3333"}])
        assert build_state(data, _state_mgr(), "all")["proxy_workers"] == 1

    def test_chart_uses_timestamps(self):
        history = [{"timestamp": 100, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},
                   {"timestamp": 160, "v": 600, "v_p2pool": 300, "v_xvb": 300, "t": "b"}]
        chart = build_state(_data(), _state_mgr(history=history), "all")["chart"]
        assert chart["p2pool"] == [{"x": 100_000, "y": 500}, {"x": 160_000, "y": 300}]
        assert chart["xvb"][1] == {"x": 160_000, "y": 300}

    def test_propagates_state_errors(self):
        bad_sm = MagicMock()
        bad_sm.get_history.side_effect = RuntimeError("boom")
        with pytest.raises(RuntimeError):
            build_state(_data(), bad_sm, "all")


class TestParseWindow:
    def test_valid_pair(self):
        assert parse_window("1000", "2000") == (1000.0, 2000.0)

    def test_absent_is_none(self):
        assert parse_window(None, None) is None
        assert parse_window("1000", None) is None

    @pytest.mark.parametrize("frm,to", [
        ("bad", "2000"),   # non-numeric
        ("2000", "1000"),  # from >= to
        ("1000", "1000"),  # zero-width
        ("-5", "2000"),    # non-positive
        ("nan", "2000"),   # not finite
        ("inf", "2000"),
    ])
    def test_malformed_falls_back_to_none(self, frm, to):
        assert parse_window(frm, to) is None


class TestShell:
    def test_returns_html_referencing_module(self):
        shell = get_shell_html()
        assert "<!DOCTYPE html>" in shell
        assert '/static/dashboard.js' in shell
        assert 'id="app"' in shell

    def test_error_fallback(self, monkeypatch):
        views._SHELL_CACHE = None
        monkeypatch.setattr(views.os.path, "getmtime",
                            lambda p: (_ for _ in ()).throw(OSError()))
        assert get_shell_html() == "<h1>Dashboard shell error</h1>"
