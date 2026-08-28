"""Unit tests for the host/rig/node status sections (mining_dashboard/web/infra_views.py).

Moved out of tests/web/test_views.py with the sections themselves (#1105). The test bodies are
verbatim; the only edits are the three module-alias reads in ``TestBuildEnergy`` that follow their
target from ``views`` to ``infra_views``.

``_SYNC_DONE``/``_BASE``/``_metrics``/``_sync``/``_state_mgr``/``_data`` below are COPIES. The
master lives in ``tests/web/test_views.py``, which still needs them for the tests that stayed, and a
sibling copy is in ``tests/web/test_xvb_views.py``. There is no import route between two test
modules here — ``pyproject.toml`` runs pytest with ``--import-mode=importlib`` and the test tree has
no ``__init__.py``, so neither a sibling module nor ``conftest`` is importable — and converting
these to pytest fixtures would rewrite every call site and cost the verbatim move. The same trade is
already recorded for this pair at ``tests/web/test_views.py``'s ``_state_mgr``. These copies mirror
the ``Metrics`` dataclass, so any drift breaks them loudly rather than silently. Consolidating them
into real fixtures is tracked as #1459, once #1105 stops requiring byte-identity.
"""

import time
from dataclasses import replace
from unittest.mock import MagicMock

from mining_dashboard.service.metrics import Metrics, SyncMetric, _sync_metric
from mining_dashboard.web.infra_views import (
    _reject_flag,
    _rigforge_display,
    build_energy,
    build_proxy_summary,
    build_sync,
    build_system,
    build_tari,
    build_workers,
    rigforge_update_for,
)
from mining_dashboard.web.views import build_state
from mining_dashboard.web.worker_detail import build_worker_detail

# --- Fixtures: COPIES of the builders in test_views.py (see the module docstring) ------

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
        from mining_dashboard.web import infra_views

        monkeypatch.setattr(
            infra_views.config,
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
        monkeypatch.setattr(infra_views.config, "DASHBOARD_WORKERS", descriptors or [])
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
