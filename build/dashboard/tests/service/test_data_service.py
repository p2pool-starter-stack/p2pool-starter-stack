from unittest.mock import MagicMock, AsyncMock, patch

import pytest

import mining_dashboard.service.data_service as ds_mod
from mining_dashboard.service.data_service import (
    DataService, _normalize_proxy_workers, _merge_direct_stats, _aggregate_hashrate,
    _parse_proxy_list_worker, _parse_legacy_dict_worker, _parse_proxy_summary,
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


class TestProxyWorkerParsers:
    """The per-shape row parsers used by _normalize_proxy_workers (Issue #39)."""

    def test_parse_list_row_named_fields(self):
        # idx2=connections, idx3/4/5=accepted/rejected/invalid, idx8=1m kH/s, idx9=10m kH/s,
        # idx7=last share ms.
        row = ["rig", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        w = _parse_proxy_list_worker(row)
        assert w == {"name": "rig", "ip": "10.0.0.1", "status": "online",
                     "h10": 1000, "h60": 1000, "h15": 2000, "uptime": 0,
                     "accepted": 0, "rejected": 0, "invalid": 0}

    def test_parse_list_row_share_counts(self):
        # idx3=accepted, idx4=rejected, idx5=invalid are carried through (Issue #82).
        row = ["rig", "10.0.0.1", 1, 500, 7, 2, 0, 0, 1.0, 2.0, 0, 0, 0]
        w = _parse_proxy_list_worker(row)
        assert (w["accepted"], w["rejected"], w["invalid"]) == (500, 7, 2)

    def test_parse_list_row_offline_and_uptime(self):
        row = ["rig", "10.0.0.1", 0, 0, 0, 0, 0, 1_000, 1.0, 2.0, 0, 0, 0]
        w = _parse_proxy_list_worker(row)
        assert w["status"] == "offline"
        assert w["uptime"] > 0  # derived from the last-share timestamp

    def test_parse_legacy_dict_row(self):
        w = _parse_legacy_dict_worker({"id": "old", "ip": "1.2.3.4",
                                       "hashrate": [10, 20, 30], "uptime": 5})
        assert w == {"name": "old", "ip": "1.2.3.4", "status": "online",
                     "h10": 10, "h60": 20, "h15": 30, "uptime": 5,
                     "accepted": 0, "rejected": 0, "invalid": 0}

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
        assert w["h15"] == 2000                         # idx9 kH/s -> H/s
        assert w["uptime"] == 0                          # idx7 (last share ms) == 0

    def test_list_format_offline_when_no_connections(self):
        # A worker still listed by the proxy but with 0 connections is a stopped miner.
        row = ["rig1", "10.0.0.1", 0, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        [w] = _normalize_proxy_workers({"workers": [row]})
        assert w["status"] == "offline"

    def test_list_format_uptime_estimate_from_last_share(self):
        # idx7 = last share timestamp (ms) -> a non-negative "seconds since last share".
        row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 1_000, 1.0, 2.0, 0, 0, 0]
        [w] = _normalize_proxy_workers({"workers": [row]})
        assert isinstance(w["uptime"], int)
        assert w["uptime"] > 0

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
        summary = {"results": {"accepted": 1000, "rejected": 12, "invalid": 3, "expired": 1,
                               "best": [987654, 5000, 100]}}
        assert _parse_proxy_summary(summary) == {
            "accepted": 1000, "rejected": 12, "invalid": 3, "expired": 1, "best": 987654,
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


class TestMergeDirectStats:
    """Augment proxy workers with direct-API stats; kind-based scaling + keep-online (#39/#28)."""

    def _worker(self):
        return {"name": "rig", "ip": "10.0.0.1", "status": "online",
                "h10": 1, "h60": 2, "h15": 3, "uptime": 0}

    def test_proxy_kind_scales_khs_to_hs(self):
        extra = {"kind": "proxy", "uptime": 120, "hashrate": {"total": [1, 2, 3]}}
        [w] = _merge_direct_stats([self._worker()], [extra], "3333")
        assert (w["h10"], w["h60"], w["h15"]) == (1000, 2000, 3000)
        assert w["uptime"] == 120
        assert w["active_pool"] == "3333"

    def test_xmrig_kind_not_scaled(self):
        extra = {"uptime": 99, "hashrate": {"total": [10, 20, 30]}}
        [w] = _merge_direct_stats([self._worker()], [extra], "3344")
        assert (w["h10"], w["h60"], w["h15"]) == (10, 20, 30)
        assert w["active_pool"] == "3344"

    def test_unreachable_direct_api_keeps_proxy_values_online(self):
        # Falsy extra_stats -> keep proxy-derived hashrate/uptime and stay online (#28).
        w0 = self._worker()
        [w] = _merge_direct_stats([w0], [{}], "3333")
        assert w["status"] == "online"
        assert (w["h10"], w["h60"], w["h15"]) == (1, 2, 3)  # untouched
        assert w["active_pool"] == "3333"

    def test_short_hashrate_total_ignored(self):
        # A <3-entry total isn't applied; uptime still updates and active_pool is tagged.
        extra = {"uptime": 7, "hashrate": {"total": [5, 6]}}
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
            {"status": "online", "h15": 0, "h60": 0, "h10": 700},     # uses h10
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
        with self._tari(required=False), patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"):
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
        proxy.get_summary.return_value = {"results": {"accepted": 100, "rejected": 5, "invalid": 1,
                                                      "expired": 2, "best": [123456]}}

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})  # direct API unreachable
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
        tari_client.close = AsyncMock()

        with patch.object(ds_mod, "ClientSession", _FakeClientSession), \
             patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client), \
             patch.object(ds_mod, "TariClient", return_value=tari_client), \
             patch.object(ds_mod, "get_stratum_stats", return_value=({}, [])), \
             patch.object(ds_mod, "get_network_stats", return_value={"height": 100}), \
             patch.object(ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}), \
             patch.object(ds_mod, "get_p2pool_stats", return_value={"pool": {"last_share_time": 0, "difficulty": 0}}), \
             patch.object(ds_mod, "get_monero_sync_status", AsyncMock(return_value={"is_syncing": False, "percent": 100, "target": 100, "current": 100})), \
             patch.object(ds_mod, "get_disk_usage", return_value={}), \
             patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")), \
             patch.object(ds_mod, "get_memory_usage", return_value={}), \
             patch.object(ds_mod, "get_load_average", return_value="0"), \
             patch.object(ds_mod, "get_cpu_usage", return_value="0%"), \
             patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        # The worker was aggregated and totals computed from proxy-derived hashrate.
        assert svc.latest_data["workers"][0]["name"] == "rig1"
        assert svc.latest_data["workers"][0]["status"] == "online"
        assert svc.latest_data["total_live_h15"] == 2000.0
        # The proxy /summary totals were collected and surfaced (Issue #82).
        assert svc.latest_data["proxy_summary"] == {
            "accepted": 100, "rejected": 5, "invalid": 1, "expired": 2, "best": 123456,
        }
        sm.update_history.assert_called()
        sm.save_snapshot.assert_called()

    async def test_run_holds_miner_while_syncing(self):
        # A syncing Monero node → gate holds p2pool + xmrig-proxy and #31's failover stays
        # dormant (no workers to fail over before we've even started mining).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc._apply_worker_rejection = AsyncMock()

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False, "reachable": True})
        tari_client.close = AsyncMock()

        with patch.object(ds_mod, "ClientSession", _FakeClientSession), \
             patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client), \
             patch.object(ds_mod, "TariClient", return_value=tari_client), \
             patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]), \
             patch.object(ds_mod, "get_stratum_stats", return_value=({}, [])), \
             patch.object(ds_mod, "get_network_stats", return_value={"height": 100}), \
             patch.object(ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}), \
             patch.object(ds_mod, "get_p2pool_stats", return_value={"pool": {"last_share_time": 0, "difficulty": 0}}), \
             patch.object(ds_mod, "get_monero_sync_status", AsyncMock(return_value={"is_syncing": True, "reachable": True, "percent": 50, "current": 50, "target": 100})), \
             patch.object(ds_mod, "get_disk_usage", return_value={}), \
             patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")), \
             patch.object(ds_mod, "get_memory_usage", return_value={}), \
             patch.object(ds_mod, "get_load_average", return_value="0"), \
             patch.object(ds_mod, "get_cpu_usage", return_value="0%"), \
             patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        svc._apply_worker_rejection.assert_not_called()
        assert svc.miner_released is False
        assert svc.latest_data["miner_held"] is True

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
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False, "reachable": True})
        tari_client.close = AsyncMock()

        with patch.object(ds_mod, "ClientSession", _FakeClientSession), \
             patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client), \
             patch.object(ds_mod, "TariClient", return_value=tari_client), \
             patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]), \
             patch.object(ds_mod, "get_stratum_stats", return_value=({}, [])), \
             patch.object(ds_mod, "get_network_stats", return_value={"height": 0}), \
             patch.object(ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}), \
             patch.object(ds_mod, "get_p2pool_stats", return_value={"pool": {"last_share_time": 0, "difficulty": 0}}), \
             patch.object(ds_mod, "get_monero_sync_status", AsyncMock(return_value={"is_syncing": False, "reachable": True})), \
             patch.object(ds_mod, "get_disk_usage", return_value={}), \
             patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")), \
             patch.object(ds_mod, "get_memory_usage", return_value={}), \
             patch.object(ds_mod, "get_load_average", return_value="0"), \
             patch.object(ds_mod, "get_cpu_usage", return_value="0%"), \
             patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)):
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
            return_value={"is_syncing": True, "reachable": True, "percent": 42, "current": 42, "target": 100})
        tari_client.close = AsyncMock()

        with patch.object(ds_mod, "ClientSession", _FakeClientSession), \
             patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client), \
             patch.object(ds_mod, "TariClient", return_value=tari_client), \
             patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]), \
             patch.object(ds_mod, "TARI_REQUIRED", False), \
             patch.object(ds_mod, "get_stratum_stats", return_value=({}, [])), \
             patch.object(ds_mod, "get_network_stats", return_value={"height": 100}), \
             patch.object(ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}), \
             patch.object(ds_mod, "get_p2pool_stats", return_value={"pool": {"last_share_time": 0, "difficulty": 0}}), \
             patch.object(ds_mod, "get_monero_sync_status", AsyncMock(return_value={"is_syncing": False, "reachable": True})), \
             patch.object(ds_mod, "get_disk_usage", return_value={}), \
             patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")), \
             patch.object(ds_mod, "get_memory_usage", return_value={}), \
             patch.object(ds_mod, "get_load_average", return_value="0"), \
             patch.object(ds_mod, "get_cpu_usage", return_value="0%"), \
             patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        assert svc.miner_released is True
        assert svc.latest_data["global_sync"] is False
        assert svc.latest_data["tari_syncing_passive"] is True

    async def test_iteration_survives_collector_error(self):
        svc, sm, proxy = _make_service()
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={})

        with patch.object(ds_mod, "ClientSession", _FakeClientSession), \
             patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client), \
             patch.object(ds_mod, "TariClient", return_value=tari_client), \
             patch.object(ds_mod, "get_stratum_stats", side_effect=RuntimeError("boom")), \
             patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)):
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
            return_value={"is_syncing": True, "reachable": True, "percent": 80, "current": 80, "target": 100})
        tari_client.close = AsyncMock()

        with patch.object(ds_mod, "ClientSession", _FakeClientSession), \
             patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client), \
             patch.object(ds_mod, "TariClient", return_value=tari_client), \
             patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]), \
             patch.object(ds_mod, "TARI_REQUIRED", True), \
             patch.object(ds_mod, "get_stratum_stats", return_value=({}, [])), \
             patch.object(ds_mod, "get_network_stats", return_value={"height": 100}), \
             patch.object(ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}), \
             patch.object(ds_mod, "get_p2pool_stats", return_value={"pool": {"last_share_time": 0, "difficulty": 0}}), \
             patch.object(ds_mod, "get_monero_sync_status", AsyncMock(return_value={"is_syncing": False, "reachable": True})), \
             patch.object(ds_mod, "get_disk_usage", return_value={}), \
             patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")), \
             patch.object(ds_mod, "get_memory_usage", return_value={}), \
             patch.object(ds_mod, "get_load_average", return_value="0"), \
             patch.object(ds_mod, "get_cpu_usage", return_value="0%"), \
             patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)):
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
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]), \
             patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"), \
             patch.object(ds_mod, "TARI_REQUIRED", True):
            await svc._apply_sync_gate(gate_satisfied=False)   # latch → no-op
            await svc._apply_worker_rejection(monero_down=True, tari_down=False)
        stopped = [c.args[0] for c in svc.docker_control.stop.await_args_list]
        assert stopped == ["xmrig-proxy"]          # p2pool was NOT re-held
        svc.docker_control.start.assert_not_called()
        assert svc.workers_rejected is True

    async def test_both_nodes_down_rejects_once(self):
        # A simultaneous Monero+Tari outage (both required) is a single rejection, not two.
        svc, _sm, _proxy = _make_service()
        with patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"), \
             patch.object(ds_mod, "TARI_REQUIRED", True):
            await svc._apply_worker_rejection(monero_down=True, tari_down=True)
        svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
        assert svc.workers_rejected is True
