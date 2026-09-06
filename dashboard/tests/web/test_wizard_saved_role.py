"""The set-up-again screen's server half (#1318).

A boot with `pithead.setup=1` publishes one extra spool file, `saved-role.json`, naming the role
this machine is already set up as. Its PRESENCE is the whole signal: the page offers "Keep it"
only when the host said what there is to keep. These tests pin that reading and the one write
the Keep half makes.

They live beside `test_wizard.py` rather than in it because that file is at its budget ceiling.
"""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import wizard


@pytest.fixture
def spool(tmp_path, monkeypatch):
    sd = tmp_path / "spool"
    sd.mkdir()
    monkeypatch.setenv("WIZARD_SPOOL", str(sd))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    sd.joinpath("config.reference.json").write_text(json.dumps({"p2pool": {"pool": "mini"}}))
    return sd


@pytest.fixture
async def client(spool):
    c = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await c.start_server()
    yield c
    await c.close()


async def _auth(client, token="pit-X7KM2Q"):  # noqa: S107 — the test fixture's token, not a secret
    return await client.post("/auth", data={"token": token}, allow_redirects=False)


async def _state(client):
    return await (await client.get("/api/wizard-state")).json()


RIG = {"role": "rig", "pool": "pithead.lan:3333", "worker": "rig-01"}


# --- what the page reads ---------------------------------------------------------------------


async def test_saved_role_is_always_a_key_and_is_null_on_a_normal_boot(client):
    """The client asserts on null, never on absence — so the key has to be there either way."""
    await _auth(client)
    s = await _state(client)
    assert "saved_role" in s
    assert s["saved_role"] is None


async def test_a_rig_boot_carries_the_pool_and_worker_the_screen_names(client, spool):
    spool.joinpath("saved-role.json").write_text(json.dumps(RIG))
    await _auth(client)
    assert (await _state(client))["saved_role"] == RIG


async def test_a_coordinator_boot_carries_the_role_alone(client, spool):
    """A coordinator has no pool or worker to name, and the file says only what it is."""
    spool.joinpath("saved-role.json").write_text(json.dumps({"role": "pithead"}))
    await _auth(client)
    assert (await _state(client))["saved_role"] == {"role": "pithead"}


@pytest.mark.parametrize(
    ("label", "written"),
    [
        ("not json at all", "{"),
        ("json that is not an object", "[1, 2]"),
        ("an object naming no role", "{}"),
        ("a role that is empty", '{"role": ""}'),
        ("a role that is not a string", '{"role": 3}'),
        ("a rig whose role key is misspelled", '{"roles": "rig", "worker": "rig-01"}'),
    ],
)
async def test_an_unusable_file_reads_as_absent_rather_than_failing(client, spool, label, written):
    """Never hard-fail and never offer to keep a role the page cannot name: fall through to the
    normal wizard. The host writes this file atomically, so a half-written one is not expected —
    the rule holds anyway, because the cost of being wrong here is a machine that cannot be set
    up at all."""
    spool.joinpath("saved-role.json").write_text(written)
    await _auth(client)
    s = await _state(client)
    assert s["saved_role"] is None, label
    assert s["stage"] == "setup", label  # the normal wizard, not an error page


async def test_the_unusable_cases_are_narrow(client, spool):
    """The control that keeps the row above honest: the same reader, given a usable file, has to
    produce the OTHER answer. Without this, a reader that returned None for everything would
    pass every case in that table."""
    spool.joinpath("saved-role.json").write_text(json.dumps(RIG))
    await _auth(client)
    assert (await _state(client))["saved_role"] is not None


# --- the one write the Keep half makes -------------------------------------------------------


async def test_keep_role_writes_the_file_the_host_waits_on(client, spool):
    spool.joinpath("saved-role.json").write_text(json.dumps(RIG))
    await _auth(client)
    r = await client.post("/keep-role")
    assert r.status == 200
    assert (await r.json())["status"] == "kept"
    assert (spool / "keep-role").read_text() == "1"


async def test_keep_role_needs_the_token(client, spool):
    spool.joinpath("saved-role.json").write_text(json.dumps(RIG))
    r = await client.post("/keep-role", allow_redirects=False)
    assert r.status == 302
    assert not (spool / "keep-role").exists()


async def test_keep_role_refuses_when_there_is_no_role_to_keep(client, spool):
    """The screen is not reachable on a normal boot, so this is a client that invented the call
    — it writes nothing rather than telling the host to keep a configuration nobody named."""
    await _auth(client)
    assert (await client.post("/keep-role")).status == 400
    assert not (spool / "keep-role").exists()
