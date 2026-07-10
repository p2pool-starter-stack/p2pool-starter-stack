import asyncio
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
    DataService,
    WorkerLifecycle,
    _aggregate_hashrate,
    _aggregate_window_hashrates,
    _merge_direct_stats,
    _merge_proxy_summary,
    _normalize_proxy_workers,
    _parse_legacy_dict_worker,
    _parse_proxy_list_worker,
    _parse_proxy_summary,
    _shares_to_record,
    _summary_deltas,
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
