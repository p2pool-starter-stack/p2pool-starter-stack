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

import mining_dashboard.web.charts as charts
import mining_dashboard.web.views as views
from mining_dashboard.config import config as egress_config
from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    HASHRATE_WINDOWS,
)
from mining_dashboard.service.metrics import Metrics, SyncMetric, _sync_metric
from mining_dashboard.web.views import (
    _MAX_CHART_POINTS,
    _mode_palette,
    _reject_flag,
    _rigforge_display,
    _window_reject_pct,
    build_blocks,
    build_cadence,
    build_chart,
    build_disk_growth,
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
    build_workers,
    build_xvb_history,
    canonical_window,
    get_shell_html,
    host_display_addr,
    rigforge_update_for,
    visible_update,
)
from mining_dashboard.web.worker_detail import build_worker_detail

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
        out = charts._downsample_history(rows, 86400)
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

    def test_disk_unit_switches_to_tb_on_large_volumes(self):
        # Threshold mechanics live in test_utils.py; this proves the card wires the unit through.
        s = build_system(
            {"system": {"disk": {"used_gb": 408.6, "total_gb": 3666.4, "percent_str": "11.1%"}}}
        )
        assert (s["disk"]["used"], s["disk"]["total"], s["disk"]["unit"]) == ("0.4", "3.6", "TB")

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


class TestRigforgeUpdate:
    """The per-worker RigForge new-release callout (#596), derived at the render seam."""

    _REL = {"tag": "v1.11.2", "url": "https://h/v1.11.2"}
    _W = {"name": "r", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"}

    def test_behind_rig_gets_the_callout(self):
        w = {**self._W, "rigforge": {"version": "1.11.1"}}
        out = rigforge_update_for(w, self._REL)
        assert out == {"available": True, "latest": "v1.11.2", "url": "https://h/v1.11.2"}

    def test_current_rig_never_badges_its_own_version(self):
        # The rig reports bare "1.11.2"; the tag is "v1.11.2" — equality must hold across the
        # format difference (the #664 self-consistency guard, per-worker edition).
        w = {**self._W, "rigforge": {"version": "1.11.2"}}
        assert rigforge_update_for(w, self._REL) is None

    def test_newer_or_unparseable_rig_version_is_none(self):
        assert rigforge_update_for({**self._W, "rigforge": {"version": "9.0.0"}}, self._REL) is None
        assert (
            rigforge_update_for({**self._W, "rigforge": {"version": "nightly"}}, self._REL) is None
        )

    def test_no_version_or_no_release_is_none(self):
        # A plain-:8080 rig reports no version: no badge, not a false "up to date". No cached
        # release (check disabled / offline): same.
        assert rigforge_update_for(self._W, self._REL) is None
        assert rigforge_update_for({**self._W, "rigforge": {"version": "1.11.1"}}, None) is None

    def test_build_workers_attaches_per_row(self):
        rows = build_workers(
            [
                {**self._W, "name": "behind", "rigforge": {"version": "1.11.1"}},
                {**self._W, "name": "current", "rigforge": {"version": "1.11.2"}},
                {**self._W, "name": "plain"},
            ],
            self._REL,
        )
        by = {r["name"]: r["rigforge_update"] for r in rows}
        assert by["behind"]["latest"] == "v1.11.2"
        assert by["current"] is None
        assert by["plain"] is None

    def test_build_workers_without_release_attaches_none(self):
        rows = build_workers([{**self._W, "rigforge": {"version": "1.11.1"}}])
        assert rows[0]["rigforge_update"] is None

    def test_build_state_feeds_the_cached_release_through(self):
        data = _data(
            workers=[{**self._W, "rigforge": {"version": "1.11.1"}}],
            rigforge_release=self._REL,
        )
        st = build_state(data, _state_mgr(), "all")
        assert st["workers"][0]["rigforge_update"]["latest"] == "v1.11.2"

    def test_worker_detail_attaches_the_callout(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        try:
            d = build_worker_detail(
                "r",
                {
                    "workers": [{**self._W, "rigforge": {"version": "1.11.1"}}],
                    "rigforge_release": self._REL,
                },
                sm,
            )
        finally:
            sm.close()
        assert d["rigforge_update"]["latest"] == "v1.11.2"


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
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", True)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
        now = time.time()
        mgr = self._payout_mgr(
            {
                "monero": [{"ts": now - 60, "amount_atomic": 12_345}],
                "tari": [{"ts": now - 120, "amount_atomic": 999}],
            }
        )
        out = views.build_payouts(mgr, "all")
        assert out["monero"] == [{"x": int((now - 60) * 1000), "amount": 12_345}]
        assert out["tari"] == [{"x": int((now - 120) * 1000), "amount": 999}]

    def test_build_payouts_range_filters_like_blocks(self, monkeypatch):
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", True)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
        now = time.time()
        mgr = self._payout_mgr(
            {
                "tari": [
                    {"ts": now - 8 * 24 * 3600, "amount_atomic": 1},
                    {"ts": now - 60, "amount_atomic": 2},
                ]
            }
        )
        assert len(views.build_payouts(mgr, "1w")["tari"]) == 1

    def test_build_payouts_gates_per_chain_and_none_mgr(self, monkeypatch):
        # A disabled chain stays an empty list even when rows exist — the payload never leaks
        # payout data while the operator has confirmation off for that chain.
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
        now = time.time()
        mgr = self._payout_mgr(
            {
                "monero": [{"ts": now, "amount_atomic": 1}],
                "tari": [{"ts": now, "amount_atomic": 2}],
            }
        )
        out = views.build_payouts(mgr, "all")
        assert out["monero"] == []
        assert len(out["tari"]) == 1
        mgr.get_payouts.assert_called_once_with("tari")  # disabled chain never queried
        assert views.build_payouts(None, "all") == {"monero": [], "tari": []}

    def test_payouts_ride_build_state_end_to_end(self, monkeypatch):
        # The wiring, not just the builder: with confirmation on, a stored payout row surfaces
        # in the top-level payload the client polls (the mine cart train reads state.payouts).
        # The shared _state_mgr() MagicMock auto-mocks get_payouts, so point it at real rows.
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
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

    def test_last_block_is_a_relative_duration(self):
        # One time register for "when did the pool last find a block" (#992): the cadence card
        # already shows a duration, and a bare HH:MM:SS here (no date, no timezone) read as one
        # too — so the value now IS a duration, "Never" before the pool's first block.
        data = {"pool": {"pool": {"last_block_ts": time.time() - 90}}}
        assert build_pool_network(data, _metrics())["pool"]["last_blk"] == "1m 30s ago"
        assert build_pool_network({}, _metrics())["pool"]["last_blk"] == "Never"


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


# --- build_state integration ----------------------------------------------------------


# ponytail: this _state_mgr()/_data() pair looks near-duplicated with the ones in test_metrics.py,
# but the per-module defaults differ on purpose (e.g. tari_sync, the get_tiers/xvb shapes). A shared
# builder would need enough params that it reads worse than the local copy — left duplicated.
def _state_mgr(
    history=None,
    mode="P2POOL",
    share_stats=None,
    blocks=None,
    disk_growth=None,
    xvb_history=None,
):
    sm = MagicMock()
    sm.get_history.return_value = history or []
    sm.get_xvb_stats.return_value = {"current_mode": mode}
    sm.get_tiers.return_value = {}
    sm.get_xvb_reward_estimates.return_value = {"estimates": {}, "last_update": 0.0}
    sm.get_xvb_round_stats.return_value = {"stats": {}, "last_update": 0.0}
    sm.get_share_stats.return_value = share_stats or []
    sm.get_raffle_wins.return_value = []
    sm.get_xvb_standby.return_value = None  # no backup standby held (#249)
    sm.is_db_healthy.return_value = True
    # #196 Tier-1 telemetry backbone exposure.
    sm.get_blocks.return_value = blocks or []
    sm.get_disk_growth.return_value = disk_growth or []
    sm.get_xvb_history.return_value = xvb_history or []
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
            "blocks",
            "payouts",
            "disk_growth",
            "xvb_history",
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


class TestOsUpdateState:
    """The appliance OS-update state read (host-written file behind the results/ mount)."""

    def test_absent_file_reads_none(self, monkeypatch):
        # No file = not an appliance: the state carries None and the control never renders.
        monkeypatch.setattr(views.config, "OS_UPDATE_STATE_PATH", "/nonexistent/os-update.json")
        assert views.read_os_update_state() is None
        assert build_state(_data(), _state_mgr(), "all")["os_update"] is None

    def test_state_file_passes_through(self, tmp_path, monkeypatch):
        p = tmp_path / "os-update-state.json"
        p.write_text(
            json.dumps(
                {
                    "step": "idle",
                    "verdict": {"outcome": "updated", "from": "1.18.1", "to": "1.19.0"},
                }
            )
        )
        monkeypatch.setattr(views.config, "OS_UPDATE_STATE_PATH", str(p))
        out = build_state(_data(), _state_mgr(), "all")["os_update"]
        assert out["step"] == "idle"
        assert out["verdict"]["outcome"] == "updated"

    def test_garbled_file_degrades_to_none(self, tmp_path, monkeypatch):
        p = tmp_path / "os-update-state.json"
        p.write_text("{not json")
        monkeypatch.setattr(views.config, "OS_UPDATE_STATE_PATH", str(p))
        assert views.read_os_update_state() is None
        p.write_text('["a","list"]')  # wrong shape is not a dict — also None
        assert views.read_os_update_state() is None


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

    def test_blocks_disk_growth_xvb_history_surfaced(self):
        # #196 Tier-1: the three backbone series ride on /api/state, each sourced from its own
        # StateManager getter.
        now = time.time()
        sm = _state_mgr(
            blocks=[{"ts": now - 60, "height": 5, "difficulty": 10.0}],
            disk_growth=[
                {"ts": now - 60, "monero_db_bytes": 1, "disk_used_gb": 2.0, "disk_total_gb": 3.0}
            ],
            xvb_history=[
                {
                    "ts": now - 60,
                    "avg_1h": 1,
                    "avg_24h": 2,
                    "fail_count": 0,
                    "donation_fraction": 0.1,
                }
            ],
        )
        st = build_state(_data(), sm, "all")
        assert st["blocks"][0]["height"] == 5
        assert st["disk_growth"][0]["monero_db_bytes"] == 1
        assert st["xvb_history"][0]["avg_1h"] == 1
        # Fresh install -> empty series, not a crash.
        empty = build_state(_data(), _state_mgr(), "all")
        assert empty["blocks"] == [] and empty["disk_growth"] == [] and empty["xvb_history"] == []

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

    def test_xvb_tor_off_stays_a_tor_only_badge(self, monkeypatch):
        # xvb.tor gates only the xmrig-proxy donation dial; the dashboard's stats fetch is
        # unconditionally Tor (#163/#701), so with the firewall on nothing leaks — badge stays green.
        _set_egress_config(monkeypatch, XVB_TOR_ENABLED=False)
        st = build_state(_data(), _state_mgr(), "all")
        assert st["badges"][-1]["variant"] == "ok"
        assert st["egress"]["summary"]["leaks"] == 0

    def test_clearnet_leak_emits_a_warning_badge(self, monkeypatch):
        # A real leak (clearnet sidechain peers with the firewall down) must flip the badge to a
        # loud warning and the topology summary to "warn".
        _set_egress_config(monkeypatch, P2POOL_CLEARNET=True, TOR_EGRESS_FIREWALL=False)
        st = build_state(_data(), _state_mgr(), "all")
        badge = st["badges"][-1]
        assert badge["variant"] == "bad"
        assert "clearnet egress" in badge["text"]
        assert st["topology"]["summary"]["level"] == "warn"
        assert st["egress"]["summary"]["leaks"] >= 1

    def test_remote_monerod_is_reflected_in_the_payload(self, monkeypatch):
        # #1350: a private-addressed remote monerod is a LAN hop and charges neither counter; a
        # public one is clearnet, blocked not leaked. Both hops read — they used to disagree.
        def _payload(host):
            _set_egress_config(monkeypatch, MONERO_NODE_HOST=host, LOCAL_MONERO_HOST="127.0.0.1")
            st = build_state(_data(), _state_mgr(), "all")
            hops = {e["from"]: e["route"] for e in st["topology"]["edges"] if e["to"] == "monerod"}
            return hops, st["egress"]["summary"]["blocked_by_firewall"]

        assert _payload("10.0.0.9") == ({"p2pool": "lan", "dashboard": "lan"}, 0)
        assert _payload("8.8.8.8") == ({"p2pool": "clearnet", "dashboard": "clearnet"}, 1)

    def test_payload_stays_json_serializable_with_a_leak(self, monkeypatch):
        _set_egress_config(monkeypatch, P2POOL_CLEARNET=True, TOR_EGRESS_FIREWALL=False)
        json.dumps(build_state(_data(), _state_mgr(), "all"))


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


class TestBuildWorkerHashrateHistory:
    """The per-worker hashrate-over-time chart (#1013) + its change-marker overlay (#1015)."""

    def _detail(self, monkeypatch, workers=None, descriptors=None, range_arg="all", window=None):
        from mining_dashboard.service.storage_service import StateManager
        from mining_dashboard.web import views

        monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", descriptors or [])
        sm = StateManager(db_path=":memory:")
        data = {"workers": workers or [{"name": "rig1", "status": "online", "h60": 0}]}
        return sm, data, range_arg, window

    def test_no_history_yet_is_an_honest_empty_series(self, monkeypatch):
        # A brand new rig: no worker_history samples, no change history. The chart must render an
        # empty state client-side, not a broken axis — this is the data half of that contract.
        sm, data, range_arg, window = self._detail(monkeypatch)
        try:
            d = build_worker_detail("rig1", data, sm, range_arg, window)
        finally:
            sm.close()
        assert d["hashrate_history"] == {"hashrate": [], "markers": []}

    def test_hashrate_series_and_markers_present(self, monkeypatch):
        sm, data, range_arg, window = self._detail(monkeypatch)
        try:
            sm.add_worker_history(
                [{"ts": 1000.0, "name": "rig1", "h15": 1234.0, "accepted": 0, "rejected": 0}]
            )
            sm.add_worker_config_version("rig1", "cid1", "applied", {"DONATION": 2}, None, ts=900.0)
            d = build_worker_detail("rig1", data, sm, range_arg, window)
        finally:
            sm.close()
        hist = d["hashrate_history"]
        assert hist["hashrate"] == [{"x": 1000000, "y": 1234.0}]
        assert len(hist["markers"]) == 1
        m = hist["markers"][0]
        assert m["x"] == 900000
        assert m["status"] == "applied"
        assert m["type"] == "apply"
        assert m["changes"] == {"DONATION": 2}

    def test_upgrade_row_marked_with_its_own_type(self, monkeypatch):
        sm, data, range_arg, window = self._detail(monkeypatch)
        try:
            sm.add_worker_config_version(
                "rig1",
                "cid1",
                "applied",
                {"version": "v1.12.0"},
                None,
                ts=900.0,
                change_type="upgrade",
            )
            d = build_worker_detail("rig1", data, sm, range_arg, window)
        finally:
            sm.close()
        m = d["hashrate_history"]["markers"][0]
        assert m["type"] == "upgrade"
        assert m["changes"] == {"version": "v1.12.0"}

    def test_range_filters_both_hashrate_and_markers(self, monkeypatch):
        # Same range/window bound the chart line and its markers together, so a marker never
        # renders outside the window its own hashrate slice covers.
        now = time.time()
        sm, data, _, _ = self._detail(monkeypatch)
        try:
            sm.add_worker_history(
                [{"ts": now - 7200, "name": "rig1", "h15": 1.0, "accepted": 0, "rejected": 0}]
            )
            sm.add_worker_history(
                [{"ts": now - 60, "name": "rig1", "h15": 2.0, "accepted": 0, "rejected": 0}]
            )
            sm.add_worker_config_version("rig1", "c-old", "applied", {"a": 1}, None, ts=now - 7200)
            sm.add_worker_config_version("rig1", "c-new", "applied", {"a": 2}, None, ts=now - 60)
            d = build_worker_detail("rig1", data, sm, "1h", None)  # 2h-old sample/marker excluded
        finally:
            sm.close()
        hist = d["hashrate_history"]
        assert len(hist["hashrate"]) == 1 and hist["hashrate"][0]["y"] == 2.0
        assert len(hist["markers"]) == 1 and hist["markers"][0]["status"] == "applied"
