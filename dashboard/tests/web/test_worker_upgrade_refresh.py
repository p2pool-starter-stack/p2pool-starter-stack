"""The #1233 refresh trigger, end to end through the real ``/api/control/worker-upgrade`` route and
its background finalizer (mirrors ``test_server.py``'s ``TestWorkerUpgradeRecordsHistory`` fixture
shape, since ``worker_refresh`` is exercised from the SAME background task that records history).

Each test names the mutation it would catch:
  - deleting the ``maybe_refresh_after_upgrade`` call in ``_finalize_worker_upgrade`` (or any
    guard that made it unreachable) would leave the refresh mock uncalled on a genuine success —
    ``test_applied_result_triggers_refresh`` / ``test_accepted_result_triggers_refresh`` catch that.
  - inverting the success/non-success split would fire it on a rejection or skip a real success —
    the paired non-firing tests below catch either direction.
  - passing the wrong worker/version (e.g. the client's stale proposal instead of the host's
    re-derived tag) would still pass a "was it called" test but fail the exact-args assertion.
"""

import json
import uuid
from unittest.mock import AsyncMock

import pytest

from mining_dashboard.service import control_service, worker_refresh
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import create_app

CONTROL_HEADERS = {"X-Pithead-Control": "1"}


@pytest.fixture
def control_spool(tmp_path, monkeypatch):
    host_config = tmp_path / "config.json"
    host_config.write_text(
        json.dumps({"dashboard": {"auth": {"username": "admin", "password": "correct horse"}}})
    )
    (tmp_path / "requests").mkdir()
    (tmp_path / "results").mkdir()
    monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host_config))
    monkeypatch.setattr(
        control_service.config, "HOST_REFERENCE_PATH", str(tmp_path / "no-reference.json")
    )
    monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    monkeypatch.setattr(control_service.config, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    monkeypatch.setattr(control_service.config, "CONTROL_WAIT_S", 0.1)
    monkeypatch.setattr(control_service.config, "CONTROL_WORKER_UPGRADE_WAIT_S", 0.5)
    return tmp_path


@pytest.fixture
async def worker_client(aiohttp_client, control_spool, monkeypatch):
    from mining_dashboard.config import config as cfg_mod

    monkeypatch.setattr(
        cfg_mod, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "10.0.0.9", "control_port": 8082}]
    )
    data = {
        "workers": [
            {
                "name": "rig1",
                "ip": "10.0.0.9",
                "status": "online",
                "active_pool": "3333",
                "h60": 0,
                "rigforge": {"version": "1.11.0"},
            }
        ]
    }
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, data))
    cli.sm = sm
    yield cli
    sm.close()


async def _upgrade(worker_client, control_spool, monkeypatch, result):
    rid = str(uuid.uuid4())
    monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
    (control_spool / "results" / f"{rid}.json").write_text(json.dumps(result))
    resp = await worker_client.post(
        "/api/control/worker-upgrade",
        json={"worker": "rig1", "version": "v1.12.0"},
        headers=CONTROL_HEADERS,
    )
    assert resp.status == 202
    import asyncio

    await asyncio.gather(*worker_client.app["_bg_tasks"])


class TestUpgradeRefreshTrigger:
    async def test_applied_result_triggers_refresh(self, worker_client, control_spool, monkeypatch):
        called = AsyncMock(return_value=True)
        monkeypatch.setattr(worker_refresh, "refresh_worker_after_upgrade", called)
        result = {"status": "applied", "change_id": "cid", "worker": "rig1", "version": "v1.12.0"}
        await _upgrade(worker_client, control_spool, monkeypatch, result)
        called.assert_awaited_once_with(worker_client.app["latest_data"], "rig1", "v1.12.0")

    async def test_accepted_result_triggers_refresh(
        self, worker_client, control_spool, monkeypatch
    ):
        called = AsyncMock(return_value=True)
        monkeypatch.setattr(worker_refresh, "refresh_worker_after_upgrade", called)
        result = {"status": "accepted", "change_id": "cid", "worker": "rig1", "version": "v1.12.0"}
        await _upgrade(worker_client, control_spool, monkeypatch, result)
        called.assert_awaited_once()

    @pytest.mark.parametrize("status", ["rejected", "failed", "rolled_back", "throttled", "noop"])
    async def test_non_success_result_does_not_trigger_refresh(
        self, worker_client, control_spool, monkeypatch, status
    ):
        called = AsyncMock(return_value=True)
        monkeypatch.setattr(worker_refresh, "refresh_worker_after_upgrade", called)
        result = {"status": status, "change_id": "cid", "worker": "rig1", "version": "v1.12.0"}
        await _upgrade(worker_client, control_spool, monkeypatch, result)
        called.assert_not_awaited()
