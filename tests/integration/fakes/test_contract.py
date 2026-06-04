"""
Contract test: point the REAL dashboard clients at the controllable fakes and assert they
parse every state we need to drive in the mini-stack (issue #54, tier 3 / tier 2 seam).

This is the proof that the fakes speak the daemons' wire format closely enough for the real
MoneroClient / TariClient — and it runs anywhere (no docker, no real chain). If a future
monerod/Tari change breaks the parser, this goes red here instead of only on the live box.

Run: PYTHONPATH=build/dashboard python3 -m pytest tests/integration/fakes -q
"""
import asyncio
import pathlib
import sys

import requests
from unittest.mock import MagicMock

_HERE = pathlib.Path(__file__).resolve().parent
_REPO = _HERE.parents[2]
# Make the dashboard package and the fakes importable regardless of how pytest is invoked.
sys.path.insert(0, str(_REPO / "build" / "dashboard"))
sys.path.insert(0, str(_HERE))

from fake_monerod import FakeMonerod  # noqa: E402
from fake_tari import start_server  # noqa: E402
from mining_dashboard.client.monero.monero_client import MoneroClient  # noqa: E402
from mining_dashboard.client.tari.tari_client import TariClient  # noqa: E402


# --- Monero (HTTP get_info) -------------------------------------------------
def test_monero_synced_reads_no_sync_and_db_size():
    with FakeMonerod(database_size=85 * 10**9) as m:
        client = MoneroClient(url=m.url, username="")
        st = client.get_sync_status()
    assert st == {"is_syncing": False, "db_size": 85 * 10**9}


def test_monero_syncing_reports_percent():
    with FakeMonerod() as m:
        m.set(mode="syncing", height=1500, target_height=3000, database_size=40 * 10**9)
        client = MoneroClient(url=m.url, username="")
        st = client.get_sync_status()
    assert st["is_syncing"] is True
    assert st["current"] == 1500 and st["target"] == 3000 and st["percent"] == 50
    assert st["db_size"] == 40 * 10**9


def test_monero_down_is_unreachable():
    with FakeMonerod() as m:
        m.set(mode="down")
        client = MoneroClient(url=m.url, username="")
        assert client.get_sync_status() is None


def test_monero_http_control_mutates_state():
    # Validates the /control path the docker mini-stack drives over the network.
    with FakeMonerod() as m:
        requests.post(m.url + "/control", json={"mode": "syncing", "height": 10, "target_height": 100}, timeout=5)
        info = requests.get(m.url + "/get_info", timeout=5).json()
    assert info["synchronized"] is False and info["height"] == 10 and info["target_height"] == 100


# --- Tari (gRPC BaseNode) ---------------------------------------------------
# Driven via asyncio.run so they don't depend on pytest-asyncio being active (the dashboard's
# asyncio_mode=auto only applies when pytest's rootdir is build/dashboard).
async def _tari_get_status(state):
    server, bound = await start_server(0, state)
    client = TariClient(MagicMock())
    client.grpc_address = f"127.0.0.1:{bound}"
    try:
        return await client.get_sync_status()
    finally:
        await client.close()
        await server.stop(None)


def test_tari_synced_reads_done():
    st = asyncio.run(_tari_get_status({"mode": "synced", "height": 2000, "target_height": 2000}))
    assert st["is_syncing"] is False and st["reachable"] is True and st["percent"] == 100


def test_tari_syncing_reports_percent():
    st = asyncio.run(_tari_get_status({"mode": "syncing", "height": 500, "target_height": 2000}))
    assert st["is_syncing"] is True and st["percent"] == 25 and st["reachable"] is True


def test_tari_down_is_unreachable_with_no_cache():
    # No prior good reading to cache, so a down node is reported unreachable immediately.
    st = asyncio.run(_tari_get_status({"mode": "down", "height": 0, "target_height": 0}))
    assert st["reachable"] is False
