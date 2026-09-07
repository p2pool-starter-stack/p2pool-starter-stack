"""
Contract test: point the REAL dashboard clients at the controllable fakes and assert they
parse every state we need to drive in the mini-stack (issue #54, tier 3 / tier 2 seam).

This is the proof that the fakes speak the daemons' wire format closely enough for the real
MoneroClient / TariClient — and it runs anywhere (no docker, no real chain). If a future
monerod/Tari change breaks the parser, this goes red here instead of only on the live box.

Run: PYTHONPATH=dashboard python3 -m pytest tests/integration/fakes -q
"""

import asyncio
import json
import pathlib
import re
import sys

import requests

_HERE = pathlib.Path(__file__).resolve().parent
_REPO = _HERE.parents[2]
# Make the dashboard package and the fakes importable regardless of how pytest is invoked.
sys.path.insert(0, str(_REPO / "dashboard"))
sys.path.insert(0, str(_HERE))

import aiohttp  # noqa: E402
from fake_monerod import FakeMonerod  # noqa: E402
from fake_tari import start_server  # noqa: E402
from fake_tari_wallet import start_server as start_wallet_server  # noqa: E402
from fake_wallet_rpc import FakeWalletRpc  # noqa: E402
from fake_worker_api import FakeWorkerApi, enriched_body  # noqa: E402

from mining_dashboard.client import xmrig_client as xc  # noqa: E402
from mining_dashboard.client.monero.monero_client import MoneroClient  # noqa: E402
from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient  # noqa: E402
from mining_dashboard.client.tari.tari_client import TariClient  # noqa: E402
from mining_dashboard.client.tari.tari_wallet_client import TariWalletClient  # noqa: E402
from mining_dashboard.client.xmrig_client import (  # noqa: E402
    _CONTROL_TERMINAL,
    XMRigWorkerClient,
    parse_rigforge,
    parse_worker_control_status,
)


# --- Monero (HTTP get_info) -------------------------------------------------
def test_monero_synced_reads_no_sync_and_db_size():
    with FakeMonerod(database_size=85 * 10**9) as m:
        client = MoneroClient(url=m.url, username="")
        st = client.get_sync_status()
    assert st == {"is_syncing": False, "db_size": 85 * 10**9, "synchronized": True}


def test_monero_syncing_reports_percent():
    with FakeMonerod() as m:
        m.set(mode="syncing", height=1500, target_height=3000, database_size=40 * 10**9)
        client = MoneroClient(url=m.url, username="")
        st = client.get_sync_status()
    assert st["is_syncing"] is True
    assert st["current"] == 1500 and st["target"] == 3000 and st["percent"] == 50
    assert st["db_size"] == 40 * 10**9
    # The raw wire flag rides along for the peer-loss detector (#972).
    assert st["synchronized"] is False


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
    assert st == {"is_syncing": False, "db_size": 0, "synchronized": True}


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
# asyncio_mode=auto only applies when pytest's rootdir is dashboard).
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


# --- RigForge worker API ↔ dashboard (the enriched-feed + auth contract, #209) ------------
#
# Point the REAL XMRigWorkerClient at the fake RigForge worker API over a real socket, across the
# none/name/token auth matrix (the #315 model — the issue body's old "Bearer <rig name>" is one mode
# of three). This proves the wiring the tier-1 xmrig_client unit tests mock away: the bearer is
# actually transmitted, a real 401 is handled, and the real enriched /1/summary parses through
# parse_rigforge. A drift in RigForge's auth handshake or enriched-feed shape (rigforge#99) goes red
# here, not only on a live rig. The real-rig legs (real mining, real proxy /workers aggregation,
# stratum --access-password) stay tier-4 — see docs/dev/integration-testing.md.
#
# The client reaches a loopback fake via an operator-set descriptor `host` (the trusted config.json
# path), NOT the miner-IP path — a worker IP of 127.0.0.1 is correctly refused by the #122 SSRF guard
# (proven in the tier-1 suite), so a descriptor is the honest way to target a local test server.


def _probe_worker(fake, *, auth="none", token="", fleet_token="", name="rig1"):
    """Run one real get_stats() against `fake`, configuring the client exactly as config.py would.

    Restores the module globals afterward so the matrix cases don't leak into each other."""
    saved = (xc.WORKER_ENDPOINTS, xc.XMRIG_API_AUTH, xc.XMRIG_API_TOKEN)
    entry = {"name": name, "host": fake.host, "port": fake.port}
    if token:
        entry["token"] = token  # a per-worker token forces token-auth for that rig
    xc.WORKER_ENDPOINTS = [entry]
    xc.XMRIG_API_AUTH = auth
    xc.XMRIG_API_TOKEN = fleet_token

    async def _impl():
        async with aiohttp.ClientSession() as session:
            client = XMRigWorkerClient(session)
            # ip is unused here (descriptor host wins); pass the stratum name for name-auth.
            return await client.get_stats("203.0.113.5", name)

    try:
        return asyncio.run(_impl())
    finally:
        xc.WORKER_ENDPOINTS, xc.XMRIG_API_AUTH, xc.XMRIG_API_TOKEN = saved


def test_worker_auth_none_open_api_reads_and_parses():
    with FakeWorkerApi(auth="none") as fake:
        payload = _probe_worker(fake, auth="none")
    assert payload["api_ok"] is True
    rf = parse_rigforge(payload)  # the enriched block parses through the real consumer
    assert rf is not None and rf["miner_down"] is False
    assert rf["power"] == {"watts": 142.0, "hs_per_watt": 35.9}
    assert rf["health"]["governor"] == "performance"
    assert rf["watchdog"]["max_temp_c"] == 85


def test_worker_auth_name_sends_bearer_name():
    # name mode: the rig's xmrig access-token equals its stratum name (Bearer = name).
    with FakeWorkerApi(auth="name", name="rig1") as fake:
        ok = _probe_worker(fake, auth="name", name="rig1")
        assert ok["api_ok"] is True
    # A rig whose name doesn't match what the API expects is a 401, surfaced as api_ok False.
    with FakeWorkerApi(auth="name", name="someone-else") as fake:
        bad = _probe_worker(fake, auth="name", name="rig1")
        assert bad == {"api_ok": False, "adopted": False}


def test_worker_per_worker_token_forces_token_auth():
    # A per-worker descriptor token (#172) is sent as the bearer whatever the fleet mode is.
    with FakeWorkerApi(auth="token", token="s3cr3t") as fake:
        ok = _probe_worker(fake, auth="none", token="s3cr3t")
        assert ok["api_ok"] is True
    # Wrong token → real 401 → api_ok False (the documented misconfiguration failure mode).
    with FakeWorkerApi(auth="token", token="s3cr3t") as fake:
        bad = _probe_worker(fake, auth="none", token="wrong")
        assert bad == {"api_ok": False, "adopted": True}


def test_worker_fleet_token_mode_sends_shared_token():
    with FakeWorkerApi(auth="token", token="fleetwide") as fake:
        ok = _probe_worker(fake, auth="token", fleet_token="fleetwide")
        assert ok["api_ok"] is True


def test_worker_miner_down_body_parses_as_up_but_miner_down():
    # RigForge up, XMRig unreachable: the block alone, flagged — the UI shows up-but-miner-down.
    with FakeWorkerApi(auth="none", miner_down=True) as fake:
        payload = _probe_worker(fake, auth="none")
    assert payload["api_ok"] is True
    rf = parse_rigforge(payload)
    assert rf is not None and rf["miner_down"] is True


# --- The wire contract RigForge publishes for us (#1412) ------------------------------------
#
# Everything above proves our fake and the real consumers agree. Nothing above tied the FAKE to
# what a real worker emits, so the pair could drift together and stay green — a guard anchored to
# the wrong artifact, which reads as coverage. RigForge regenerates `tests/contract/v1/` from its
# real code paths and byte-compares it on every one of its own runs, so those fixtures are the
# producer's own account of the wire. `contract/v1/` here is a vendored copy of them.
#
# Division of labour, because a reader should not have to infer it: the fixture pins the SHAPE and
# the fake pins realistic VALUES (the fixture is a hardware-independent capture whose numeric
# fields are mostly null). So the guards below compare key paths, never values.

_CONTRACT = _HERE / "contract" / "v1"


def _key_paths(obj, prefix=""):
    """Every leaf path in `obj`, list indices collapsed to `[]` so ordering and length don't count."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from _key_paths(v, f"{prefix}.{k}" if prefix else k)
    elif isinstance(obj, list):
        for v in obj:
            yield from _key_paths(v, prefix + "[]")
        if not obj:
            yield prefix + "[]"
    else:
        yield prefix


def test_fake_matches_the_vendored_wire_contract():
    """Our fake's `rigforge` block carries exactly the keys a real worker emits — no more, no less.

    Equality in both directions on purpose. A missing key is a surface the contract test cannot
    see (that is how config/config_meta/control went uncovered); an extra key is our fake inventing
    a shape no rig sends, which is how a consumer comes to depend on something that isn't there.
    """
    pinned = set(_key_paths(json.loads((_CONTRACT / "feed.json").read_text())["rigforge"]))
    assert set(_key_paths(enriched_body()["rigforge"])) == pinned

    # The miner-unreachable body drops every XMRig key and serves the WHOLE block plus one flag —
    # config/config_meta/control included. Same producer path, so the same guard has to cover it.
    down = enriched_body(miner_down=True)
    assert set(down) == {"rigforge"}
    assert set(_key_paths(down["rigforge"])) == pinned | {"xmrig_api"}


def test_vendored_contract_ref_line_agrees_with_the_baked_pin():
    """PROVENANCE's ref line agrees with the ref the appliance bakes — the string, not the bytes.

    A vendored snapshot with no freshness mechanism is just a slower drift: it agrees with the
    producer on the day it is copied and silently stops. This half is offline and reads two
    hand-edited strings, so it cannot see the fixture content; the bytes are covered by
    test_contract_freshness.py, which consults the producer itself (#1426).
    """
    provenance = dict(line.split("=", 1) for line in (_CONTRACT / "PROVENANCE").read_text().split())
    dockerfile = (_REPO / "os" / "rootfs" / "Dockerfile").read_text()
    baked = re.search(r"^ARG RIGFORGE_REF=(\S+)", dockerfile, re.M)
    assert baked, "RIGFORGE_REF not found in os/rootfs/Dockerfile — did the pin move or rename?"
    assert provenance["ref"] == baked.group(1), (
        "the baked RigForge pin moved and PROVENANCE was not updated. Re-copy "
        "tests/contract/v1/{feed,control-status}.json from RigForge at the new ref, THEN update "
        "PROVENANCE — this guard reads the ref line; the bytes are test_contract_freshness.py."
    )


def test_every_pinned_control_status_is_classified():
    """Every status word RigForge can emit is one this repo has actually decided about.

    RigForge's own guard cross-checks this vocabulary against the literals in its source, so the
    fixture cannot fall behind its producer. This is the consumer half: a NEW status word must fail
    here rather than fall through `not in _CONTROL_TERMINAL` and be read as "still in flight"
    forever. That is exactly what happened with noop/throttled, which nothing outside a live run
    caught. Fail-closed by construction — a word in neither set is an error, not a default.
    """
    pinned = set(json.loads((_CONTRACT / "control-status.json").read_text())["statuses"])
    # Words we deliberately class as NOT terminal: the rig has begun a change and has not said how
    # it ended. Listed, not inferred, so adding one is deliberate. `pinned` must be non-empty — a
    # difference against an empty left side is empty, so an emptied `statuses` checks nothing.
    non_terminal = {"pending", "started"}
    assert pinned and pinned - set(_CONTROL_TERMINAL) - non_terminal == set()


def test_worker_config_prefill_parses_over_the_wire():
    """The rig's effective writable config reaches the editor's prefill (#1235), over a real socket."""
    with FakeWorkerApi(auth="none") as fake:
        payload = _probe_worker(fake, auth="none")
    cfg = parse_rigforge(payload)["config"]
    # Exactly the writable keys, with the rig's own values; pools[].pass is the producer's {"__secret__": true} marker, kept as-is (rigforge#415, #1548).
    assert cfg == {
        "pools": [{"url": "itest-proxy:3333", "pass": {"__secret__": True}}],
        "DONATION": 1,
        "autotune": "disabled",
        "watchdog": "enabled",
        "watchdog_interval_min": 5,
        "max_temp_c": 85,
    }


def test_worker_config_provenance_parses_over_the_wire():
    """The rig's account of where its config came from (#1345) survives the wire intact."""
    with FakeWorkerApi(auth="none") as fake:
        payload = _probe_worker(fake, auth="none")
    assert parse_rigforge(payload)["config_meta"] == {
        "revision": "50c51399833d2a28",
        "changed_at": "2026-08-24T09:15:00Z",
        "source": "control",
        "last_change_id": "7777777777777777",
    }


def test_worker_control_outcome_mirrors_over_the_wire():
    """A terminal control outcome rides the read feed (#579) and reconciles a history row."""
    with FakeWorkerApi(auth="none") as fake:
        payload = _probe_worker(fake, auth="none")
    assert parse_worker_control_status(payload) == {
        "change_id": "7777777777777777",
        "status": "rolled_back",
        "reason": "miner did not return to a live hashrate; rolled back and live",
    }


def test_a_rig_mid_change_or_fresh_reconciles_nothing():
    """Non-terminal and never-changed both return None — a history row is never force-terminaled.

    `control: null` is the fresh-rig wire shape: the producer's jq falls back to a literal null
    rather than omitting the key, so this is the body a rig serves before any change has ever run.
    """
    for control in (None, {"change_id": "8888888888888888", "status": "started", "reason": None}):
        with FakeWorkerApi(auth="none", control=control) as fake:
            payload = _probe_worker(fake, auth="none")
        assert parse_worker_control_status(payload) is None
        # The rest of the block still parses — a rig with no control history is not a broken rig.
        assert parse_rigforge(payload)["config_meta"]["revision"] == "50c51399833d2a28"
