import asyncio
import json
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import mining_dashboard.service.data_service as ds_mod
from mining_dashboard.client.xmrig_client import XMRigWorkerClient
from mining_dashboard.client.xvb_client import (
    REG_ERROR,
    REG_INVALID,
    REG_NOT_ELIGIBLE,
    REG_OK,
)
from mining_dashboard.config.config import XVB_REGISTER_INTERVAL_S
from mining_dashboard.service.data_service import (
    _XVB_REGISTER_FAIL_ALERT,
    _XVB_WINNERS_SYNC_FAST_SEC,
    _XVB_WINNERS_SYNC_SEC,
    DataService,
    WorkerLifecycle,
    _aggregate_hashrate,
    _aggregate_window_hashrates,
    _diff_config_keys,
    _iso_now,
    _merge_direct_stats,
    _merge_proxy_summary,
    _normalize_proxy_workers,
    _parse_audit_ts,
    _parse_legacy_dict_worker,
    _parse_proxy_list_worker,
    _parse_proxy_summary,
    _read_host_config,
    _shares_to_record,
    _summary_deltas,
    _xvb_winners_gate_sec,
)


class _FakeClientSession:
    """Stand-in for aiohttp.ClientSession used as an async context manager."""

    async def __aenter__(self):
        return MagicMock()

    async def __aexit__(self, *exc):
        return False


def _make_service():
    state_manager = MagicMock()
    state_manager.load_snapshot.return_value = None
    state_manager.get_shares.return_value = []
    state_manager.get_xvb_stats.return_value = {"current_mode": "P2POOL"}
    proxy_client = MagicMock()
    xvb_client = MagicMock()
    svc = DataService(state_manager, proxy_client, xvb_client)
    # Mock the docker-control proxy so run()'s sync gate / failover don't hit the network.
    svc.docker_control = MagicMock()
    svc.docker_control.stop = AsyncMock(return_value=True)
    svc.docker_control.start = AsyncMock(return_value=True)
    return svc, state_manager, proxy_client


class TestSharesToRecord:
    """#129: how many P2Pool shares to record from the cumulative shares_found counter, + the new baseline."""

    def test_first_poll_baselines_without_backfill(self):
        # last_known None -> baseline to current, record nothing (don't backfill the historical count).
        assert _shares_to_record(None, 1000) == (0, 1000)

    def test_delta_records_the_difference(self):
        # A burst of 3 shares since the last poll -> record 3, advance the baseline.
        assert _shares_to_record(1000, 1003) == (3, 1003)

    def test_no_change_records_nothing(self):
        assert _shares_to_record(1000, 1000) == (0, 1000)

    def test_counter_reset_rebaselines(self):
        # p2pool restarted (counter went backwards) -> re-baseline to the lower value, record nothing.
        assert _shares_to_record(1000, 5) == (0, 5)


def _totals(accepted=0, rejected=0, invalid=0, expired=0):
    return {"accepted": accepted, "rejected": rejected, "invalid": invalid, "expired": expired}


class TestSummaryDeltas:
    """#116: per-poll share-health deltas from consecutive cumulative proxy /summary totals."""

    def test_first_poll_baselines_without_backfill(self):
        cur = _totals(accepted=1000, rejected=5)
        assert _summary_deltas(None, cur) == (None, cur)

    def test_normal_delta(self):
        deltas, baseline = _summary_deltas(
            _totals(accepted=100, rejected=5), _totals(accepted=110, rejected=6, invalid=1)
        )
        assert deltas == _totals(accepted=10, rejected=1, invalid=1)
        assert baseline == _totals(accepted=110, rejected=6, invalid=1)

    def test_any_counter_backwards_rebaselines_without_negative_delta(self):
        # Proxy restart: accepted went backwards while rejected advanced — segment break, no row.
        cur = _totals(accepted=3, rejected=9)
        assert _summary_deltas(_totals(accepted=100, rejected=5), cur) == (None, cur)

    def test_all_zero_deltas_skipped(self):
        # _merge_proxy_summary repeats last-good totals on a bad poll and an idle proxy submits
        # nothing — neither may write an empty row every cycle.
        cur = _totals(accepted=100, rejected=5)
        assert _summary_deltas(_totals(accepted=100, rejected=5), cur) == (None, cur)


class TestProxyWorkerParsers:
    """The per-shape row parsers used by _normalize_proxy_workers (Issue #39)."""

    def test_parse_list_row_named_fields(self):
        # idx2=connections, idx3/4/5=accepted/rejected/invalid, idx7=last share ms, and the five
        # native hashrate windows at idx8..12 = 1m/10m/1h/12h/24h kH/s (the 1h/12h/24h ones are #168).
        row = ["rig", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 3.0, 4.0, 5.0]
        w = _parse_proxy_list_worker(row)
        assert w == {
            "name": "rig",
            "ip": "10.0.0.1",
            "status": "online",
            "h10": 1000,
            "h60": 1000,
            "h15": 2000,
            "h1h": 3000,
            "h12h": 4000,
            "h24h": 5000,
            "uptime": 0,
            "accepted": 0,
            "rejected": 0,
            "invalid": 0,
        }

    def test_parse_list_row_share_counts(self):
        # idx3=accepted, idx4=rejected, idx5=invalid are carried through (Issue #82).
        row = ["rig", "10.0.0.1", 1, 500, 7, 2, 0, 0, 1.0, 2.0, 0, 0, 0]
        w = _parse_proxy_list_worker(row)
        assert (w["accepted"], w["rejected"], w["invalid"]) == (500, 7, 2)

    def test_parse_list_row_offline_and_uptime(self):
        row = ["rig", "10.0.0.1", 0, 0, 0, 0, 0, 1_000, 1.0, 2.0, 0, 0, 0]
        w = _parse_proxy_list_worker(row)
        assert w["status"] == "offline"
        # The parser no longer estimates uptime from the last-share timestamp (#169); it starts at 0
        # and WorkerLifecycle / the direct API supply the real value.
        assert w["uptime"] == 0

    def test_parse_legacy_dict_row(self):
        w = _parse_legacy_dict_worker(
            {"id": "old", "ip": "1.2.3.4", "hashrate": [10, 20, 30], "uptime": 5}
        )
        # The legacy shape has only 10s/60s/15m, so the #168 long windows fall back to its longest
        # available average (hr[2]=30) rather than reading zero.
        assert w == {
            "name": "old",
            "ip": "1.2.3.4",
            "status": "online",
            "h10": 10,
            "h60": 20,
            "h15": 30,
            "h1h": 30,
            "h12h": 30,
            "h24h": 30,
            "uptime": 5,
            "accepted": 0,
            "rejected": 0,
            "invalid": 0,
        }

    def test_parse_legacy_dict_share_counts(self):
        # When a legacy payload happens to carry share counts, they pass through.
        w = _parse_legacy_dict_worker({"id": "old", "accepted": 9, "rejected": 1, "invalid": 0})
        assert (w["accepted"], w["rejected"], w["invalid"]) == (9, 1, 0)


class TestNormalizeProxyWorkers:
    """The two xmrig-proxy /workers payload shapes -> a uniform worker list (Issue #39)."""

    def test_list_format_online(self):
        # 6.x list: idx2=connections (1 -> online), idx8=1.0 kH/s, idx9=2.0 kH/s.
        row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        [w] = _normalize_proxy_workers({"workers": [row]})
        assert w["name"] == "rig1"
        assert w["ip"] == "10.0.0.1"
        assert w["status"] == "online"
        assert w["h10"] == 1000 and w["h60"] == 1000  # idx8 kH/s -> H/s
        assert w["h15"] == 2000  # idx9 kH/s -> H/s
        assert w["uptime"] == 0  # idx7 (last share ms) == 0

    def test_list_format_offline_when_no_connections(self):
        # A worker still listed by the proxy but with 0 connections is a stopped miner.
        row = ["rig1", "10.0.0.1", 0, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        [w] = _normalize_proxy_workers({"workers": [row]})
        assert w["status"] == "offline"

    def test_list_format_uptime_starts_at_zero(self):
        # The normalizer no longer derives uptime from the last-share timestamp (#169) — it starts at
        # 0; WorkerLifecycle (or the direct miner API) supplies the real value downstream.
        row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 1_000, 1.0, 2.0, 0, 0, 0]
        [w] = _normalize_proxy_workers({"workers": [row]})
        assert w["uptime"] == 0

    def test_short_list_row_is_skipped(self):
        # Fewer than 13 fields isn't the 6.x shape -> ignored rather than mis-parsed.
        assert _normalize_proxy_workers({"workers": [["rig1", "10.0.0.1", 1]]}) == []

    def test_legacy_dict_format(self):
        row = {"id": "old", "ip": "1.2.3.4", "hashrate": [100, 200, 300], "uptime": 50}
        [w] = _normalize_proxy_workers({"workers": [row]})
        assert w["name"] == "old"
        assert w["status"] == "online"
        assert (w["h10"], w["h60"], w["h15"]) == (100, 200, 300)
        assert w["uptime"] == 50

    def test_legacy_dict_defaults(self):
        [w] = _normalize_proxy_workers({"workers": [{}]})
        assert w["name"] == "Unknown"
        assert w["ip"] == "0.0.0.0"
        assert (w["h10"], w["h60"], w["h15"]) == (0, 0, 0)

    def test_missing_payload_returns_empty(self):
        assert _normalize_proxy_workers(None) == []
        assert _normalize_proxy_workers({}) == []
        assert _normalize_proxy_workers({"nope": 1}) == []


class TestParseProxySummary:
    """Pool-wide share totals from the proxy /summary `results` block (Issue #82)."""

    def test_extracts_results_and_best(self):
        summary = {
            "results": {
                "accepted": 1000,
                "rejected": 12,
                "invalid": 3,
                "expired": 1,
                "best": [987654, 5000, 100],
            }
        }
        assert _parse_proxy_summary(summary) == {
            "accepted": 1000,
            "rejected": 12,
            "invalid": 3,
            "expired": 1,
            "best": 987654,
        }

    def test_best_defaults_to_zero_when_empty(self):
        assert _parse_proxy_summary({"results": {"accepted": 5, "best": []}})["best"] == 0
        assert _parse_proxy_summary({"results": {"accepted": 5}})["best"] == 0

    def test_missing_results_block_zeros_out(self):
        out = _parse_proxy_summary({"version": "6.x"})
        assert out == {"accepted": 0, "rejected": 0, "invalid": 0, "expired": 0, "best": 0}

    def test_malformed_payload_returns_empty(self):
        assert _parse_proxy_summary(None) == {}
        assert _parse_proxy_summary([1, 2, 3]) == {}
        assert _parse_proxy_summary("nope") == {}


class TestMergeProxySummary:
    """A malformed (non-raising) /summary must keep the last-good totals, not blank them (#141)."""

    _GOOD = {"accepted": 1000, "rejected": 12, "invalid": 3, "expired": 1, "best": 987654}
    _LAST = {"accepted": 999, "rejected": 9, "invalid": 1, "expired": 0, "best": 42}

    def test_valid_summary_is_adopted(self):
        summary = {
            "results": {
                "accepted": 1000,
                "rejected": 12,
                "invalid": 3,
                "expired": 1,
                "best": [987654],
            }
        }
        assert _merge_proxy_summary(self._LAST, summary) == self._GOOD

    def test_malformed_payload_keeps_last_good(self):
        # A non-dict body (None / list / str) parses to {} without raising — must fall back, not wipe.
        for bad in (None, [1, 2, 3], "nope"):
            assert _merge_proxy_summary(self._LAST, bad) == self._LAST

    def test_valid_zero_summary_is_adopted_not_treated_as_malformed(self):
        # A real dict summary (even one reporting all-zeros / no results) is non-empty after parse —
        # adopt it, don't keep stale. Only a non-dict body is "malformed" per #141.
        zeros = {"accepted": 0, "rejected": 0, "invalid": 0, "expired": 0, "best": 0}
        assert _merge_proxy_summary(self._LAST, {"version": "6.x"}) == zeros


class TestWorkerLifecycle:
    """Per-worker connection tracking: true uptime (#169) + stale-row fall-off (#182)."""

    @staticmethod
    def _w(name, status, uptime=0):
        return {"name": name, "status": status, "uptime": uptime}

    def test_online_uptime_counts_from_first_seen(self):
        lc = WorkerLifecycle(falloff_sec=3600)
        [w] = lc.update([self._w("rig", "online")], now=1000.0)
        assert w["uptime"] == 0  # just connected
        [w] = lc.update([self._w("rig", "online")], now=1075.0)
        assert w["uptime"] == 75  # now - connected_since, monotonic

    def test_real_api_uptime_is_not_overwritten(self):
        # A worker whose direct API is reachable already carries a real (>0) uptime — keep it.
        lc = WorkerLifecycle(falloff_sec=3600)
        [w] = lc.update([self._w("rig", "online", uptime=999)], now=1000.0)
        assert w["uptime"] == 999

    def test_offline_worker_shown_until_falloff_then_dropped(self):
        lc = WorkerLifecycle(falloff_sec=3600)
        lc.update([self._w("rig", "online")], now=1000.0)  # active at t=1000
        kept = lc.update([self._w("rig", "offline")], now=4000.0)  # 3000s later: within 1h window
        assert [w["name"] for w in kept] == ["rig"]  # still shown (as DOWN)
        gone = lc.update([self._w("rig", "offline")], now=5000.0)  # 4000s since active: > falloff
        assert gone == []  # fell off the table

    def test_fallen_off_worker_stays_gone_while_proxy_keeps_reporting_it(self):
        # Regression (#182): xmrig-proxy keeps a disconnected worker in /workers for HOURS, so the
        # lifecycle must not let a fallen-off ghost reappear. Previously, dropping the worker from
        # internal state at falloff meant the next poll re-created it with last_active=now, resetting
        # the 1h clock — the row flickered off for one cycle then came back as DOWN forever.
        lc = WorkerLifecycle(falloff_sec=3600)
        lc.update([self._w("rig", "online")], now=1000.0)  # active at t=1000
        assert lc.update([self._w("rig", "offline")], now=4700.0) == []  # 3700s > falloff → dropped
        # The proxy STILL reports it offline on every subsequent poll — it must stay gone, not flicker.
        for t in (4730.0, 8400.0, 8430.0, 30000.0):
            assert lc.update([self._w("rig", "offline")], now=t) == [], f"ghost reappeared at t={t}"
        # A genuine reconnect still re-adds it, fresh.
        [w] = lc.update([self._w("rig", "online")], now=30030.0)
        assert w["uptime"] == 0

    def test_reconnect_restarts_uptime_and_readds(self):
        lc = WorkerLifecycle(falloff_sec=10)
        lc.update([self._w("rig", "online")], now=1000.0)
        lc.update([], now=2000.0)  # proxy drops it entirely (fell off)
        [w] = lc.update([self._w("rig", "online")], now=3000.0)  # reconnects fresh
        assert w["uptime"] == 0  # uptime restarts, not inherited
        [w] = lc.update([self._w("rig", "online")], now=3050.0)
        assert w["uptime"] == 50

    def test_offline_then_online_resets_connected_since(self):
        lc = WorkerLifecycle(falloff_sec=3600)
        lc.update([self._w("rig", "online")], now=1000.0)
        lc.update([self._w("rig", "offline")], now=1100.0)  # disconnect resets connected_since
        [w] = lc.update([self._w("rig", "online")], now=1200.0)  # back online — counts from here
        assert w["uptime"] == 0


class TestMergeDirectStats:
    """Augment proxy workers with direct-API stats; kind-based scaling + keep-online (#39/#28)."""

    def _worker(self):
        return {
            "name": "rig",
            "ip": "10.0.0.1",
            "status": "online",
            "h10": 1,
            "h60": 2,
            "h15": 3,
            "uptime": 0,
        }

    def test_proxy_kind_scales_khs_to_hs(self):
        # A successful probe carries api_ok=True (injected by get_stats); enrichment applies.
        extra = {"api_ok": True, "kind": "proxy", "uptime": 120, "hashrate": {"total": [1, 2, 3]}}
        [w] = _merge_direct_stats([self._worker()], [extra], "3333")
        assert (w["h10"], w["h60"], w["h15"]) == (1000, 2000, 3000)
        assert w["uptime"] == 120
        assert w["active_pool"] == "3333"
        assert w["api_ok"] is True

    def test_xmrig_kind_not_scaled(self):
        extra = {"api_ok": True, "uptime": 99, "hashrate": {"total": [10, 20, 30]}}
        [w] = _merge_direct_stats([self._worker()], [extra], "3344")
        assert (w["h10"], w["h60"], w["h15"]) == (10, 20, 30)
        assert w["active_pool"] == "3344"
        assert w["api_ok"] is True

    def test_failed_probe_flags_api_ok_false_keeps_proxy_values_online(self):
        # A surfaced failure (api_ok=False) keeps proxy-derived hashrate/uptime and stays online
        # (#28) but flags the worker so the UI can distinguish "API misconfigured" from "offline".
        w0 = self._worker()
        [w] = _merge_direct_stats([w0], [{"api_ok": False}], "3333")
        assert w["status"] == "online"
        assert (w["h10"], w["h60"], w["h15"]) == (1, 2, 3)  # untouched
        assert w["api_ok"] is False
        assert w["active_pool"] == "3333"

    def test_skipped_probe_leaves_api_ok_unset(self):
        # An empty result is a worker we deliberately didn't probe (SSRF guard): unknown, not a
        # failure — keep proxy values, stay online, and don't claim an api_ok verdict.
        w0 = self._worker()
        [w] = _merge_direct_stats([w0], [{}], "3333")
        assert w["status"] == "online"
        assert (w["h10"], w["h60"], w["h15"]) == (1, 2, 3)  # untouched
        assert "api_ok" not in w
        assert w["active_pool"] == "3333"

    def test_short_hashrate_total_ignored(self):
        # A <3-entry total isn't applied; uptime still updates and active_pool is tagged.
        extra = {"api_ok": True, "uptime": 7, "hashrate": {"total": [5, 6]}}
        [w] = _merge_direct_stats([self._worker()], [extra], "3333")
        assert (w["h10"], w["h60"], w["h15"]) == (1, 2, 3)
        assert w["uptime"] == 7

    def test_rigforge_block_carried_onto_worker(self):
        # A RigForge enriched feed (#235) rides in on the same result; the parsed block reaches the
        # worker model. A plain-xmrig result leaves no `rigforge` key.
        extra = {
            "api_ok": True,
            "hashrate": {"total": [1, 2, 3]},
            "rigforge": {"version": "1.7.0", "power": {"watts": 100.0, "hs_per_watt": 50.0}},
        }
        [w] = _merge_direct_stats([self._worker()], [extra], "3333")
        assert w["rigforge"]["version"] == "1.7.0"
        assert w["rigforge"]["power"] == {"watts": 100.0, "hs_per_watt": 50.0}

        [plain] = _merge_direct_stats([self._worker()], [{"api_ok": True}], "3333")
        assert "rigforge" not in plain


class TestAggregateHashrate:
    """Total live hashrate, priority 15m > 60s > 10s, online-only (Issue #39)."""

    def test_prefers_h15(self):
        workers = [{"status": "online", "h15": 2000, "h60": 1000, "h10": 500}]
        assert _aggregate_hashrate(workers) == (2000, 500)

    def test_falls_back_to_h60_then_h10(self):
        workers = [
            {"status": "online", "h15": 0, "h60": 1500, "h10": 500},  # uses h60
            {"status": "online", "h15": 0, "h60": 0, "h10": 700},  # uses h10
        ]
        total_h15, total_h10 = _aggregate_hashrate(workers)
        assert total_h15 == 1500 + 700
        assert total_h10 == 500 + 700

    def test_offline_excluded(self):
        workers = [
            {"status": "online", "h15": 1000, "h10": 100},
            {"status": "offline", "h15": 9999, "h10": 9999},
        ]
        assert _aggregate_hashrate(workers) == (1000, 100)

    def test_empty(self):
        assert _aggregate_hashrate([]) == (0, 0)


class TestAggregateWindowHashrates:
    """Per-averaging-window totals for the chart toggle (#168). Each window is its own honest sum —
    no fallback between windows — and offline workers contribute nothing."""

    def test_sums_each_window_independently(self):
        workers = [
            {"status": "online", "h10": 100, "h1h": 300, "h12h": 1200, "h24h": 2400},
            {"status": "online", "h10": 50, "h1h": 150, "h12h": 600, "h24h": 1200},
        ]
        assert _aggregate_window_hashrates(workers) == {
            "1m": 150,
            "1h": 450,
            "12h": 1800,
            "24h": 3600,
        }

    def test_no_fallback_between_windows(self):
        # Unlike the headline aggregate, a not-yet-filled long window stays low rather than borrowing
        # a shorter window's value — a fresh rig reads ~0 on 24h even with a healthy 1m.
        workers = [{"status": "online", "h10": 1000, "h1h": 0, "h12h": 0, "h24h": 0}]
        totals = _aggregate_window_hashrates(workers)
        assert totals == {"1m": 1000, "1h": 0, "12h": 0, "24h": 0}

    def test_offline_excluded_and_missing_keys_zero(self):
        workers = [
            {"status": "online", "h10": 100},  # missing long windows -> 0
            {"status": "offline", "h10": 9999, "h1h": 9999, "h24h": 9999},  # excluded entirely
        ]
        assert _aggregate_window_hashrates(workers) == {"1m": 100, "1h": 0, "12h": 0, "24h": 0}

    def test_empty(self):
        assert _aggregate_window_hashrates([]) == {"1m": 0, "1h": 0, "12h": 0, "24h": 0}


class TestInit:
    def test_restores_snapshot(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = {"total_live_h15": 5000, "extra": "kept"}
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.latest_data["total_live_h15"] == 5000
        assert svc.latest_data["extra"] == "kept"

    def test_restored_snapshot_never_resurrects_the_update_badge(self):
        # #664: `update` is derived state — a pre-upgrade "new release available" restored after
        # the very upgrade it advertised must be dropped; the checker recomputes on its cadence.
        sm = MagicMock()
        sm.load_snapshot.return_value = {
            "total_live_h15": 5000,
            "update": {"available": True, "latest": "v1.9.1", "url": "u"},
            # #596: same rule for the fleet-wide RigForge release — restored with the flag now
            # off, it would keep serving stale per-worker badges until the first poll cycle.
            "rigforge_release": {"tag": "v1.11.2", "url": "u"},
        }
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.latest_data.get("update") in (None, {})  # never the restored dict
        assert svc.latest_data.get("rigforge_release") is None  # nor the RigForge one (#596)
        assert svc.latest_data["total_live_h15"] == 5000  # the rest of the snapshot survives

    def test_rigforge_checker_wired_to_the_rigforge_api_under_the_same_flag(self):
        # #596 wiring: one fleet-wide RigForge release checker, pointed at the RigForge repo,
        # gated on the SAME dashboard.check_for_updates flag as the stack's own check.
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.rigforge_update_checker.client.api_url == ds_mod.GITHUB_RIGFORGE_RELEASES_API
        assert "rigforge" in svc.rigforge_update_checker.client.api_url
        assert svc.rigforge_update_checker.enabled == svc.update_checker.enabled
        assert svc.rigforge_update_checker.client.tor_proxy == svc.update_checker.client.tor_proxy

    def test_ignores_non_dict_snapshot(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.latest_data["total_live_h15"] == 0

    def test_restores_workers_rejected_flag(self):
        # A dashboard restart mid-outage must remember it had rejected workers, so it can
        # readmit them on recovery (Issue #31).
        sm = MagicMock()
        sm.load_snapshot.return_value = {"workers_rejected": True}
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.workers_rejected is True

    def test_restores_miner_released_latch(self):
        # A restart after the miner was released must NOT re-hold a running, mining stack (#35).
        sm = MagicMock()
        sm.load_snapshot.return_value = {"miner_released": True}
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.miner_released is True

    def test_holds_miner_when_restart_mid_sync(self):
        # Fresh state (no snapshot) → the miner is held until the gate is first satisfied.
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.miner_released is False


class TestWorkerRejection:
    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc

    def _tari(self, required=True):
        # Tari's "is it required?" flag, patched in the data_service module namespace.
        return patch.object(ds_mod, "TARI_REQUIRED", required)

    async def test_stop_when_monero_down(self):
        # monerod is required, so its outage always rejects — even with Tari non-blocking.
        svc = self._svc()
        with (
            self._tari(required=False),
            patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"),
        ):
            await svc._apply_worker_rejection(monero_down=True, tari_down=False)
        svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
        assert svc.workers_rejected is True

    async def test_stop_when_tari_down_and_required(self):
        svc = self._svc()
        with self._tari(required=True):
            await svc._apply_worker_rejection(monero_down=False, tari_down=True)
        svc.docker_control.stop.assert_awaited_once()
        assert svc.workers_rejected is True

    async def test_tari_down_ignored_when_non_blocking(self):
        # A Tari-only outage must NOT reject workers when Tari is non-blocking — we can still
        # mine Monero on p2pool.
        svc = self._svc()
        with self._tari(required=False):
            await svc._apply_worker_rejection(monero_down=False, tari_down=True)
        svc.docker_control.stop.assert_not_called()
        assert svc.workers_rejected is False

    async def test_stop_failure_keeps_flag_false_for_retry(self):
        svc = self._svc()
        svc.docker_control.stop = AsyncMock(return_value=False)
        with self._tari():
            await svc._apply_worker_rejection(monero_down=True, tari_down=False)
        assert svc.workers_rejected is False  # so the next cycle retries

    async def test_no_double_stop_when_already_rejected(self):
        svc = self._svc()
        svc.workers_rejected = True
        with self._tari():
            await svc._apply_worker_rejection(monero_down=True, tari_down=True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()

    async def test_readmit_when_relevant_nodes_healthy(self):
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = True
        svc.tari_health.healthy = True
        with self._tari(required=True):
            await svc._apply_worker_rejection(monero_down=False, tari_down=False)
        svc.docker_control.start.assert_awaited_once()
        assert svc.workers_rejected is False

    async def test_no_readmit_while_a_relevant_node_unconfirmed(self):
        # Rejected + nodes no longer "down", but a node we reject on isn't yet confirmed
        # healthy (e.g. fresh after restart) → do NOT readmit to a possibly-still-down stack.
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = True
        svc.tari_health.healthy = False
        with self._tari(required=True):
            await svc._apply_worker_rejection(monero_down=False, tari_down=False)
        svc.docker_control.start.assert_not_called()
        assert svc.workers_rejected is True

    async def test_readmit_ignores_tari_when_non_blocking(self):
        # Tari non-blocking → Tari health is irrelevant to readmission; monerod healthy is enough.
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = True
        svc.tari_health.healthy = False
        with self._tari(required=False):
            await svc._apply_worker_rejection(monero_down=False, tari_down=False)
        svc.docker_control.start.assert_awaited_once()
        assert svc.workers_rejected is False

    async def test_no_readmit_until_monero_healthy_even_if_tari_non_blocking(self):
        # monerod is mandatory: never readmit while it's unconfirmed, regardless of Tari.
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = False
        with self._tari(required=False):
            await svc._apply_worker_rejection(monero_down=False, tari_down=False)
        svc.docker_control.start.assert_not_called()
        assert svc.workers_rejected is True


class TestSyncGate:
    """Hold p2pool + xmrig-proxy until the required chain(s) finish their initial sync (#35)."""

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc

    async def test_holds_all_containers_when_not_synced(self):
        svc = self._svc()
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]):
            await svc._apply_sync_gate(gate_satisfied=False)
        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        assert svc.miner_held is True
        assert svc.miner_released is False

    async def test_releases_when_gate_satisfied(self):
        svc = self._svc()
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]):
            await svc._apply_sync_gate(gate_satisfied=True)
        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        svc.docker_control.stop.assert_not_called()
        assert svc.miner_released is True
        assert svc.miner_held is False

    async def test_noop_once_released(self):
        # One-way latch: after release we never touch the containers again, so a later
        # not-synced reading (e.g. a node blip) can't fight #31 by re-stopping the miner.
        svc = self._svc()
        svc.miner_released = True
        await svc._apply_sync_gate(gate_satisfied=False)
        await svc._apply_sync_gate(gate_satisfied=True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()

    async def test_partial_start_failure_keeps_latch_closed(self):
        # If only one container starts, stay unreleased so the next cycle retries the rest.
        svc = self._svc()
        svc.docker_control.start = AsyncMock(side_effect=[True, False])
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]):
            await svc._apply_sync_gate(gate_satisfied=True)
        assert svc.miner_released is False

    async def test_rehold_stops_quietly_after_first_cycle(self):
        # The first hold logs (quiet=False); subsequent re-asserts are quiet so a multi-hour
        # sync doesn't flood the dashboard log.
        svc = self._svc()
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_sync_gate(gate_satisfied=False)
            await svc._apply_sync_gate(gate_satisfied=False)
        first, second = svc.docker_control.stop.await_args_list
        assert first.kwargs.get("quiet") is False
        assert second.kwargs.get("quiet") is True


class TestFailClosedGate:
    """Opt-in (dashboard.fail_closed, #490) miner hold on an unrecoverable health failure —
    reuses the #35 sync gate's own stop/start mechanism over SYNC_GATE_CONTAINERS, but (unlike
    the sync gate) is not a one-way latch: it re-checks every cycle and releases once the
    unrecoverable condition clears."""

    def _svc(self, released=True):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        svc.miner_released = released
        return svc

    def _enabled(self, on=True):
        return patch.object(ds_mod, "DASHBOARD_FAIL_CLOSED", on)

    async def test_default_off_never_touches_containers(self):
        # dashboard.fail_closed defaults False — an unrecoverable failure must only ever alert
        # (elsewhere), never hold. A cosmetic dashboard fault must not idle the fleet.
        svc = self._svc()
        with (
            self._enabled(False),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()
        assert svc.fail_closed_held is False

    async def test_noop_before_sync_gate_releases_the_miner(self):
        # Holding before the sync gate has released is already #35's job — engaging here too
        # would just be a second, redundant hold path.
        svc = self._svc(released=False)
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=True)
        svc.docker_control.stop.assert_not_called()
        assert svc.fail_closed_held is False

    async def test_holds_when_enabled_and_unrecoverable(self):
        svc = self._svc()
        with (
            self._enabled(True),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=True)
        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        assert svc.fail_closed_held is True

    async def test_rehold_stops_quietly_after_first_cycle(self):
        svc = self._svc()
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=True)
            await svc._apply_fail_closed_gate(unrecoverable=True)
        first, second = svc.docker_control.stop.await_args_list
        assert first.kwargs.get("quiet") is False
        assert second.kwargs.get("quiet") is True

    async def test_releases_once_condition_clears(self):
        # Unlike the sync gate's one-way latch, this must release on its own once the
        # unrecoverable condition clears (an operator fix + restart, no full stack restart).
        svc = self._svc()
        svc.fail_closed_held = True
        with (
            self._enabled(True),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=False)
        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        svc.docker_control.stop.assert_not_called()
        assert svc.fail_closed_held is False

    async def test_partial_start_failure_stays_held(self):
        svc = self._svc()
        svc.fail_closed_held = True
        svc.docker_control.start = AsyncMock(side_effect=[True, False])
        with (
            self._enabled(True),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=False)
        assert svc.fail_closed_held is True  # next cycle retries

    async def test_not_a_one_way_latch_can_rehold_after_release(self):
        # The defining difference from the #35 sync gate: a later unrecoverable condition (a
        # second DB-recovery failure) must be able to hold again after an earlier release.
        svc = self._svc()
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=True)
            assert svc.fail_closed_held is True
            await svc._apply_fail_closed_gate(unrecoverable=False)
            assert svc.fail_closed_held is False
            await svc._apply_fail_closed_gate(unrecoverable=True)
            assert svc.fail_closed_held is True

    async def test_healthy_and_never_held_is_a_noop(self):
        svc = self._svc()
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=False)
        svc.docker_control.start.assert_not_called()
        svc.docker_control.stop.assert_not_called()

    async def test_real_trigger_a_transient_unhealthy_dashboard_does_not_gate(self):
        # #490 F1/F2: wire the ACTUAL trigger expression the run loop computes
        # (is_db_unrecoverable OR containers.is_confirmed_bad("dashboard")) from real objects, and
        # prove a first-sighting-unhealthy dashboard (a seed, unvetted by the 120s debounce) does
        # NOT hold the fleet. The hardcoded-bool gate tests above cover the mechanism; this covers
        # the classification that feeds it.
        from mining_dashboard.service.storage_service import StateManager

        svc = self._svc()
        sm = StateManager(db_path=":memory:")
        try:
            svc.state_manager = sm
            svc.alert_service.containers.update(
                {
                    "dashboard": {
                        "running": True,
                        "restarting": False,
                        "restart_count": 0,
                        "health": "unhealthy",
                    }
                }
            )
            assert sm.is_db_unrecoverable() is False  # healthy DB
            trigger = sm.is_db_unrecoverable() or svc.alert_service.containers.is_confirmed_bad(
                "dashboard"
            )
            assert trigger is False  # seed is not confirmed -> no gate
            with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
                await svc._apply_fail_closed_gate(trigger)
            svc.docker_control.stop.assert_not_called()
            assert svc.fail_closed_held is False
        finally:
            sm.close()


class TestRunIteration:
    async def test_single_iteration_aggregates(self):
        svc, sm, proxy = _make_service()

        # A proxy worker in the 6.x list format (>=13 fields): connections=1 (online),
        # idx8=1.0 kH/s, idx9=2.0 kH/s -> h15 = 2000 H/s.
        worker_row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        proxy.get_workers.return_value = {"workers": [worker_row]}
        proxy.get_summary.return_value = {
            "results": {
                "accepted": 100,
                "rejected": 5,
                "invalid": 1,
                "expired": 2,
                "best": [123456],
            }
        }

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})  # direct API unreachable
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(
                    return_value={
                        "is_syncing": False,
                        "percent": 100,
                        "target": 100,
                        "current": 100,
                    }
                ),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        # The worker was aggregated and totals computed from proxy-derived hashrate.
        assert svc.latest_data["workers"][0]["name"] == "rig1"
        assert svc.latest_data["workers"][0]["status"] == "online"
        assert svc.latest_data["total_live_h15"] == 2000.0
        # The proxy /summary totals were collected and surfaced (Issue #82).
        assert svc.latest_data["proxy_summary"] == {
            "accepted": 100,
            "rejected": 5,
            "invalid": 1,
            "expired": 2,
            "best": 123456,
        }
        sm.update_history.assert_called()
        sm.save_snapshot.assert_called()

    async def test_share_stat_deltas_persisted(self):
        # #116 wiring: with a baseline from a previous poll, one iteration writes the counters'
        # deltas via add_share_stats (the delta rules themselves are unit-tested above).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        proxy.get_summary.return_value = {
            "results": {"accepted": 110, "rejected": 6, "invalid": 1, "expired": 2, "best": [1]}
        }
        svc._last_share_totals = _totals(accepted=100, rejected=5, invalid=1, expired=2)

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "percent": 100}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        # Only accepted (+10) and rejected (+1) advanced; the deltas — not the counters — landed.
        assert sm.add_share_stats.call_args.kwargs == {
            "accepted": 10,
            "rejected": 1,
            "invalid": 0,
            "expired": 0,
        }
        # Baseline advanced to the new cumulative totals for the next poll.
        assert svc._last_share_totals == _totals(accepted=110, rejected=6, invalid=1, expired=2)

    async def test_degradation_edge_records_event_and_alerts(self):
        # #99 wiring: when the detector reports an edge, the loop persists a chart marker and pushes
        # the hashrate_loss alert. Stub the detector so a single iteration produces a deterministic
        # edge (the debounce itself is unit-tested in test_degradation.py).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        proxy.get_summary.return_value = {"results": {}}
        svc.degradation = MagicMock()
        svc.degradation.update.return_value = ("loss", 0.6, 1000.0, 400.0)
        svc.alert_service.degradation_alert = AsyncMock()

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "percent": 100}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        assert sm.add_event.call_args.args[1] == "hashrate_loss"
        svc.alert_service.degradation_alert.assert_awaited_once_with("loss", 0.6)

    async def test_run_holds_miner_while_syncing(self):
        # A syncing Monero node → gate holds p2pool + xmrig-proxy and #31's failover stays
        # dormant (no workers to fail over before we've even started mining).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc._apply_worker_rejection = AsyncMock()

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={"is_syncing": False, "reachable": True}
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(
                    return_value={
                        "is_syncing": True,
                        "reachable": True,
                        "percent": 50,
                        "current": 50,
                        "target": 100,
                    }
                ),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        svc._apply_worker_rejection.assert_not_called()
        assert svc.miner_released is False
        assert svc.latest_data["miner_held"] is True

    async def test_run_wires_computed_signals_into_the_alerter(self):
        # Wiring guard: the unit tests prove each signal → the right alert in isolation; this proves
        # the data loop actually hands the alerter the full contract each cycle (so a dropped/renamed
        # kwarg, or forgetting the daily-summary call, fails here rather than silently going dark).
        svc, sm, proxy = _make_service()
        sm.is_db_healthy.return_value = True
        proxy.get_workers.return_value = {"workers": []}
        svc._apply_worker_rejection = AsyncMock()
        svc.alert_service = MagicMock()
        # Disabled → the loop skips the per-cycle build_metrics (a MagicMock state_manager can't feed
        # it); process()/maybe_daily_summary are still called every cycle regardless.
        svc.alert_service.enabled = False
        svc.alert_service.process = AsyncMock()
        svc.alert_service.maybe_daily_summary = AsyncMock()

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={"is_syncing": False, "reachable": True}
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(ds_mod, "get_tari_stats", return_value={"active": True, "height": 3}),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "reachable": True}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={"percent": 42}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        svc.alert_service.process.assert_awaited_once()
        kw = svc.alert_service.process.await_args.kwargs
        # The full signal contract the AlertService.evaluate() unit tests rely on.
        assert set(kw) >= {
            "monero_down",
            "tari_down",
            "tari_required",
            "miner_released",
            "workers",
            "workers_expected",
            "disk_percent",
            "db_healthy",
            "xvb_enabled",
            "shares_in_window",
            "clearnet_active",
            "xvb_registration_state",
            "update_available",
            "low_hr_warning",
            "hugepages_reserved",
            "low_ram",
            "blocks_found_total",
            "block_height",
            "containers",
        }
        # ...sourced from the real computed values, not placeholders.
        assert kw["db_healthy"] is True  # from state_manager.is_db_healthy()
        assert kw["disk_percent"] == 42  # from get_disk_usage()
        assert isinstance(kw["workers"], list)
        # The once-daily digest is wired in too.
        svc.alert_service.maybe_daily_summary.assert_awaited_once()

    async def test_run_releases_despite_height_override(self):
        # Both nodes are synced per their RPC/gRPC, but p2pool is held so its stats file is
        # empty → get_network_stats height 0 trips the UI "syncing" override. The gate must
        # key off the raw sync signals (captured before the override) or it would deadlock,
        # never starting p2pool because p2pool isn't running. (Releases → start the miner.)
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={"is_syncing": False, "reachable": True}
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 0}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "reachable": True}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        assert svc.miner_released is True
        # The UI override still marks Monero as syncing for display — that's fine; only the
        # gate must ignore it.
        assert svc.latest_data["monero_sync"]["is_syncing"] is True

    async def test_run_nonblocking_tari_releases_and_stays_operational(self):
        # Monero synced, Tari still syncing, Tari non-blocking (#51): release the miner (don't
        # wait for Tari), keep the operational view (global_sync False), and flag Tari's
        # passive sync so the UI shows a "Tari syncing" indicator instead of the takeover.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={
                "is_syncing": True,
                "reachable": True,
                "percent": 42,
                "current": 42,
                "target": 100,
            }
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "TARI_REQUIRED", False),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "reachable": True}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        assert svc.miner_released is True
        assert svc.latest_data["global_sync"] is False
        assert svc.latest_data["tari_syncing_passive"] is True

    async def _run_one_iteration(self, svc, monero_sync, tari_sync):
        """Drive a single loop iteration with the given per-node sync signals."""
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value=tari_sync)
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            # The real get_stratum_stats returns a dict ({} on a missing/unreadable stats file);
            # the wallet tripwire (#375) reads .get("wallet") off it, so the mock must match.
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(ds_mod, "get_monero_sync_status", AsyncMock(return_value=monero_sync)),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

    async def test_stale_monitor_not_fed_without_a_synchronized_verdict(self):
        # No `synchronized` key (log-scrape fallback / remote node) = no verdict (#972): the
        # stale monitor must not be fed, so its streaks stay put across blind cycles.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.monero_sync_stale = MagicMock()
        svc.monero_sync_stale.down = False
        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": True},
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.monero_sync_stale.update.assert_not_called()
        assert svc.latest_data["monero_sync"]["stale"] is False

    async def test_stale_flag_fed_surfaced_and_passed_to_the_alerter(self):
        # RPC verdict present (#972): the monitor is fed the raw flag, its debounced `down`
        # lands in the snapshot as `stale`, and the alerter receives it as monero_stale.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.monero_sync_stale = MagicMock()
        svc.monero_sync_stale.down = True
        svc.alert_service.process = AsyncMock(return_value=[])
        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": True, "synchronized": False},
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.monero_sync_stale.update.assert_called_once_with(False)
        assert svc.latest_data["monero_sync"]["stale"] is True
        assert svc.alert_service.process.await_args.kwargs["monero_stale"] is True

    async def test_healthchecks_pinged_when_healthy(self):
        # Enabled + healthy → a plain liveness ping (no args) each cycle.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.healthchecks = MagicMock()
        svc.healthchecks.enabled = True
        svc.healthchecks.ping.return_value = True

        await self._run_one_iteration(
            svc,
            monero_sync={
                "is_syncing": False,
                "reachable": True,
                "percent": 100,
                "current": 100,
                "target": 100,
            },
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.healthchecks.ping.assert_called_once_with()

    async def test_healthchecks_pinged_even_when_a_node_is_down(self):
        # Pure dead-man's switch: the heartbeat reports only that the STACK is alive, so a node
        # being down must NOT change or suppress the ping (that's the Telegram alerter's job, #121).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.healthchecks = MagicMock()
        svc.healthchecks.enabled = True
        svc.healthchecks.ping.return_value = True

        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": False},  # monerod down
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.healthchecks.ping.assert_called_once_with()

    async def test_healthchecks_not_pinged_when_disabled(self):
        # Default: the disabled client is never invoked from the loop (no worker thread).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.healthchecks = MagicMock()
        svc.healthchecks.enabled = False

        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": True},
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.healthchecks.ping.assert_not_called()

    async def test_iteration_survives_collector_error(self):
        svc, sm, proxy = _make_service()
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={})

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", side_effect=RuntimeError("boom")),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            # The error is caught inside the loop; the sleep after it raises to stop us.
            with pytest.raises(StopAsyncIteration):
                await svc.run()


class TestControlPlaneComposition:
    """Compositions of the sync-gate (#35) and failover (#31) the per-feature tests don't
    cover on their own: the required-Tari hold, and the two features coexisting after release."""

    async def test_run_holds_when_tari_required_and_only_monero_synced(self):
        # Monero synced, Tari still syncing, Tari REQUIRED: the gate condition
        # `monero_synced AND (tari_synced OR NOT TARI_REQUIRED)` is NOT satisfied, so the
        # miner stays held until Tari also finishes — the mirror of the non-blocking case.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc._apply_worker_rejection = AsyncMock()

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={
                "is_syncing": True,
                "reachable": True,
                "percent": 80,
                "current": 80,
                "target": 100,
            }
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "TARI_REQUIRED", True),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "reachable": True}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        assert svc.miner_released is False
        assert svc.latest_data["miner_held"] is True

    async def test_post_release_blip_lets_failover_act_without_rehold(self):
        # After release, a node-down event must NOT be re-held by the sync gate (the #35
        # one-way latch), yet #31 failover must still stop the proxy so workers fail over.
        # The two coexist: gate no-ops, rejection acts on the proxy only.
        svc, _sm, _proxy = _make_service()
        svc.miner_released = True
        with (
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"),
            patch.object(ds_mod, "TARI_REQUIRED", True),
        ):
            await svc._apply_sync_gate(gate_satisfied=False)  # latch → no-op
            await svc._apply_worker_rejection(monero_down=True, tari_down=False)
        stopped = [c.args[0] for c in svc.docker_control.stop.await_args_list]
        assert stopped == ["xmrig-proxy"]  # p2pool was NOT re-held
        svc.docker_control.start.assert_not_called()
        assert svc.workers_rejected is True

    async def test_both_nodes_down_rejects_once(self):
        # A simultaneous Monero+Tari outage (both required) is a single rejection, not two.
        svc, _sm, _proxy = _make_service()
        with (
            patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"),
            patch.object(ds_mod, "TARI_REQUIRED", True),
        ):
            await svc._apply_worker_rejection(monero_down=True, tari_down=True)
        svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
        assert svc.workers_rejected is True


class TestXvbRewardEstimatesSync:
    """XvB published per-tier reward-estimate fetch (#118)."""

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        xvb = MagicMock()
        return DataService(sm, MagicMock(), xvb), sm, xvb

    async def test_success_caches_estimates(self):
        svc, sm, xvb = self._svc()
        xvb.get_reward_estimates.return_value = {"donor": 0.06, "donor_mega": 56.9}
        await svc._sync_xvb_reward_estimates()
        sm.set_xvb_reward_estimates.assert_called_once_with({"donor": 0.06, "donor_mega": 56.9})

    async def test_failed_fetch_writes_nothing(self):
        # None (failed/unparseable) must leave the cache + last_update frozen so staleness is
        # detectable (#311) — never overwrite the last-good estimates with an empty set.
        svc, sm, xvb = self._svc()
        xvb.get_reward_estimates.return_value = None
        await svc._sync_xvb_reward_estimates()
        sm.set_xvb_reward_estimates.assert_not_called()


class TestXvbAutoRegister:
    """XvB raffle auto-registration gating (#263)."""

    def _svc(self, submit_url="https://xvb.example/submit"):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        xvb = MagicMock()
        xvb.submit_url = submit_url  # configured by default; pass "" for the unconfigured case
        svc = DataService(sm, MagicMock(), xvb)
        return svc, sm, xvb

    def _stats(self, pplns_window=2160, pool_type="Main"):
        return {"p2p": {"type": pool_type}, "pool": {"pplns_window": pplns_window}}

    def _fresh_share(self):
        return [{"ts": time.time()}]

    def _state_writes(self, sm):
        """Merged kwargs across all update_xvb_stats calls (the persisted XvB-state writes)."""
        merged = {}
        for call in sm.update_xvb_stats.call_args_list:
            merged.update(call.kwargs)
        return merged

    async def test_no_share_does_not_register(self):
        # Endpoint only takes effect with a PPLNS share, so we don't even call it before then.
        svc, _sm, xvb = self._svc()
        await svc._maybe_register_xvb(shares=[], p2pool_stats=self._stats())
        xvb.register.assert_not_called()
        assert svc._xvb_last_registered is None

    async def test_stale_share_outside_window_does_not_register(self):
        svc, _sm, xvb = self._svc()
        # 2160 blocks * 10s = 6h window; a share 7h old is outside it.
        stale = [{"ts": time.time() - 7 * 3600}]
        await svc._maybe_register_xvb(shares=stale, p2pool_stats=self._stats())
        xvb.register.assert_not_called()

    async def test_registers_once_eligible(self):
        # REG_OK covers both a fresh 2xx and the idempotent "already registered" steady state.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_OK
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_called_once()
        assert svc._xvb_last_registered is not None
        writes = self._state_writes(sm)
        assert "registered_at" in writes
        assert writes["registration_state"] == "registered"

    async def test_transient_error_retries_next_poll(self):
        # A transient error must NOT latch the timestamp, so the next eligible poll retries; and one
        # blip stays below the failing threshold (no dashboard warning yet).
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_ERROR
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_last_registered is None
        assert svc._xvb_register_failures == 1
        assert "registration_state" not in self._state_writes(sm)

    async def test_not_eligible_is_quiet_retry(self):
        # Local share hasn't propagated to XvB yet => retry quietly, NOT counted as a failure.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_NOT_ELIGIBLE
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_register_failures == 0
        sm.update_xvb_stats.assert_not_called()
        assert svc._xvb_last_registered is None  # not registered, will retry

    async def test_invalid_wallet_latches_and_warns(self, caplog):
        # Permanent rejection: surface "invalid", warn once, and stop calling the endpoint.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_INVALID
        with caplog.at_level("WARNING"):
            await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
            await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_called_once()  # latched after the first rejection — no re-hammering
        assert self._state_writes(sm)["registration_state"] == "invalid"
        assert sum("rejected MONERO_WALLET_ADDRESS" in r.message for r in caplog.records) == 1

    async def test_skips_when_recently_registered(self):
        svc, _sm, xvb = self._svc()
        svc._xvb_last_registered = time.time()  # just registered
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_not_called()

    async def test_reregisters_after_interval(self):
        # Idempotent daily re-register once the cadence elapses.
        svc, _sm, xvb = self._svc()
        xvb.register.return_value = REG_OK
        svc._xvb_last_registered = time.time() - XVB_REGISTER_INTERVAL_S - 1
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_called_once()

    async def test_disabled_endpoint_skips_silently(self):
        # XVB_SUBMIT_URL disabled => empty submit_url => no call, no warning, no status write.
        svc, sm, xvb = self._svc(submit_url="")
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        xvb.register.assert_not_called()
        sm.update_xvb_stats.assert_not_called()

    async def test_persistent_failure_flags_failing_after_threshold(self):
        # A configured-but-erroring endpoint surfaces a "failing" badge only after a few attempts.
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_ERROR
        for _ in range(_XVB_REGISTER_FAIL_ALERT - 1):
            await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        # Below the threshold: no dashboard warning yet.
        assert "registration_state" not in self._state_writes(sm)
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert self._state_writes(sm)["registration_state"] == "failing"
        assert svc._xvb_last_registered is None  # still never succeeded

    async def test_success_after_failures_resets_counter(self):
        svc, sm, xvb = self._svc()
        xvb.register.return_value = REG_ERROR
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_register_failures == 1
        xvb.register.return_value = REG_OK
        await svc._maybe_register_xvb(shares=self._fresh_share(), p2pool_stats=self._stats())
        assert svc._xvb_register_failures == 0
        assert self._state_writes(sm)["registration_state"] == "registered"


class TestXvbStatsSync:
    """XvB stats fetch → persist (#163), and the #311 precondition: a FAILED fetch must write
    nothing, so the last reading and ``last_update`` stay frozen and the staleness guard can fire.
    This is the integration seam the algo-level unit tests assume but can't see."""

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        xvb = MagicMock()
        return DataService(sm, MagicMock(), xvb), sm, xvb

    async def test_successful_fetch_persists_stats(self):
        svc, sm, xvb = self._svc()
        xvb.get_stats.return_value = {"avg_1h": 12_000.0, "avg_24h": 11_000.0, "fail_count": 0}
        await svc._sync_xvb_stats()
        sm.update_xvb_stats.assert_called_once_with(avg_1h=12_000.0, avg_24h=11_000.0, fail_count=0)

    async def test_failed_fetch_writes_nothing(self):
        # #311 linchpin: get_stats() returns None on a Tor timeout / 5xx. Persisting nothing is what
        # keeps last_update frozen so the controller can detect the feed is stale. If this regresses
        # to stamping on failure, the staleness guard silently never triggers.
        svc, sm, xvb = self._svc()
        xvb.get_stats.return_value = None
        await svc._sync_xvb_stats()
        sm.update_xvb_stats.assert_not_called()

    def _svc_with_real_storage(self):
        # v1.7 telemetry backbone (#196 Wave-0): a real in-memory StateManager so a captured
        # xvb_history row is provable, not just "the mock was called".
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    async def test_first_fetch_writes_an_xvb_history_row(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.xvb_client.get_stats.return_value = {
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
            }
            await svc._sync_xvb_stats()
            rows = sm.get_xvb_history()
            assert len(rows) == 1
            assert rows[0]["avg_1h"] == 1000.0
            assert rows[0]["mode"] == "P2POOL"  # the default xvb state, before any mode switch
        finally:
            sm.close()

    async def test_wallclock_gate_suppresses_a_too_soon_second_write(self):
        # The capture cadence is a wall-clock gate (~5 min), not iteration-count-based — two
        # fetches back-to-back in the same test must not double-write.
        svc, sm = self._svc_with_real_storage()
        try:
            svc.xvb_client.get_stats.return_value = {
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
            }
            await svc._sync_xvb_stats()
            await svc._sync_xvb_stats()
            assert len(sm.get_xvb_history()) == 1
        finally:
            sm.close()

    async def test_gate_reopens_once_the_cadence_elapses(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.xvb_client.get_stats.return_value = {
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
            }
            await svc._sync_xvb_stats()
            svc._last_xvb_history_write -= 301  # simulate 5+ minutes having passed
            await svc._sync_xvb_stats()
            assert len(sm.get_xvb_history()) == 2
        finally:
            sm.close()


class TestXvbWinnersSync:
    """XvB raffle-winners mirror: the public winners file → raffle_wins table, on a 30-min
    wall-clock gate, with the same "a failed fetch writes nothing" contract as the stats sync
    — and additionally does NOT stamp the gate, so a failure retries on the next eligible poll."""

    _WIN = {"ts": 1000.0, "hashrate": 4.2e6, "height": 100, "block_id": "aa11", "tier": "donor"}
    # get_recent_wins' one-fetch-two-parses shape (#866): wins + the all-rounds aggregate.
    _STATS = {"types": {"donor": {"rounds": 4, "players_avg": 70.0}}, "span_days": 4.0}

    def _fetch(self, wins, stats=None):
        return {"wins": wins, "round_stats": stats if stats is not None else self._STATS}

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        # Adaptive-gate reads (#892): defaults that resolve to the 30-min baseline.
        sm.get_xvb_stats.return_value = {}
        sm.get_tiers.return_value = {}
        sm.get_raffle_wins.return_value = []
        xvb = MagicMock()
        return DataService(sm, MagicMock(), xvb), sm, xvb

    async def test_successful_fetch_persists_wins(self):
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = self._fetch([self._WIN])
        await svc._sync_xvb_winners()
        sm.add_raffle_wins.assert_called_once_with([self._WIN])
        # The same fetched body also refreshes the all-rounds aggregate (#866).
        sm.set_xvb_round_stats.assert_called_once_with(self._STATS)
        assert svc._last_xvb_winners_sync > 0  # gate stamped on success

    async def test_unparseable_round_stats_do_not_overwrite_the_cached_aggregate(self):
        # A file that yields wins but no round aggregate (format drift) must not blank the
        # cache — the stale-by-last_update rule owns degradation, never an empty-implied-fresh.
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = self._fetch(
            [self._WIN], stats={"types": {}, "span_days": 0.0}
        )
        await svc._sync_xvb_winners()
        sm.set_xvb_round_stats.assert_not_called()
        sm.add_raffle_wins.assert_called_once_with([self._WIN])

    async def test_failed_fetch_writes_nothing_and_leaves_the_gate_open(self):
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = None
        await svc._sync_xvb_winners()
        sm.add_raffle_wins.assert_not_called()
        sm.set_xvb_round_stats.assert_not_called()
        # Gate NOT stamped: the next eligible poll retries instead of waiting out 30 min.
        assert svc._last_xvb_winners_sync == 0.0

    async def test_wallclock_gate_suppresses_a_too_soon_second_fetch(self):
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = self._fetch([])
        await svc._sync_xvb_winners()
        await svc._sync_xvb_winners()
        assert xvb.get_recent_wins.call_count == 1

    async def test_gate_reopens_once_the_cadence_elapses(self):
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = self._fetch([])
        await svc._sync_xvb_winners()
        svc._last_xvb_winners_sync -= 1801  # simulate 30+ minutes having passed
        await svc._sync_xvb_winners()
        assert xvb.get_recent_wins.call_count == 2

    async def test_a_new_win_round_trips_through_real_storage(self):
        # A real in-memory StateManager so the persisted row is provable end to end — and the
        # raffle_win alert fires exactly once per new win: the idempotent insert means the
        # second sync re-reading the same file window neither re-stores nor re-alerts.
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.alert_service = AsyncMock()
        try:
            svc.xvb_client.get_recent_wins.return_value = self._fetch([self._WIN])
            await svc._sync_xvb_winners()
            rows = sm.get_raffle_wins()
            assert len(rows) == 1
            assert rows[0]["block_id"] == "aa11"
            svc.alert_service.raffle_win_alert.assert_awaited_once_with("donor", 4.2e6)
            # A second sync past the gate re-reads the same file window — still one row, no re-alert.
            svc._last_xvb_winners_sync -= 1801
            await svc._sync_xvb_winners()
            assert len(sm.get_raffle_wins()) == 1
            svc.alert_service.raffle_win_alert.assert_awaited_once()
        finally:
            sm.close()


class TestXvbWinnersGate:
    """The adaptive winners-mirror gate (#892): the fast cadence only in the windows where a
    late-detected win costs money — the credited 1h average riding just above its tier
    threshold, or a recorded win still fresh — and the 30-min baseline everywhere else."""

    _TIERS = {"donor": 1_000, "donor_whale": 100_000}
    _NOW = 1_000_000.0

    def _gate(self, avg_1h, avg_24h, last_win_ts=0.0):
        return _xvb_winners_gate_sec(avg_1h, avg_24h, self._TIERS, last_win_ts, self._NOW)

    def test_baseline_at_comfortable_margin_with_no_fresh_win(self):
        # 250k credited over the 100k whale threshold: >25% above, no recorded win → 30 min.
        assert self._gate(250_000, 250_000) == _XVB_WINNERS_SYNC_SEC

    def test_fast_while_credited_rides_the_tier_threshold(self):
        # The controller's steady state: the 1h average held at threshold + cushion (#769) —
        # the exact band the #892 incident sagged out of.
        assert self._gate(103_000, 105_000) == _XVB_WINNERS_SYNC_FAST_SEC

    def test_margin_boundary_is_inclusive(self):
        assert self._gate(125_000, 125_000) == _XVB_WINNERS_SYNC_FAST_SEC
        assert self._gate(125_001, 125_001) == _XVB_WINNERS_SYNC_SEC

    def test_tier_qualifies_on_the_lower_of_the_two_averages(self):
        # 24h still ramping: the wallet qualifies at donor (1k), and 103k is far above THAT
        # threshold — no whale round to protect yet → baseline.
        assert self._gate(103_000, 50_000) == _XVB_WINNERS_SYNC_SEC

    def test_baseline_below_the_lowest_tier(self):
        # Cold ramp, no tier credited: nothing can be won, nothing to protect → 30 min.
        assert self._gate(500, 400) == _XVB_WINNERS_SYNC_SEC

    def test_fast_while_a_recorded_win_is_younger_than_90_min(self):
        gate = self._gate(250_000, 250_000, last_win_ts=self._NOW - 89 * 60)
        assert gate == _XVB_WINNERS_SYNC_FAST_SEC

    def test_baseline_once_the_recorded_win_ages_out(self):
        gate = self._gate(250_000, 250_000, last_win_ts=self._NOW - 91 * 60)
        assert gate == _XVB_WINNERS_SYNC_SEC

    async def test_sensitive_window_reopens_the_sync_gate_early(self):
        # Wiring: in the sensitive band _sync_xvb_winners refetches after 150+ s, where the
        # old fixed 30-min gate would have suppressed the second fetch.
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        sm.get_xvb_stats.return_value = {"avg_1h": 103_000, "avg_24h": 105_000}
        sm.get_tiers.return_value = self._TIERS
        sm.get_raffle_wins.return_value = []
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.xvb_client.get_recent_wins.return_value = {"wins": [], "round_stats": {}}
        await svc._sync_xvb_winners()
        svc._last_xvb_winners_sync -= _XVB_WINNERS_SYNC_FAST_SEC + 1
        await svc._sync_xvb_winners()
        assert svc.xvb_client.get_recent_wins.call_count == 2


class _RecordingGet:
    """One aiohttp ``session.get()`` async-context-manager that records nothing itself."""

    async def __aenter__(self):
        resp = MagicMock()
        resp.status = 200
        resp.json = AsyncMock(return_value={"ok": True})
        return resp

    async def __aexit__(self, *exc):
        return False


class _RecordingSession:
    """Minimal aiohttp ClientSession stub that records every probed URL."""

    def __init__(self):
        self.urls = []

    def get(self, url, headers=None, timeout=None):
        self.urls.append(url)
        return _RecordingGet()


class TestWorkerProbeSsrfWiring:
    """End-to-end SSRF guard (#122): a miner controls its own row in xmrig-proxy's ``/workers``
    list (name at index 0, IP at index 1). Prove that an internal/loopback IP or a crafted name
    can't make the dashboard probe an internal target — the exact tier-1 mirror of the deferred
    live test in #206. Threads the real proxy-row → probe path (``_normalize_proxy_workers`` then
    the same task construction as DataService.run), so the parsed IP — never the name — is the only
    thing ever used as a host."""

    @staticmethod
    def _row(name, ip):
        # A full positional xmrig-proxy 6.x row (>= _PX_MIN_FIELDS): 1 active conn, some hashrate.
        return [name, ip, 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]

    async def _probe(self, raw_workers):
        workers = _normalize_proxy_workers({"workers": raw_workers})
        session = _RecordingSession()
        client = XMRigWorkerClient(session)
        # Mirror DataService.run's probe fan-out verbatim (data_service.py:632).
        results = await asyncio.gather(*[client.get_stats(w["ip"], w["name"]) for w in workers])
        return workers, results, session.urls

    async def test_internal_ip_worker_is_never_probed(self):
        # Every class the guard blocks: cloud metadata (link-local), loopback, the stack's own
        # docker bridge (socket proxies / Tor / monerod), multicast, unspecified, and a name that
        # isn't a bare IP. LAN/public miner IPs are intentionally NOT here — those are real miners.
        for ip in (
            "169.254.169.254",  # cloud metadata (link-local)
            "127.0.0.1",  # loopback
            "172.28.0.2",  # internal docker bridge (default MINING_NET_CIDR)
            "224.0.0.1",  # multicast
            "0.0.0.0",  # unspecified
            "p2pool",  # a worker name, not a bare IP
            "",  # missing
        ):
            _, results, urls = await self._probe([self._row("evil", ip)])
            assert results == [{}], f"probed an internal/invalid target {ip!r}"
            assert urls == [], f"issued a request to internal/invalid target {ip!r}"

    async def test_real_worker_is_probed_internal_neighbour_is_not(self):
        workers, results, urls = await self._probe(
            [self._row("rig", "8.8.8.8"), self._row("evil", "169.254.169.254")]
        )
        # Exactly one probe, to the real miner only.
        assert urls == ["http://8.8.8.8:8080/1/summary"]
        assert results[0].get("api_ok") is True
        assert results[1] == {}

    async def test_malicious_name_is_never_used_as_a_host(self):
        # The name is fully attacker-controlled; it must never end up in the request URL.
        _, _, urls = await self._probe([self._row("169.254.169.254", "8.8.8.8")])
        assert urls == ["http://8.8.8.8:8080/1/summary"]
        assert all("169.254.169.254" not in u for u in urls)


class TestPayoutSync:
    """On-chain payout confirmation poll (#381): persist confirmed payouts, alert once, no replay."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.wallet_client = MagicMock()
        svc.alert_service.payout_confirmed_alert = AsyncMock(return_value="sent")
        return svc, sm

    def test_new_payout_persists_and_alerts_once(self):
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "aa", "height": 100, "ts": 1000.0, "amount_atomic": 250_000_000_000}
            svc.wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_payouts())
            assert len(sm.get_payouts("monero")) == 1
            svc.alert_service.payout_confirmed_alert.assert_awaited_once_with(
                "monero", 250_000_000_000, "aa"
            )
        finally:
            sm.close()

    def test_restart_replay_does_not_realert(self):
        # The same payout seen again (a re-scan of the tip) inserts nothing new → no second alert.
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "aa", "height": 100, "ts": 1000.0, "amount_atomic": 1}
            svc.wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_payouts())
            asyncio.run(svc._sync_payouts())
            assert svc.alert_service.payout_confirmed_alert.await_count == 1
            assert len(sm.get_payouts("monero")) == 1
        finally:
            sm.close()

    def test_seeds_min_height_from_stored_max(self):
        # The poll must query from the highest stored height so it re-scans only the tip.
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_payouts(
                "monero", [{"txid": "old", "height": 500, "ts": 1.0, "amount_atomic": 1}]
            )
            svc.wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_payouts())
            svc.wallet_client.get_confirmed_payouts.assert_called_once_with(500)
        finally:
            sm.close()

    def test_empty_poll_is_a_quiet_noop(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_payouts())
            svc.alert_service.payout_confirmed_alert.assert_not_awaited()
        finally:
            sm.close()

    def test_disabled_feature_leaves_no_wallet_client(self, monkeypatch):
        monkeypatch.setattr(ds_mod, "PAYOUT_CONFIRM_ENABLED", False)
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.wallet_client is None


class TestReconcileWorkerConfig:
    """#579: the dashboard's regular per-rig read poll reconciles any #185 history row a slow rig
    rollback left stuck 'accepted', once the rig's enriched feed mirrors a terminal outcome for
    that change_id (rigforge.control). Real StateManager (not a mock) throughout — every assertion
    reads back the actual stored row, so a reverted WHERE-clause guard or a dropped reconcile call
    fails these tests, not just a mock's call count.

    #530 extends the same poll: a TERMINAL report for a change_id this dashboard never spooled is
    a rig-side out-of-band edit, recorded to ``audit_events`` instead of silently reconciling
    nothing."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def _seed(self, sm, status, change_id="cid-1", worker="rig1"):
        sm.add_worker_config_version(worker, change_id, status, {"max_temp_c": 80}, None)

    def _status_of(self, sm, worker="rig1", change_id="cid-1"):
        rows = [r for r in sm.get_worker_config_history(worker) if r["change_id"] == change_id]
        assert len(rows) == 1
        return rows[0]

    def _workers(self, *names):
        return [{"name": n} for n in names]

    def test_terminal_report_reconciles_accepted_row(self):
        # The main revert-proof case: a real 'accepted' row becomes 'rolled_back' once the rig's
        # enriched feed mirrors that outcome for the matching change_id.
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            worker_results = [
                {
                    "rigforge": {
                        "control": {
                            "change_id": "cid-1",
                            "status": "rolled_back",
                            "reason": "miner did not return to a live hashrate",
                        }
                    }
                }
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            row = self._status_of(sm)
            assert row["status"] == "rolled_back"
            assert row["reason"] == "miner did not return to a live hashrate"
            # A known change_id reconciles quietly — no audit row for the dashboard's own change.
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    def test_terminal_row_is_never_overwritten(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "applied")
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "rolled_back"}}}
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm)["status"] == "applied"
        finally:
            sm.close()

    def test_offline_rig_leaves_row_accepted(self):
        # An unreachable/offline rig probes to {} (XMRigWorkerClient.get_stats' failure shape) — no
        # false terminal.
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), [{}]))
            assert self._status_of(sm)["status"] == "accepted"
        finally:
            sm.close()

    def test_missing_change_id_leaves_row_accepted(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            worker_results = [{"rigforge": {"control": {"status": "rolled_back"}}}]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm)["status"] == "accepted"
        finally:
            sm.close()

    def test_still_in_flight_report_leaves_row_accepted(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "accepted"}}}
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm)["status"] == "accepted"
        finally:
            sm.close()

    def test_multiple_workers_reconciled_independently(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted", change_id="cid-1", worker="rig1")
            self._seed(sm, "accepted", change_id="cid-2", worker="rig2")
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "applied"}}},
                {
                    "rigforge": {
                        "control": {
                            "change_id": "cid-2",
                            "status": "rejected",
                            "reason": "bad pool url",
                        }
                    }
                },
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1", "rig2"), worker_results))
            assert self._status_of(sm, worker="rig1", change_id="cid-1")["status"] == "applied"
            row2 = self._status_of(sm, worker="rig2", change_id="cid-2")
            assert row2["status"] == "rejected"
            assert row2["reason"] == "bad pool url"
        finally:
            sm.close()


class TestRigEditDetection:
    """#530: a rig's control-status mirror reports a TERMINAL outcome for a change_id this
    dashboard never spooled into ``worker_config`` — the rig applied it on its own. That gets
    recorded as a ``rig-edit`` audit row naming the worker, instead of the silent no-op a
    ``reconcile_worker_config_status`` UPDATE would be against a change_id with no matching row."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def test_unknown_change_id_records_rig_edit(self):
        svc, sm = self._svc_with_real_storage()
        try:
            worker_results = [
                {
                    "rigforge": {
                        "control": {
                            "change_id": "rig-local-cid",
                            "status": "applied",
                            "reason": None,
                        }
                    }
                }
            ]
            asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], worker_results))
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "rig-edit"
            assert events[0]["actor"] == "rig1"
            assert events[0]["status"] == "applied"
            assert "rig-local-cid" in events[0]["keys"]
            # Nothing to reconcile — no #185 row existed for this change_id.
            assert sm.get_worker_config_history("rig1") == []
        finally:
            sm.close()

    def test_known_change_id_never_flagged(self):
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_worker_config_version("rig1", "cid-1", "accepted", {"max_temp_c": 80}, None)
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "applied"}}}
            ]
            asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], worker_results))
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    def test_multiple_workers_only_the_unknown_one_flagged(self):
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_worker_config_version("rig1", "cid-known", "accepted", {}, None)
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-known", "status": "applied"}}},
                {"rigforge": {"control": {"change_id": "cid-unknown", "status": "rejected"}}},
            ]
            asyncio.run(
                svc._reconcile_worker_config([{"name": "rig1"}, {"name": "rig2"}], worker_results)
            )
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["actor"] == "rig2"
            assert events[0]["status"] == "rejected"
        finally:
            sm.close()

    def test_same_change_id_across_polls_records_exactly_one_row(self):
        # The flood guard (HIGH #530 review): a rig re-reports its last terminal change_id every
        # poll. Deterministic row id + in-memory guard must collapse that to ONE audit row, not a
        # new row per ~30s cycle for a permanent, never-pruned table.
        svc, sm = self._svc_with_real_storage()
        try:
            worker_results = [
                {"rigforge": {"control": {"change_id": "rig-local-cid", "status": "applied"}}}
            ]
            for _ in range(3):  # three consecutive polls, same report
                asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], worker_results))
            assert len(sm.get_audit_events()) == 1
        finally:
            sm.close()

    def test_repeat_report_after_a_restart_still_dedups_via_the_deterministic_id(self):
        # The in-memory guard is empty on a fresh DataService (restart), but the SAME rig report
        # must still not duplicate the row — the deterministic id + INSERT OR IGNORE is the bound.
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        try:
            worker_results = [
                {"rigforge": {"control": {"change_id": "rig-local-cid", "status": "applied"}}}
            ]
            svc1 = DataService(sm, MagicMock(), MagicMock())
            asyncio.run(svc1._reconcile_worker_config([{"name": "rig1"}], worker_results))
            svc2 = DataService(sm, MagicMock(), MagicMock())  # "restart": fresh empty guard set
            asyncio.run(svc2._reconcile_worker_config([{"name": "rig1"}], worker_results))
            assert len(sm.get_audit_events()) == 1
        finally:
            sm.close()

    def _flood(self, svc, worker, change_ids):
        for cid in change_ids:
            wr = [{"rigforge": {"control": {"change_id": cid, "status": "applied"}}}]
            asyncio.run(svc._reconcile_worker_config([{"name": worker}], wr))

    def test_distinct_change_id_flood_is_bounded_per_worker(self):
        # #724: a rogue rig on the unauthenticated feed reports a NEW change_id every poll. Each
        # clears #530's deterministic-id dedup, so without a cap every poll writes a permanent row.
        # The per-worker hourly cap bounds rig-edit rows to _RIG_EDIT_CAP_PER_HOUR, plus exactly one
        # rate-limited marker so the flood stays visible — not silently swallowed.
        svc, sm = self._svc_with_real_storage()
        try:
            cap = ds_mod._RIG_EDIT_CAP_PER_HOUR
            self._flood(svc, "rig1", [f"cid-{i}" for i in range(cap + 8)])
            events = sm.get_audit_events()
            rig_edits = [e for e in events if e["action"] == "rig-edit"]
            markers = [e for e in events if e["action"] == "rate-limited"]
            assert len(rig_edits) == cap
            assert len(markers) == 1
            assert markers[0]["source"] == "rig-edit"
            assert markers[0]["actor"] == "rig1"
            assert markers[0]["status"] == "dropped"
        finally:
            sm.close()

    def test_normal_cadence_is_never_rate_limited(self):
        # A real operator edits a rig a handful of times an hour — well under the cap. Every genuine
        # change_id records and no rate-limited marker is ever written.
        svc, sm = self._svc_with_real_storage()
        try:
            self._flood(svc, "rig1", ["real-0", "real-1", "real-2"])
            events = sm.get_audit_events()
            assert len(events) == 3
            assert all(e["action"] == "rig-edit" for e in events)
        finally:
            sm.close()

    def test_cap_is_per_worker_a_flood_does_not_starve_another_rig(self):
        # The cap is keyed on the worker (not global), so one rogue rig flooding distinct change_ids
        # never drops a genuine rig-edit — nor any host-edit — from a different, well-behaved source.
        svc, sm = self._svc_with_real_storage()
        try:
            self._flood(
                svc, "rogue", [f"flood-{i}" for i in range(ds_mod._RIG_EDIT_CAP_PER_HOUR + 5)]
            )
            self._flood(svc, "goodrig", ["honest-cid"])
            goodrig = [e for e in sm.get_audit_events() if e["actor"] == "goodrig"]
            assert len(goodrig) == 1
            assert goodrig[0]["action"] == "rig-edit"
        finally:
            sm.close()

    def test_cap_resets_after_the_window_elapses(self, monkeypatch):
        # Fixed in-memory window: once an hour passes the worker's budget refreshes, so a later
        # genuine change_id records normally again — the cap throttles a flood, it doesn't ban a rig.
        svc, sm = self._svc_with_real_storage()
        clock = {"t": 1000.0}
        monkeypatch.setattr(ds_mod.time, "time", lambda: clock["t"])
        try:
            cap = ds_mod._RIG_EDIT_CAP_PER_HOUR
            self._flood(svc, "rig1", [f"cid-{i}" for i in range(cap + 3)])
            assert len([e for e in sm.get_audit_events() if e["action"] == "rig-edit"]) == cap
            clock["t"] += ds_mod._RIG_EDIT_WINDOW_SEC + 1  # next window
            self._flood(svc, "rig1", ["post-window"])
            assert [e for e in sm.get_audit_events() if "post-window" in e["keys"]]
        finally:
            sm.close()


class TestTariPayoutSync:
    """Tari on-chain payout confirmation poll (#462): persist to the shared table with chain="tari",
    alert once, no replay — the Tari sibling of TestPayoutSync. The Tari client is async, so
    get_confirmed_payouts is an AsyncMock (awaited directly, not via to_thread)."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.tari_wallet_client = MagicMock()
        svc.tari_wallet_client.get_confirmed_payouts = AsyncMock()
        svc.alert_service.payout_confirmed_alert = AsyncMock(return_value="sent")
        return svc, sm

    def test_new_tari_payout_persists_and_alerts_once(self):
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "t1", "height": 100, "ts": 1000.0, "amount_atomic": 250_000}
            svc.tari_wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_tari_payouts())
            assert len(sm.get_payouts("tari")) == 1
            svc.alert_service.payout_confirmed_alert.assert_awaited_once_with("tari", 250_000, "t1")
            # It landed on the Tari side only — the Monero chain is untouched.
            assert sm.get_payouts("monero") == []
        finally:
            sm.close()

    def test_restart_replay_does_not_realert(self):
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "t1", "height": 100, "ts": 1000.0, "amount_atomic": 1}
            svc.tari_wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_tari_payouts())
            asyncio.run(svc._sync_tari_payouts())
            assert svc.alert_service.payout_confirmed_alert.await_count == 1
            assert len(sm.get_payouts("tari")) == 1
        finally:
            sm.close()

    def test_seeds_min_height_from_stored_tari_max(self):
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_payouts("tari", [{"txid": "old", "height": 500, "ts": 1.0, "amount_atomic": 1}])
            svc.tari_wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_tari_payouts())
            svc.tari_wallet_client.get_confirmed_payouts.assert_awaited_once_with(500)
        finally:
            sm.close()

    def test_empty_poll_is_a_quiet_noop(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.tari_wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_tari_payouts())
            svc.alert_service.payout_confirmed_alert.assert_not_awaited()
        finally:
            sm.close()

    def test_disabled_feature_leaves_no_tari_wallet_client(self, monkeypatch):
        monkeypatch.setattr(ds_mod, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.tari_wallet_client is None


class TestTelemetryBackboneHooks:
    """v1.7 telemetry backbone (#196 Wave-0): the blocks/disk_growth/network_history/
    worker_history capture hooks wired into run(), verified end-to-end against a real in-memory
    StateManager so "a row landed" is provable, not just "the mock was called". (xvb_history's
    hook lives on ``_sync_xvb_stats`` and is covered directly in TestXvbStatsSync above.)"""

    def _svc(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        proxy = MagicMock()
        svc = DataService(sm, proxy, MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc, sm, proxy

    async def _run_one(
        self, svc, *, p2pool_stats=None, network_stats=None, disk_usage=None, monero_sync=None
    ):
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={"is_syncing": False, "reachable": True}
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(
                ds_mod, "get_network_stats", return_value=network_stats or {"height": 100}
            ),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value=p2pool_stats
                or {"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value=monero_sync or {"is_syncing": False, "reachable": True}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value=disk_usage or {}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

    async def test_block_hook_baselines_without_backfill_on_first_poll(self):
        # First-ever poll must never backfill the whole historical block count as one event.
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        await self._run_one(
            svc, p2pool_stats={"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 3}}
        )
        assert sm.get_blocks() == []
        assert svc._last_blocks_found == 3

    async def test_block_hook_writes_a_row_on_a_new_block(self):
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        svc._last_blocks_found = 5  # a prior poll already baselined
        await self._run_one(
            svc,
            p2pool_stats={
                "pool": {
                    "last_share_time": 0,
                    "difficulty": 0,
                    "blocks_found": 6,
                    "last_block_found": 3_100_000,
                }
            },
            network_stats={"height": 100, "difficulty": 999.0},
        )
        rows = sm.get_blocks()
        assert len(rows) == 1
        assert rows[0]["height"] == 3_100_000
        assert rows[0]["difficulty"] == 999.0

    async def test_block_hook_quiet_when_counter_unchanged(self):
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        svc._last_blocks_found = 6
        await self._run_one(
            svc, p2pool_stats={"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 6}}
        )
        assert sm.get_blocks() == []

    async def test_hourly_hooks_write_disk_growth_and_network_history_on_first_poll(self):
        # `_last_hourly_capture` starts at 0.0, so the first poll is always due.
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        await self._run_one(
            svc,
            network_stats={"height": 100, "difficulty": 1e9, "reward": 0.6},
            disk_usage={"used_gb": 100.0, "total_gb": 500.0},
            monero_sync={"is_syncing": False, "reachable": True, "db_size": 123456},
        )
        disk_rows = sm.get_disk_growth()
        assert len(disk_rows) == 1
        assert disk_rows[0]["monero_db_bytes"] == 123456
        assert disk_rows[0]["disk_used_gb"] == 100.0
        assert disk_rows[0]["disk_total_gb"] == 500.0
        net_rows = sm.get_network_history()
        assert len(net_rows) == 1
        assert net_rows[0]["difficulty"] == 1e9
        assert net_rows[0]["reward"] == 0.6

    async def test_hourly_hooks_suppressed_when_gate_not_due(self):
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        svc._last_hourly_capture = time.time()  # just captured — not due for another hour
        await self._run_one(svc)
        assert sm.get_disk_growth() == []
        assert sm.get_network_history() == []

    async def test_worker_history_hook_writes_a_row_for_each_online_worker(self):
        # proxy list row: connections=1 (online), idx8=1.0 kH/s (h10), idx9=2.0 kH/s (h15).
        svc, sm, proxy = self._svc()
        worker_row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        proxy.get_workers.return_value = {"workers": [worker_row]}
        proxy.get_summary.return_value = {"results": {}}
        await self._run_one(svc)
        rows = sm.get_worker_history()
        assert len(rows) == 1
        assert rows[0]["name"] == "rig1"
        assert rows[0]["h15"] == 2000.0

    async def test_worker_history_hook_skips_offline_workers(self):
        svc, sm, proxy = self._svc()
        offline_row = ["rig1", "10.0.0.1", 0, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]  # connections=0
        proxy.get_workers.return_value = {"workers": [offline_row]}
        await self._run_one(svc)
        assert sm.get_worker_history() == []

    async def test_worker_history_hook_suppressed_when_gate_not_due(self):
        svc, sm, proxy = self._svc()
        worker_row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        proxy.get_workers.return_value = {"workers": [worker_row]}
        svc._last_worker_capture = time.time()
        await self._run_one(svc)
        assert sm.get_worker_history() == []

    async def test_table_health_reflects_a_forced_block_write_failure(self):
        # The whole poll loop is one try/except, so a hook that starts failing must be visible
        # via the per-table health signal, not just swallowed silently.
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        with sm._db_lock:
            sm._conn.execute("DROP TABLE blocks")
        svc._last_blocks_found = 5
        await self._run_one(
            svc, p2pool_stats={"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 6}}
        )
        assert sm.get_table_health()["blocks"]["healthy"] is False


class TestSyncPrices:
    """#520: the poll-loop price refresh — a no-op with the feed off, the cached PriceFeed result
    surfaced as latest_data["prices"] when on."""

    async def test_disabled_feed_never_fetches(self):
        svc, _, _ = _make_service()
        svc.price_feed = MagicMock(enabled=False)
        await svc._sync_prices()
        svc.price_feed.maybe_fetch.assert_not_called()
        assert "prices" not in svc.latest_data

    async def test_enabled_feed_surfaces_prices(self):
        svc, _, _ = _make_service()
        prices = {"xmr": 333.97, "tari": 0.0004, "currency": "USD", "fetched_at": 1000.0}
        svc.price_feed = MagicMock(enabled=True)
        svc.price_feed.maybe_fetch.return_value = prices
        await svc._sync_prices()
        assert svc.latest_data["prices"] == prices


class TestDiffConfigKeys:
    """#530: dotted-path config diff — names only, the out-of-band host-edit detector's sole
    correctness surface. A value is compared for equality but never returned."""

    def test_no_change_is_empty(self):
        cfg = {"xvb": {"enabled": True}}
        assert _diff_config_keys(cfg, dict(cfg)) == []

    def test_changed_leaf_named(self):
        old = {"xvb": {"donation_level": "auto"}}
        new = {"xvb": {"donation_level": "vip"}}
        assert _diff_config_keys(old, new) == ["xvb.donation_level"]

    def test_added_and_removed_keys_named(self):
        assert _diff_config_keys({"a": 1}, {"b": 2}) == ["a", "b"]

    def test_nested_paths_use_dotted_names(self):
        old = {"telegram": {"events": {"node_down": True}}}
        new = {"telegram": {"events": {"node_down": False}}}
        assert _diff_config_keys(old, new) == ["telegram.events.node_down"]

    def test_secret_sentinel_change_detected_without_a_value(self):
        # The masked config's secret leaves are {"__secret__": True} sentinels (#440) — clearing or
        # setting one changes dict-presence, detectable by equality alone; no real secret is ever
        # compared or returned by this function.
        old = {"dashboard": {"auth": {"password": {"__secret__": True}}}}
        new = {"dashboard": {"auth": {}}}
        assert _diff_config_keys(old, new) == ["dashboard.auth.password"]

    def test_unrelated_keys_untouched(self):
        assert _diff_config_keys({"a": 1, "b": 2}, {"a": 1, "b": 3}) == ["b"]

    def test_non_dict_input_is_treated_as_empty(self):
        # A malformed config.json (top-level not an object) must never crash the watcher — every
        # key on the OTHER side just reads as added/removed.
        assert _diff_config_keys("not-a-dict", {"a": 1}) == ["a"]
        assert _diff_config_keys(None, None) == []


class TestAuditTsHelpers:
    """#530: the shared ts format between control.log's own writer and this dashboard's
    detections — a plain string round-trips through both directions."""

    def test_iso_now_round_trips_through_parse_audit_ts(self):
        parsed = _parse_audit_ts(_iso_now())
        assert parsed is not None
        assert abs(parsed - time.time()) < 5

    def test_parse_audit_ts_rejects_garbage(self):
        assert _parse_audit_ts("not-a-timestamp") is None
        assert _parse_audit_ts(None) is None
        assert _parse_audit_ts(123) is None


class TestWatchHostConfig:
    """#530: config.json changed without a matching control-channel commit -> a ``host-edit``
    audit row. Real StateManager throughout, like TestReconcileWorkerConfig — every assertion
    reads back the persisted row."""

    def _svc(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def _write_config(self, path, doc):
        path.write_text(json.dumps(doc))

    async def test_control_disabled_is_a_noop(self, monkeypatch):
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", False)
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
            assert svc._last_host_config is None
        finally:
            sm.close()

    async def test_first_poll_only_baselines(self, tmp_path, monkeypatch):
        cfg = tmp_path / "config.json"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
            assert svc._last_host_config == {"xvb": {"enabled": True}}
        finally:
            sm.close()

    async def test_unexplained_change_is_recorded_host_edit(self, tmp_path, monkeypatch):
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"xvb": {"enabled": False}})  # changed out of band
            await svc._watch_host_config()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "host-edit"
            assert events[0]["keys"] == "xvb.enabled"
            assert events[0]["status"] == "detected"
        finally:
            sm.close()

    async def test_change_explained_by_a_fresh_commit_is_quiet(self, tmp_path, monkeypatch):
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"xvb": {"enabled": False}})
            # A commit landed AFTER the baseline check — it explains the change.
            log.write_text(
                json.dumps(
                    {
                        "ts": _iso_now(),
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_commit_of_one_key_does_not_swallow_a_concurrent_host_edit(
        self, tmp_path, monkeypatch
    ):
        # #530 review MEDIUM: correlate BY KEY, not just by time. A fresh dashboard commit of key A
        # landing in the same window as a host-side hand-edit of key B must NOT suppress B — the
        # out-of-band change the feature exists to catch. Fails on the old time-only `explained =
        # any(...)` logic, which swallowed the whole diff on ANY fresh commit.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        # A: xvb.enabled (committable, maps to XVB_ENABLED). B: dashboard.tari_required (maps to
        # TARI_REQUIRED) — hand-edited on the host, NOT named by the commit below.
        self._write_config(cfg, {"xvb": {"enabled": True}, "dashboard": {"tari_required": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            # Both keys change; only A was actually committed through the dashboard.
            self._write_config(
                cfg, {"xvb": {"enabled": False}, "dashboard": {"tari_required": False}}
            )
            log.write_text(
                json.dumps(
                    {
                        "ts": _iso_now(),
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()
            events = sm.get_audit_events()
            # B is recorded out-of-band; A (explained by the commit) is NOT double-recorded.
            assert len(events) == 1
            assert events[0]["source"] == "host-edit"
            assert events[0]["keys"] == "dashboard.tari_required"
        finally:
            sm.close()

    async def test_energy_commit_explains_an_energy_subkey_by_prefix(self, tmp_path, monkeypatch):
        # #530: dashboard.energy.* is config.json-only and audits under the synthetic
        # DASHBOARD_ENERGY name, which env_key_config_paths maps to the whole `dashboard.energy`
        # block by prefix — so a committed energy sub-key change stays quiet even though its dotted
        # diff path (dashboard.energy.cost_per_kwh) isn't the literal committed name.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"dashboard": {"energy": {"cost_per_kwh": 0.10}}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"dashboard": {"energy": {"cost_per_kwh": 0.20}}})
            log.write_text(
                json.dumps(
                    {
                        "ts": _iso_now(),
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "DASHBOARD_ENERGY",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_stale_commit_before_the_last_check_does_not_explain(self, tmp_path, monkeypatch):
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            # An old commit, already accounted for before this watcher ever ran, then a NEW
            # out-of-band change — the stale commit must not explain it away.
            log.write_text(
                json.dumps(
                    {
                        "ts": "2020-01-01T00:00:00Z",
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"xvb": {"enabled": False}})
            await svc._watch_host_config()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "host-edit"
        finally:
            sm.close()

    async def test_missing_mount_is_a_quiet_noop(self, monkeypatch):
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", "/nonexistent/config.json")
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_a_raw_secret_value_never_reaches_the_audit_row(self, tmp_path, monkeypatch):
        # Defense-in-depth (#530 review MEDIUM): even if the host masking regressed and left a RAW
        # secret in the mounted copy, the re-mask keeps its value out of the persisted snapshot and
        # out of any audit row. Change a non-secret key alongside the raw secret; the row names the
        # non-secret key only, and the secret value appears nowhere.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(
            cfg, {"dashboard": {"auth": {"password": "s3cr3t-raw"}}, "xvb": {"enabled": True}}
        )
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline (secret already masked in the snapshot)
            assert svc._last_host_config["dashboard"]["auth"]["password"] == {"__secret__": True}
            self._write_config(
                cfg,
                {"dashboard": {"auth": {"password": "s3cr3t-changed"}}, "xvb": {"enabled": False}},
            )
            await svc._watch_host_config()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["keys"] == "xvb.enabled"  # the secret masks to a sentinel both sides
            blob = json.dumps(events) + json.dumps(svc._last_host_config)
            assert "s3cr3t-raw" not in blob and "s3cr3t-changed" not in blob
        finally:
            sm.close()

    async def test_explained_window_is_at_most_one_second(self, tmp_path, monkeypatch):
        # Boundary (#530 review LOW): the "explained by a fresh commit" check floors `since` to
        # `_last_host_check - 1` to absorb the audit log's whole-second ts truncation. That grace
        # is exactly 1s wide — a commit 1s before the last check still explains (truncation), one
        # 2s before does not. Pinned here so the honest ceiling can't silently widen.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        check_epoch = _parse_audit_ts("2026-07-20T12:00:05Z")

        async def _run_with_commit_ts(commit_ts):
            svc, sm = self._svc()
            svc._last_host_config = {"xvb": {"enabled": True}}
            svc._last_host_check = check_epoch
            self._write_config(cfg, {"xvb": {"enabled": False}})
            log.write_text(
                json.dumps(
                    {
                        "ts": commit_ts,
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            try:
                await svc._watch_host_config()
                return len(sm.get_audit_events())
            finally:
                sm.close()

        # 1s before the last check: still explains (truncation grace) -> no host-edit row.
        assert await _run_with_commit_ts("2026-07-20T12:00:04Z") == 0
        # 2s before: outside the grace, correctly NOT explained -> host-edit recorded.
        assert await _run_with_commit_ts("2026-07-20T12:00:03Z") == 1


class TestReadHostConfig:
    """#530 review MEDIUM: the mounted copy is pre-masked host-side, but _read_host_config
    re-applies the SECRET_PATHS mask (like control_service.read_config) so a host masking
    regression can't leave a raw secret resident in the long-lived config snapshot."""

    def test_secret_value_is_remasked(self, tmp_path, monkeypatch):
        cfg = tmp_path / "config.json"
        cfg.write_text(json.dumps({"dashboard": {"auth": {"password": "leaked"}}}))
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        out = _read_host_config()
        assert out["dashboard"]["auth"]["password"] == {"__secret__": True}

    def test_missing_or_bad_file_is_none(self, tmp_path, monkeypatch):
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", "/nonexistent/config.json")
        assert _read_host_config() is None
        bad = tmp_path / "config.json"
        bad.write_text("{not json")
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(bad))
        assert _read_host_config() is None


class TestMirrorControlAudit:
    """#530: opportunistically copies the #33 log's recent entries into the durable
    ``audit_events`` table so the Security panel can group deeper than the log's own trimmed
    tail. ``audit_service.recent_changes()`` output is already sanitized — nothing new to clean
    here, only to persist."""

    def _svc(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def _log_line(self, **over):
        entry = {
            "ts": "2026-07-10T12:00:00Z",
            "id": "11111111-1111-4111-8111-111111111111",
            "actor": "admin",
            "action": "commit",
            "status": "applied",
            "keys": "XVB_ENABLED",
        }
        entry.update(over)
        return json.dumps(entry)

    async def test_disabled_is_a_noop(self, monkeypatch):
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", False)
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_mirrors_log_entries(self, tmp_path, monkeypatch):
        log = tmp_path / "control.log"
        log.write_text(self._log_line() + "\n")
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "control"
            assert events[0]["actor"] == "admin"
            assert events[0]["keys"] == "XVB_ENABLED"
        finally:
            sm.close()

    async def test_re_mirroring_is_idempotent(self, tmp_path, monkeypatch):
        log = tmp_path / "control.log"
        log.write_text(self._log_line() + "\n")
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            await svc._mirror_control_audit()
            assert len(sm.get_audit_events()) == 1
        finally:
            sm.close()

    async def test_entries_without_an_id_are_skipped(self, tmp_path, monkeypatch):
        log = tmp_path / "control.log"
        log.write_text(self._log_line(id="") + "\n")
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            assert sm.get_audit_events() == []
        finally:
            sm.close()
