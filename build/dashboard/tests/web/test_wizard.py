"""First-boot wizard (#77 phase 3): token gate, lockout, atomic spool write."""

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
    return sd


@pytest.fixture
async def client(spool):
    exits = []
    app = wizard.make_app(exit_fn=lambda code: exits.append(code))
    app["exits"] = exits
    c = TestClient(TestServer(app))
    await c.start_server()
    yield c
    await c.close()


async def test_index_is_the_token_gate(client):
    r = await client.get("/")
    assert r.status == 200
    assert "Token" in await r.text()


async def test_setup_redirects_unauthed(client):
    r = await client.get("/setup", allow_redirects=False)
    assert r.status == 302
    assert r.headers["Location"] == "/"


async def test_wrong_token_403_and_lockout_exits_3(client):
    for i in range(wizard.MAX_FAILURES):
        r = await client.post("/auth", data={"token": f"bad-{i}"})
        assert r.status == 403
    assert client.app["exits"] == [wizard.EXIT_TOKEN_LOCKOUT]


async def test_right_token_sets_cookie_and_unlocks_form(client):
    r = await client.post("/auth", data={"token": "pit-X7KM2Q"})
    assert r.status == 200  # followed the redirect to /setup
    assert "Monero payout address" in await r.text()
    r = await client.get("/setup")
    assert r.status == 200


async def test_submit_writes_spool_config_atomically(client, spool):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post(
        "/submit",
        data={
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "tari-addr",
            "monero_mode": "remote",
            "remote_host": "192.168.1.10",
            "pool": "mini",
            "clearnet_sync": "true",
        },
    )
    assert r.status == 200
    cfg = json.loads((spool / "config.json").read_text())
    assert cfg["monero"]["wallet_address"].startswith("4")
    assert cfg["monero"]["mode"] == "remote"
    assert cfg["monero"]["remote"]["host"] == "192.168.1.10"
    assert cfg["monero"]["clearnet_initial_sync"] is True
    assert cfg["tari"]["clearnet_initial_sync"] is True
    assert cfg["p2pool"] == {"pool": "mini", "stratum_password": "auto"}
    # No half-written temp files remain beside the atomic rename target.
    assert [p.name for p in spool.iterdir()] == ["config.json"]


async def test_local_mode_omits_remote_and_clearnet_keys(client, spool):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    await client.post(
        "/submit",
        data={
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "t",
            "monero_mode": "local",
            "pool": "main",
            "clearnet_sync": "false",
        },
    )
    cfg = json.loads((spool / "config.json").read_text())
    assert "mode" not in cfg["monero"]
    assert "remote" not in cfg["monero"]
    assert "clearnet_initial_sync" not in cfg["monero"]
    assert cfg["p2pool"]["pool"] == "main"


async def test_submit_unauthed_redirects_and_writes_nothing(client, spool):
    r = await client.post("/submit", data={"monero_wallet": "x"}, allow_redirects=False)
    assert r.status == 302
    assert not (spool / "config.json").exists()


async def test_status_reflects_spool_state(client, spool):
    assert "Waiting" in await (await client.get("/status")).text()
    (spool / "error.txt").write_text("bad wallet")
    assert "Rejected: bad wallet" in await (await client.get("/status")).text()
    (spool / "applied").write_text("1")
    assert "Provisioned" in await (await client.get("/status")).text()


async def test_submit_clears_previous_error(client, spool):
    (spool / "error.txt").write_text("old error")
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    await client.post(
        "/submit",
        data={"monero_wallet": "4" + "A" * 94, "tari_wallet": "t", "pool": "mini"},
    )
    assert not (spool / "error.txt").exists()


def test_main_requires_token(monkeypatch, capsys):
    monkeypatch.delenv("WIZARD_TOKEN", raising=False)
    with pytest.raises(SystemExit) as e:
        wizard.main()
    assert e.value.code == 2
