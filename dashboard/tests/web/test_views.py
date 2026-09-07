"""Unit tests for the dashboard view/presentation layer (mining_dashboard/web/views.py).

The view layer formats the computed :class:`Metrics` (and a little passthrough from the raw
snapshot) into the structured ``/api/state`` payload the Preact client renders. Domain logic is
tested in tests/service/test_metrics.py; here we test the *display* mapping (formatting +
presentation tokens), the chart series (Issue #65), and the full ``build_state`` contract.

The shared builders — ``_SYNC_DONE``/``_BASE`` and the ``_metrics``, ``_sync``, ``_hashrate``,
``_state_mgr`` and ``_data`` factories — are pytest fixtures in ``tests/web/conftest.py`` as of
#1459. Each test that needs one takes it as a parameter; the call itself reads as it always did.
What is deliberately NOT shared, and why, is written in that file.
"""

import json
import time
from unittest.mock import MagicMock, patch

import pytest

import mining_dashboard.web.charts as charts
import mining_dashboard.web.views as views
from mining_dashboard.config import config as egress_config
from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    HASHRATE_WINDOWS,
)
from mining_dashboard.web.views import (
    build_chart,
    build_pool_network,
    build_raffle_eligibility,
    build_state,
    canonical_window,
    get_shell_html,
    visible_update,
)
from mining_dashboard.web.worker_detail import build_worker_detail

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

    def test_build_state_echoes_selected_window(self, _data, _state_mgr):
        state = build_state(_data(), _state_mgr(history=[self._row()]), "all", None, "1h")
        assert state["avg_window"] == "1h"
        assert state["avg_windows"] == HASHRATE_WINDOWS
        assert state["chart"]["p2pool"][0]["y"] == 1100  # the 1h column, end to end

    def test_build_state_defaults_to_10m(self, _data, _state_mgr):
        state = build_state(_data(), _state_mgr(history=[self._row()]), "all")
        assert state["avg_window"] == DEFAULT_HASHRATE_WINDOW
        assert state["chart"]["p2pool"][0]["y"] == 1000  # the original 10m series

    def test_build_state_exposes_control_flag_for_upgrade_button(
        self, _data, _state_mgr, monkeypatch
    ):
        # Off by default; flipping the module attribute flips the state key (#59 button gating).
        import mining_dashboard.config.config as cfg

        state = build_state(_data(), _state_mgr(history=[self._row()]), "all")
        assert state["control_enabled"] is False
        monkeypatch.setattr(cfg, "DASHBOARD_CONTROL_ENABLED", True)
        state = build_state(_data(), _state_mgr(history=[self._row()]), "all")
        assert state["control_enabled"] is True


# --- pool/network passthrough ---------------------------------------------------------


class TestPoolNetwork:
    def test_formats_from_metrics_and_data(self, _metrics):
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

    def test_db_size_dash_when_unknown(self, _metrics):
        pn = build_pool_network({"monero_sync": {"db_size": 0}}, _metrics())
        assert pn["monero"]["db_size"] == "—"

    def test_last_block_is_a_relative_duration(self, _metrics):
        # One time register for "when did the pool last find a block" (#992): the cadence card
        # already shows a duration, and a bare HH:MM:SS here (no date, no timezone) read as one
        # too — so the value now IS a duration, "Never" before the pool's first block.
        data = {"pool": {"pool": {"last_block_ts": time.time() - 90}}}
        assert build_pool_network(data, _metrics())["pool"]["last_blk"] == "1m 30s ago"
        assert build_pool_network({}, _metrics())["pool"]["last_blk"] == "Never"


# --- build_state integration ----------------------------------------------------------


class TestBuildState:
    def test_has_all_sections(self, _data, _state_mgr):
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

    def test_version_section_shape(self, _data, _state_mgr):
        # The header version badge (Issue #58) is part of the shared payload, so it rides on both
        # the syncing and main screens. Shape only — resolution rules live in tests/test_version.py.
        v = build_state(_data(), _state_mgr(), "all")["version"]
        assert set(v) == {"text", "title", "dev"}
        assert isinstance(v["text"], str) and v["text"]
        assert isinstance(v["dev"], bool)

    def test_update_section_surfaced_and_defaults_none(self, _data, _state_mgr):
        # The new-release badge (#224) rides on the shared payload; a genuinely-newer result
        # passes through, and absence defaults to None (no badge).
        upd = {"available": True, "latest": "v9.9.9", "url": "https://x/releases/tag/v9.9.9"}
        assert build_state(_data(update=upd), _state_mgr(), "all")["update"] == upd
        assert build_state(_data(), _state_mgr(), "all")["update"] is None

    def test_update_badge_never_advertises_the_running_version(
        self, _data, _state_mgr, monkeypatch
    ):
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

    def test_absent_file_reads_none(self, _data, _state_mgr, monkeypatch):
        # No file = not an appliance: the state carries None and the control never renders.
        monkeypatch.setattr(views.config, "OS_UPDATE_STATE_PATH", "/nonexistent/os-update.json")
        assert views.read_os_update_state() is None
        assert build_state(_data(), _state_mgr(), "all")["os_update"] is None

    def test_state_file_passes_through(self, _data, _state_mgr, tmp_path, monkeypatch):
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

    def test_is_json_serializable(self, _data, _state_mgr):
        json.dumps(build_state(_data(), _state_mgr(), "all"))

    def test_share_stats_series_and_24h_rate_surfaced(self, _data, _state_mgr):
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

    def test_blocks_disk_growth_xvb_history_surfaced(self, _data, _state_mgr):
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

    def test_db_unhealthy_surfaces_field_and_badge(self, _data, _state_mgr):
        # When persistence is broken, /api/state must carry db_healthy=False and a loud badge (#131).
        sm = _state_mgr()
        sm.is_db_healthy.return_value = False
        st = build_state(_data(), sm, "all")
        assert st["db_healthy"] is False
        assert any("DB write failing" in b["text"] for b in st["badges"])

    def test_db_healthy_no_badge(self, _data, _state_mgr):
        st = build_state(_data(), _state_mgr(), "all")
        assert st["db_healthy"] is True
        assert not any("DB write failing" in b["text"] for b in st["badges"])

    def test_range_echoed(self, _data, _state_mgr):
        assert build_state(_data(), _state_mgr(), "24h")["range"] == "24h"

    def test_window_null_on_preset(self, _data, _state_mgr):
        assert build_state(_data(), _state_mgr(), "24h")["window"] is None

    def test_last_update_reflects_snapshot_timestamp_not_now(self, _data, _state_mgr):
        # #559: a restored stale snapshot (dashboard was down) must report its own age, not the
        # current time -- otherwise stale workers/hashrate read as "just now" until the first
        # post-restart collection cycle completes.
        old_ts = time.time() - 6 * 3600
        st = build_state(_data(timestamp=old_ts), _state_mgr(), "all")
        assert st["last_update"] == views.format_time_abs(old_ts)
        assert st["last_update"] != views.format_time_abs(time.time())

    def test_last_update_falls_back_to_now_when_timestamp_missing(self, _data, _state_mgr):
        # No "timestamp" key (or the pre-first-collection default of 0) -> fall back to now
        # rather than showing "Never".
        with patch("mining_dashboard.web.views.time.time", return_value=12345.0):
            assert build_state(_data(), _state_mgr(), "all")["last_update"] == (
                views.format_time_abs(12345.0)
            )
            assert build_state(_data(timestamp=0), _state_mgr(), "all")["last_update"] == (
                views.format_time_abs(12345.0)
            )

    def test_window_echoed_when_zoomed(self, _data, _state_mgr):
        # A custom zoom window is echoed so the client can render Reset / re-request on refresh.
        st = build_state(_data(), _state_mgr(), "all", window=(1000.0, 2000.0))
        assert st["window"] == {"from": 1000.0, "to": 2000.0}

    def test_syncing_flag_and_title(self, _data, _state_mgr):
        st = build_state(_data(global_sync=True), _state_mgr(), "all")
        assert st["syncing"] is True
        assert st["page_title"] == "Pithead Dashboard - Syncing"

    def test_proxy_workers_from_metrics(self, _data, _state_mgr):
        data = _data(
            workers=[
                {"name": "a", "ip": "1.1.1.1", "status": "online", "active_pool": "3333"},
                {"name": "b", "ip": "1.1.1.2", "status": "offline", "active_pool": "3333"},
            ]
        )
        assert build_state(data, _state_mgr(), "all")["proxy_workers"] == 1

    def test_chart_uses_timestamps(self, _data, _state_mgr):
        history = [
            {"timestamp": 100, "v": 500, "v_p2pool": 500, "v_xvb": 0, "t": "a"},
            {"timestamp": 160, "v": 600, "v_p2pool": 300, "v_xvb": 300, "t": "b"},
        ]
        chart = build_state(_data(), _state_mgr(history=history), "all")["chart"]
        assert chart["p2pool"] == [{"x": 100_000, "y": 500}, {"x": 160_000, "y": 300}]
        assert chart["xvb"][1] == {"x": 160_000, "y": 300}

    def test_propagates_state_errors(self, _data):
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

    def test_both_sections_present_and_share_one_summary(self, _data, _state_mgr, monkeypatch):
        _set_egress_config(monkeypatch)
        st = build_state(_data(), _state_mgr(), "all")
        assert st["egress"]["components"]
        assert st["topology"]["nodes"] and st["topology"]["edges"]
        # The badge can never contradict the map: identical summary in both sections.
        assert st["topology"]["summary"] == st["egress"]["summary"]

    def test_safe_config_emits_a_tor_only_header_badge(self, _data, _state_mgr, monkeypatch):
        _set_egress_config(monkeypatch)
        st = build_state(_data(), _state_mgr(), "all")
        badge = st["badges"][-1]  # _egress_badge is appended last in build_state
        assert badge["variant"] == "ok"
        assert "Tor-only" in badge["text"]
        assert st["egress"]["summary"]["all_tor"] is True

    def test_xvb_tor_off_stays_a_tor_only_badge(self, _data, _state_mgr, monkeypatch):
        # xvb.tor gates only the xmrig-proxy donation dial; the dashboard's stats fetch is
        # unconditionally Tor (#163/#701), so with the firewall on nothing leaks — badge stays green.
        _set_egress_config(monkeypatch, XVB_TOR_ENABLED=False)
        st = build_state(_data(), _state_mgr(), "all")
        assert st["badges"][-1]["variant"] == "ok"
        assert st["egress"]["summary"]["leaks"] == 0

    def test_clearnet_leak_emits_a_warning_badge(self, _data, _state_mgr, monkeypatch):
        # A real leak (clearnet sidechain peers with the firewall down) must flip the badge to a
        # loud warning and the topology summary to "warn".
        _set_egress_config(monkeypatch, P2POOL_CLEARNET=True, TOR_EGRESS_FIREWALL=False)
        st = build_state(_data(), _state_mgr(), "all")
        badge = st["badges"][-1]
        assert badge["variant"] == "bad"
        assert "clearnet egress" in badge["text"]
        assert st["topology"]["summary"]["level"] == "warn"
        assert st["egress"]["summary"]["leaks"] >= 1

    def test_remote_monerod_is_reflected_in_the_payload(self, _data, _state_mgr, monkeypatch):
        # #1350: a private-addressed remote monerod is a LAN hop and charges neither counter; a
        # public one is clearnet, blocked not leaked. Both hops read — they used to disagree.
        def _payload(host):
            _set_egress_config(monkeypatch, MONERO_NODE_HOST=host, LOCAL_MONERO_HOST="127.0.0.1")
            st = build_state(_data(), _state_mgr(), "all")
            hops = {e["from"]: e["route"] for e in st["topology"]["edges"] if e["to"] == "monerod"}
            return hops, st["egress"]["summary"]["blocked_by_firewall"]

        assert _payload("10.0.0.9") == ({"p2pool": "lan", "dashboard": "lan"}, 0)
        assert _payload("8.8.8.8") == ({"p2pool": "clearnet", "dashboard": "clearnet"}, 1)

    def test_payload_stays_json_serializable_with_a_leak(self, _data, _state_mgr, monkeypatch):
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

    def test_yes_when_in_tier_and_has_share(self, _metrics):
        m = _metrics(xvb_enabled=True, current_tier="Donor (1.00 kH/s+)", shares_in_window=5)
        assert build_raffle_eligibility(m) == {"applies": True, "eligible": True, "label": "Yes"}

    def test_no_when_below_tier_even_with_a_share(self, _metrics):
        # Has a PPLNS share but credited donation hasn't cleared the lowest tier (current_tier "None").
        m = _metrics(xvb_enabled=True, current_tier="None", shares_in_window=5)
        assert build_raffle_eligibility(m) == {"applies": True, "eligible": False, "label": "No"}

    def test_no_when_in_tier_but_no_share(self, _metrics):
        m = _metrics(xvb_enabled=True, current_tier="Donor (1.00 kH/s+)", shares_in_window=0)
        assert build_raffle_eligibility(m) == {"applies": True, "eligible": False, "label": "No"}

    def test_na_when_xvb_off(self, _metrics):
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
