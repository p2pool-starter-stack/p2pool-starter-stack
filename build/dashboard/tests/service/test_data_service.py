from unittest.mock import MagicMock, AsyncMock, patch

import pytest

import mining_dashboard.service.data_service as ds_mod
from mining_dashboard.service.data_service import DataService


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
    return DataService(state_manager, proxy_client, xvb_client), state_manager, proxy_client


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


class TestWorkerRejection:
    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc

    def _flags(self, monero=True, tari=True):
        # Both reject toggles patched in the data_service module namespace.
        return (patch.object(ds_mod, "REJECT_WORKERS_ON_MONERO_DOWN", monero),
                patch.object(ds_mod, "REJECT_WORKERS_ON_TARI_DOWN", tari))

    async def test_no_action_when_both_disabled(self):
        svc = self._svc()
        m, t = self._flags(monero=False, tari=False)
        with m, t:
            await svc._apply_worker_rejection(monero_down=True, tari_down=True)
        svc.docker_control.stop.assert_not_called()
        assert svc.workers_rejected is False

    async def test_stop_when_monero_down(self):
        svc = self._svc()
        m, t = self._flags()
        with m, t, patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"):
            await svc._apply_worker_rejection(monero_down=True, tari_down=False)
        svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
        assert svc.workers_rejected is True

    async def test_stop_when_tari_down_and_enabled(self):
        svc = self._svc()
        m, t = self._flags()
        with m, t:
            await svc._apply_worker_rejection(monero_down=False, tari_down=True)
        svc.docker_control.stop.assert_awaited_once()
        assert svc.workers_rejected is True

    async def test_tari_down_ignored_when_tari_toggle_off(self):
        # Per-node: a Tari-only outage must NOT reject workers when reject-on-tari is off —
        # we can still mine Monero on p2pool.
        svc = self._svc()
        m, t = self._flags(monero=True, tari=False)
        with m, t:
            await svc._apply_worker_rejection(monero_down=False, tari_down=True)
        svc.docker_control.stop.assert_not_called()
        assert svc.workers_rejected is False

    async def test_stop_failure_keeps_flag_false_for_retry(self):
        svc = self._svc()
        svc.docker_control.stop = AsyncMock(return_value=False)
        m, t = self._flags()
        with m, t:
            await svc._apply_worker_rejection(monero_down=True, tari_down=False)
        assert svc.workers_rejected is False  # so the next cycle retries

    async def test_no_double_stop_when_already_rejected(self):
        svc = self._svc()
        svc.workers_rejected = True
        m, t = self._flags()
        with m, t:
            await svc._apply_worker_rejection(monero_down=True, tari_down=True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()

    async def test_readmit_when_relevant_nodes_healthy(self):
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = True
        svc.tari_health.healthy = True
        m, t = self._flags()
        with m, t:
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
        m, t = self._flags()
        with m, t:
            await svc._apply_worker_rejection(monero_down=False, tari_down=False)
        svc.docker_control.start.assert_not_called()
        assert svc.workers_rejected is True

    async def test_readmit_ignores_node_whose_toggle_is_off(self):
        # reject-on-tari off → Tari health is irrelevant to readmission; monero healthy is enough.
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = True
        svc.tari_health.healthy = False
        m, t = self._flags(monero=True, tari=False)
        with m, t:
            await svc._apply_worker_rejection(monero_down=False, tari_down=False)
        svc.docker_control.start.assert_awaited_once()
        assert svc.workers_rejected is False


class TestRunIteration:
    async def test_single_iteration_aggregates(self):
        svc, sm, proxy = _make_service()

        # A proxy worker in the 6.x list format (>=13 fields): connections=1 (online),
        # idx8=1.0 kH/s, idx9=2.0 kH/s -> h15 = 2000 H/s.
        worker_row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        proxy.get_workers.return_value = {"workers": [worker_row]}

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
        sm.update_history.assert_called()
        sm.save_snapshot.assert_called()

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
