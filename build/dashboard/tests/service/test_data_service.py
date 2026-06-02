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
