"""Tests for the pure helpers behind the DataService poll loop (#1105 Phase 3, cut D5).

The 14 classes here moved 1:1 and byte-identical out of ``tests/service/test_data_service.py``
when their subjects moved into ``mining_dashboard/service/data_helpers.py``.

``_totals`` used to be defined here, a DUPLICATE of the builder in
``tests/service/test_data_service.py``.  Duplicating shared module-level test builders into each
new test module was the standing ruling while the #1105 cuts were in flight, because those cuts
proved themselves by moving test bodies verbatim and real pytest fixtures would have rewritten the
call sites inside the same change.  The cuts are finished, so #1541 moved both copies into
``tests/service/conftest.py`` as a factory fixture; the tests below take it as a parameter.

``TestXvbWinnersGate`` carries one wiring test that drives ``DataService._sync_xvb_winners``; the
class moves whole rather than being split, to keep the 1:1 byte-identical property, which is why
this module imports ``DataService``.
"""

import json
import time
from unittest.mock import MagicMock

import mining_dashboard.service.data_helpers as dh_mod
from mining_dashboard.service.data_helpers import (
    _XVB_WINNERS_SYNC_FAST_SEC,
    _XVB_WINNERS_SYNC_SEC,
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
from mining_dashboard.service.data_service import DataService


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


class TestSummaryDeltas:
    """#116: per-poll share-health deltas from consecutive cumulative proxy /summary totals."""

    def test_first_poll_baselines_without_backfill(self, _totals):
        cur = _totals(accepted=1000, rejected=5)
        assert _summary_deltas(None, cur) == (None, cur)

    def test_normal_delta(self, _totals):
        deltas, baseline = _summary_deltas(
            _totals(accepted=100, rejected=5), _totals(accepted=110, rejected=6, invalid=1)
        )
        assert deltas == _totals(accepted=10, rejected=1, invalid=1)
        assert baseline == _totals(accepted=110, rejected=6, invalid=1)

    def test_any_counter_backwards_rebaselines_without_negative_delta(self, _totals):
        # Proxy restart: accepted went backwards while rejected advanced — segment break, no row.
        cur = _totals(accepted=3, rejected=9)
        assert _summary_deltas(_totals(accepted=100, rejected=5), cur) == (None, cur)

    def test_all_zero_deltas_skipped(self, _totals):
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


class TestReadHostConfig:
    """#530 review MEDIUM: the mounted copy is pre-masked host-side, but _read_host_config
    re-applies the SECRET_PATHS mask (like control_service.read_config) so a host masking
    regression can't leave a raw secret resident in the long-lived config snapshot."""

    def test_secret_value_is_remasked(self, tmp_path, monkeypatch):
        cfg = tmp_path / "config.json"
        cfg.write_text(json.dumps({"dashboard": {"auth": {"password": "leaked"}}}))
        monkeypatch.setattr(dh_mod.config, "HOST_CONFIG_PATH", str(cfg))
        out = _read_host_config()
        assert out["dashboard"]["auth"]["password"] == {"__secret__": True}

    def test_notification_secrets_are_remasked(self, tmp_path, monkeypatch):
        # Same shared mask_secrets pass covers ntfy + the webhooks array here (#848), so a host-side
        # regression can't leave a raw notification credential resident in the config snapshot.
        cfg = tmp_path / "config.json"
        cfg.write_text(
            json.dumps(
                {
                    "notifications": {
                        "webhooks": ["https://hooks.example/leaked", ""],
                        "ntfy": {"url": "https://ntfy.example/leaked", "token": "leaked"},
                    }
                }
            )
        )
        monkeypatch.setattr(dh_mod.config, "HOST_CONFIG_PATH", str(cfg))
        out = _read_host_config()
        assert out["notifications"]["ntfy"]["url"] == {"__secret__": True}
        assert out["notifications"]["ntfy"]["token"] == {"__secret__": True}
        assert out["notifications"]["webhooks"][0] == {"__secret__": True}
        assert out["notifications"]["webhooks"][1] == ""
        assert "leaked" not in json.dumps(out)

    def test_missing_or_bad_file_is_none(self, tmp_path, monkeypatch):
        monkeypatch.setattr(dh_mod.config, "HOST_CONFIG_PATH", "/nonexistent/config.json")
        assert _read_host_config() is None
        bad = tmp_path / "config.json"
        bad.write_text("{not json")
        monkeypatch.setattr(dh_mod.config, "HOST_CONFIG_PATH", str(bad))
        assert _read_host_config() is None
