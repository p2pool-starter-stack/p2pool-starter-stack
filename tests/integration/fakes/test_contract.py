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

_HERE = pathlib.Path(__file__).resolve().parent
_REPO = _HERE.parents[2]
# Make the dashboard package and the fakes importable regardless of how pytest is invoked.
sys.path.insert(0, str(_REPO / "build" / "dashboard"))
sys.path.insert(0, str(_HERE))

from fake_monerod import FakeMonerod  # noqa: E402
from fake_tari import start_server  # noqa: E402
from fake_tari_wallet import start_server as start_wallet_server  # noqa: E402
from fake_wallet_rpc import FakeWalletRpc  # noqa: E402

from mining_dashboard.client.monero.monero_client import MoneroClient  # noqa: E402
from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient  # noqa: E402
from mining_dashboard.client.tari.tari_client import TariClient  # noqa: E402
from mining_dashboard.client.tari.tari_wallet_client import TariWalletClient  # noqa: E402


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


def test_monero_busy_status_is_unreachable():
    # HTTP 200 but status=BUSY (e.g. mid-reorg): the client must distrust it, not read it synced.
    with FakeMonerod() as m:
        m.set(mode="busy")
        assert MoneroClient(url=m.url, username="").get_sync_status() is None


def test_monero_synced_by_height_even_without_flag():
    # synchronized=false but height has reached target → caught up (mirrors monerod at the tip).
    with FakeMonerod() as m:
        m.set(mode="syncing", height=3_000_000, target_height=3_000_000)
        st = MoneroClient(url=m.url, username="").get_sync_status()
    assert st["is_syncing"] is False


def test_monero_db_size_unknown_reads_zero():
    with FakeMonerod(database_size=0) as m:
        st = MoneroClient(url=m.url, username="").get_sync_status()
    assert st == {"is_syncing": False, "db_size": 0}


def test_monero_http_control_mutates_state():
    # Validates the /control path the docker mini-stack drives over the network.
    with FakeMonerod() as m:
        requests.post(
            m.url + "/control",
            json={"mode": "syncing", "height": 10, "target_height": 100},
            timeout=5,
        )
        info = requests.get(m.url + "/get_info", timeout=5).json()
    assert info["synchronized"] is False and info["height"] == 10 and info["target_height"] == 100


# --- Monero payout wallet (view-only monero-wallet-rpc, #381) ----------------
def test_wallet_confirmed_payouts_parse_and_convert():
    rows = [
        {"txid": "a1", "amount": 250_000_000_000, "height": 100, "timestamp": 1000},
        {"txid": "b2", "amount": 500_000_000_000, "height": 200, "timestamp": 2000},
    ]
    with FakeWalletRpc(transfers=rows) as w:
        client = MoneroWalletClient(url=w.url, username="")  # fake serves no digest auth
        out = client.get_confirmed_payouts(min_height=0)
    assert [p["txid"] for p in out] == ["a1", "b2"]
    assert out[0]["amount_atomic"] == 250_000_000_000 and out[0]["amount_xmr"] == 0.25


def test_wallet_min_height_filters_server_side():
    # The client seeds min_height from the last stored payout; the wallet must honor it so a
    # re-scan of the tip returns only new rows (idempotent storage then drops any overlap).
    rows = [
        {"txid": "old", "amount": 1, "height": 100, "timestamp": 1},
        {"txid": "new", "amount": 2, "height": 300, "timestamp": 2},
    ]
    with FakeWalletRpc(transfers=rows) as w:
        out = MoneroWalletClient(url=w.url, username="").get_confirmed_payouts(min_height=200)
    assert [p["txid"] for p in out] == ["new"]


def test_wallet_no_transfers_yet_reads_empty():
    with FakeWalletRpc(transfers=[]) as w:
        assert MoneroWalletClient(url=w.url, username="").get_confirmed_payouts() == []


# --- Tari (gRPC BaseNode) ---------------------------------------------------
# Driven via asyncio.run so they don't depend on pytest-asyncio being active (the dashboard's
# asyncio_mode=auto only applies when pytest's rootdir is build/dashboard).
async def _tari_get_status(state):
    server, bound = await start_server(0, state)
    client = TariClient()
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


def test_tari_syncing_without_reliable_target_avoids_false_100():
    # Early sync: the node can't give a target above local height yet → report syncing at 0%,
    # never a premature ✔ (target 0, not a bogus 100%).
    st = asyncio.run(_tari_get_status({"mode": "syncing", "height": 1000, "target_height": 1000}))
    assert st["is_syncing"] is True and st["target"] == 0 and st["percent"] == 0


def test_tari_serves_cached_reading_when_briefly_unreachable():
    # A busy-but-alive node (gRPC blips) should keep showing its last good reading, flagged
    # reachable=False so node-down detection still sees the outage.
    async def _impl():
        state = {"mode": "synced", "height": 2000, "target_height": 2000}
        server, bound = await start_server(0, state)
        client = TariClient()
        client.grpc_address = f"127.0.0.1:{bound}"
        try:
            first = await client.get_sync_status()  # live: synced + reachable
            state["mode"] = "down"
            second = await client.get_sync_status()  # cached: last reading, reachable False
            return first, second
        finally:
            await client.close()
            await server.stop(None)

    first, second = asyncio.run(_impl())
    assert first["reachable"] is True and first["is_syncing"] is False
    assert second["reachable"] is False and second["is_syncing"] is False


# --- Tari payout wallet (view-only minotari console wallet, #462) ------------
async def _tari_confirmed_payouts(transactions, min_height=0):
    state = {"transactions": transactions}
    server, bound = await start_wallet_server(0, state)
    client = TariWalletClient(grpc_address=f"127.0.0.1:{bound}")
    try:
        return await client.get_confirmed_payouts(min_height=min_height)
    finally:
        await client.close()
        await server.stop(None)


def test_tari_wallet_confirmed_payouts_parse_and_convert():
    txs = [
        {"tx_id": 11, "amount": 250_000, "mined_in_block_height": 100, "timestamp": 1000},
        {"tx_id": 22, "amount": 500_000, "mined_in_block_height": 200, "timestamp": 2000},
    ]
    out = asyncio.run(_tari_confirmed_payouts(txs))
    assert [p["txid"] for p in out] == ["11", "22"]
    assert out[0]["amount_atomic"] == 250_000 and out[0]["amount_xtm"] == 0.25  # µT ÷ 1e6


def test_tari_wallet_min_height_filters_the_tip():
    # The client seeds min_height from the last stored payout; only newer confirmations return
    # (idempotent storage then drops any overlap), so a restart replays nothing.
    txs = [
        {"tx_id": 1, "amount": 1, "mined_in_block_height": 100, "timestamp": 1},
        {"tx_id": 2, "amount": 2, "mined_in_block_height": 300, "timestamp": 2},
    ]
    out = asyncio.run(_tari_confirmed_payouts(txs, min_height=200))
    assert [p["txid"] for p in out] == ["2"]


def test_tari_wallet_no_transactions_reads_empty():
    assert asyncio.run(_tari_confirmed_payouts([])) == []
