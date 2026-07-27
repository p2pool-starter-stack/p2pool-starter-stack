"""Server contracts of the first-boot wizard (#77 phase 3).

The wizard is an SPA on the dashboard's frontend stack; the server renders no HTML. These
tests pin what the SERVER promises — the token gate, the state API, the spool writes the host
consumes, the guards on the destructive install path, and TLS selection. Everything the
operator SEES is preact components, whose pure logic is tested where the dashboard tests its
frontend: node --test over configsync.mjs.
"""

import json

import pytest
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer, make_mocked_request

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


@pytest.fixture
def seeded(spool):
    """A published reference, as the host provides on a real machine."""
    spool.joinpath("config.reference.json").write_text(
        json.dumps(
            {
                "monero": {"wallet_address": "", "mode": "local", "prune": True},
                "tari": {"wallet_address": "", "mode": "local"},
                "p2pool": {"pool": "mini"},
                "tor": {"auto_heal": False},
            }
        )
    )
    return spool


@pytest.fixture
def installer(spool):
    spool.joinpath("disks.tsv").write_text(
        "nvme0n1\t931.5G\tSamsung SSD 990\tS6P1NF0T\tempty\n"
        "sda\t3.6T\tWDC WD40EFRX\tWD-WCC7K3\tpithead-with-data\n"
    )
    return spool


async def _auth(client, token="pit-X7KM2Q"):  # noqa: S107 — the test fixture's token, not a secret
    return await client.post("/auth", data={"token": token}, allow_redirects=False)


# --- the shell ------------------------------------------------------------------------------


async def test_shell_serves_without_auth_and_identifies_itself(client):
    # The tier-4 harness (and any curl) recognizes the page without executing the module.
    body = await (await client.get("/")).text()
    assert "Pithead setup" in body
    assert "/static/wizard.mjs" in body
    assert "/static/dashboard.css" in body  # same skin as the dashboard


async def test_bookmarked_steps_serve_the_same_shell(client):
    for path in ("/setup", "/install"):
        body = await (await client.get(path)).text()
        assert "/static/wizard.mjs" in body


async def test_static_assets_serve_with_module_mime(client):
    r = await client.get("/static/configsync.mjs")
    assert r.status == 200
    assert "javascript" in r.headers["Content-Type"]


# --- the token gate -------------------------------------------------------------------------


@pytest.mark.parametrize(
    "typed",
    ["pit-X7KM2Q", "PIT-X7KM2Q", "pit-x7km2q", "X7KM2Q", "x7km2q", "  pit-X7KM2Q  "],
)
async def test_token_transcription_variants_all_pass(client, typed):
    # The operator copies from a console, often on a phone that autocapitalizes. Case and the
    # pit- prefix carry no entropy; neither may fail a correct transcription.
    r = await _auth(client, typed)
    assert r.status == 302
    assert "SameSite=Strict" in r.headers.get("Set-Cookie", "")


async def test_wrong_token_403(client):
    assert (await _auth(client, "pit-WRONGX")).status == 403


async def test_lockout_exits_3_after_max_failures(client):
    for _ in range(wizard.MAX_FAILURES):
        await _auth(client, "pit-WRONGX")
    assert client.server.app["exits"] == [wizard.EXIT_TOKEN_LOCKOUT]


def test_main_requires_token(monkeypatch):
    monkeypatch.delenv("WIZARD_TOKEN", raising=False)
    with pytest.raises(SystemExit) as e:
        wizard.main()
    assert e.value.code == 2


# --- the state API --------------------------------------------------------------------------


async def test_state_requires_auth(client):
    assert (await client.get("/api/wizard-state")).status == 401


async def test_state_carries_the_effective_config_and_mode(client, seeded):
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["mode"] == "setup"
    assert s["config"]["monero"]["prune"] is True  # defaults filled in
    assert s["reference"]["p2pool"]["pool"] == "mini"
    assert s["error"] is None


async def test_state_switches_to_installer_mode_and_parses_disks(client, installer):
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["mode"] == "installer"
    assert s["disks"][0] == {
        "name": "nvme0n1",
        "size": "931.5G",
        "model": "Samsung SSD 990",
        "serial": "S6P1NF0T",
        "state": "empty",
    }
    assert s["disks"][1]["state"] == "pithead-with-data"


async def test_disk_fields_with_markup_stay_data(client, spool):
    # The client renders objects via preact interpolation (auto-escaped); the server's job is
    # to keep hostile strings intact as DATA, not to sanitize them into something else.
    spool.joinpath("disks.tsv").write_text("sda\t1T\tACME <Turbo> & Co\tSN&1\tempty\n")
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["disks"][0]["model"] == "ACME <Turbo> & Co"


async def test_a_rejected_attempt_comes_back_in_the_state(client, seeded):
    # No retyping a 95-character address to fix one field: the last attempt merges over the
    # defaults, and the host's rejection reason rides beside it.
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4TYPO"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    seeded.joinpath("error.txt").write_text("bad wallet")
    s = await (await client.get("/api/wizard-state")).json()
    assert s["config"]["monero"]["wallet_address"] == "4TYPO"
    assert s["error"] == "bad wallet"


# --- submit: the JSON pane IS the configuration ---------------------------------------------


async def test_submitted_json_is_what_gets_written(client, seeded):
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    r = await client.post("/submit", data={"config": json.dumps(cfg)})
    assert r.status == 200
    written = json.loads((seeded / "config.json").read_text())
    assert written["monero"]["wallet_address"] == "4XYZ"
    # The full attempt is kept for retry; no half-written temp files beside the atomic targets.
    assert json.loads((seeded / "last-attempt.json").read_text()) == cfg
    assert not [p for p in seeded.iterdir() if p.name.startswith(".")]


async def test_keys_at_their_default_are_not_written(client, seeded):
    # A config that pins every default would freeze them; the appliance receives improved
    # defaults through OS updates. Effective configuration is identical either way.
    await _auth(client)
    cfg = {
        "monero": {"wallet_address": "4XYZ", "prune": True, "mode": "local"},
        "tari": {"wallet_address": "t"},
        "p2pool": {"pool": "mini"},
        "tor": {"auto_heal": False},
    }
    await client.post("/submit", data={"config": json.dumps(cfg)})
    written = json.loads((seeded / "config.json").read_text())
    assert "prune" not in written["monero"]
    assert "mode" not in written["monero"]
    assert "p2pool" not in written
    assert written["monero"]["wallet_address"] == "4XYZ"


async def test_a_changed_default_is_written(client, seeded):
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ", "prune": False}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    assert json.loads((seeded / "config.json").read_text())["monero"]["prune"] is False


async def test_malformed_json_is_refused_without_spooling(client, seeded):
    await _auth(client)
    r = await client.post("/submit", data={"config": "{not json"})
    assert r.status == 400
    assert "Not valid JSON" in (await r.json())["error"]
    assert not (seeded / "config.json").exists()


async def test_a_bare_json_array_is_refused(client, seeded):
    await _auth(client)
    assert (await client.post("/submit", data={"config": "[1,2,3]"})).status == 400
    assert not (seeded / "config.json").exists()


async def test_submit_unauthed_redirects_and_writes_nothing(client, seeded):
    r = await client.post("/submit", data={"config": "{}"}, allow_redirects=False)
    assert r.status == 302
    assert not (seeded / "config.json").exists()


async def test_submit_clears_a_previous_error(client, seeded):
    seeded.joinpath("error.txt").write_text("old error")
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    assert not (seeded / "error.txt").exists()


# --- submit: the no-JavaScript fallback (the harness's curl, a text browser) ----------------


async def test_form_fields_still_work_without_the_pane(client, seeded):
    await _auth(client)
    r = await client.post(
        "/submit",
        data={"monero_wallet": "4" + "A" * 94, "tari_wallet": "t", "pool": "mini", "config": ""},
    )
    assert r.status == 200
    cfg = json.loads((seeded / "config.json").read_text())
    assert cfg["monero"]["wallet_address"].startswith("4")


def test_both_wallets_always_flow_to_the_host_validator():
    # tari.mode is local|remote only — there is no Monero-only mode, and the wizard must not
    # invent one. An empty value still passes through so the HOST produces the rejection.
    cfg = wizard.build_config({"monero_wallet": "4" + "A" * 94, "tari_wallet": ""})
    assert cfg["tari"]["wallet_address"] == ""


def test_remote_monero_carries_ports_and_defaults_them():
    cfg = wizard.build_config(
        {
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "t",
            "monero_mode": "remote",
            "monero_remote_host": "10.0.0.5",
            "monero_remote_rpc": "1234",
        }
    )
    assert cfg["monero"]["remote"] == {"host": "10.0.0.5", "rpc_port": 1234, "zmq_port": 18083}


def test_non_numeric_ports_fall_back_rather_than_crash():
    cfg = wizard.build_config(
        {
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "t",
            "monero_mode": "remote",
            "monero_remote_host": "h",
            "monero_remote_rpc": "not-a-port",
        }
    )
    assert cfg["monero"]["remote"]["rpc_port"] == 18081


def test_prune_is_ignored_for_a_remote_node():
    # The chain lives on someone else's machine; claiming a shape for it is a lie.
    cfg = wizard.build_config(
        {
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "t",
            "monero_mode": "remote",
            "monero_remote_host": "h",
            "prune": "false",
        }
    )
    assert "prune" not in cfg["monero"]


def test_alerts_are_omitted_unless_filled_in():
    base = {"monero_wallet": "4" + "A" * 94, "tari_wallet": "t"}
    cfg = wizard.build_config(base)
    assert "healthchecks" not in cfg and "telegram" not in cfg
    # Telegram needs both halves or neither — a half pair cannot deliver anything.
    assert "telegram" not in wizard.build_config({**base, "telegram_token": "123:ABC"})
    both = wizard.build_config({**base, "telegram_token": "123:ABC", "telegram_chat": "999"})
    assert both["telegram"] == {"enabled": True, "bot_token": "123:ABC", "chat_id": "999"}


def test_timezone_auto_is_the_default_and_never_pinned():
    base = {"monero_wallet": "4" + "A" * 94, "tari_wallet": "t"}
    assert "dashboard" not in wizard.build_config({**base, "timezone": "auto"})
    berlin = wizard.build_config({**base, "timezone": "Europe/Berlin"})
    assert berlin["dashboard"]["timezone"] == "Europe/Berlin"


# --- the destructive install path -----------------------------------------------------------


async def test_target_must_be_one_the_host_offered(client, installer):
    await _auth(client)
    r = await client.post("/install", data={"disk": "sdz", "confirm": "sdz"})
    assert r.status == 400
    assert not (installer / "install-target").exists()


async def test_confirmation_must_match_the_chosen_disk(client, installer):
    await _auth(client)
    r = await client.post("/install", data={"disk": "nvme0n1", "confirm": "nvme0n"})
    assert r.status == 400
    assert not (installer / "install-target").exists()


async def test_unauthed_install_writes_nothing(client, installer):
    r = await client.post(
        "/install", data={"disk": "nvme0n1", "confirm": "nvme0n1"}, allow_redirects=False
    )
    assert r.status == 302
    assert not (installer / "install-target").exists()


async def test_valid_request_is_written_and_clears_stale_errors(client, installer):
    (installer / "error.txt").write_text("previous failure")
    await _auth(client)
    r = await client.post("/install", data={"disk": "nvme0n1", "confirm": "nvme0n1"})
    assert r.status == 200
    assert (installer / "install-target").read_text() == "nvme0n1"
    assert not (installer / "error.txt").exists()


# --- status: what the polling views read ----------------------------------------------------


async def test_status_narrates_setup(client, spool):
    assert "Waiting" in await (await client.get("/status")).text()
    spool.joinpath("error.txt").write_text("bad wallet")
    assert "Rejected: bad wallet" in await (await client.get("/status")).text()
    spool.joinpath("error.txt").unlink()
    spool.joinpath("applied").write_text("1")
    assert "Provisioned" in await (await client.get("/status")).text()


async def test_status_narrates_the_install_and_the_shutdown(client, installer):
    assert "Copying" in await (await client.get("/status")).text()
    (installer / "installed").write_text("1")
    body = await (await client.get("/status")).text()
    # The shutdown IS the completion, and the order must survive rewording: off, then stick.
    assert body.startswith("Installed")
    assert body.lower().index("go dark") < body.lower().index("remove the usb stick")


# --- TLS ------------------------------------------------------------------------------------


def test_plain_http_is_the_fallback_when_no_cert_is_supplied(monkeypatch):
    # A machine that could not mint a certificate must still serve a setup page, not nothing.
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    monkeypatch.delenv("WIZARD_TLS_CERT", raising=False)
    started = {}
    monkeypatch.setattr(wizard.web, "run_app", lambda app, **kw: started.update(kw))
    wizard.main()
    assert started["port"] == 8000


def test_tls_is_used_when_both_halves_exist(monkeypatch, tmp_path):
    cert, key = tmp_path / "c.pem", tmp_path / "k.pem"
    cert.write_text("x")
    key.write_text("y")
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    monkeypatch.setenv("WIZARD_TLS_CERT", str(cert))
    monkeypatch.setenv("WIZARD_TLS_KEY", str(key))
    seen = {}

    def fake_run(coro):
        coro.close()
        seen["ran"] = True

    monkeypatch.setattr(wizard.asyncio, "run", fake_run)
    monkeypatch.setattr(wizard.web, "run_app", lambda *a, **k: seen.setdefault("plain", True))
    wizard.main()
    assert seen.get("ran") and "plain" not in seen


def test_a_missing_key_falls_back_rather_than_crashing(monkeypatch, tmp_path):
    cert = tmp_path / "c.pem"
    cert.write_text("x")
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    monkeypatch.setenv("WIZARD_TLS_CERT", str(cert))
    monkeypatch.setenv("WIZARD_TLS_KEY", str(tmp_path / "absent.pem"))
    started = {}
    monkeypatch.setattr(wizard.web, "run_app", lambda app, **kw: started.update(kw))
    wizard.main()
    assert started["port"] == 8000


async def test_plain_port_redirects_to_tls_keeping_the_host_used():
    # Someone typing a bare address lands on :80; a dead port there reads as a broken machine.
    req = make_mocked_request("GET", "/setup", headers={"Host": "pithead.local"})
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard._redirect_to_tls(req)
    assert exc.value.location == "https://pithead.local/setup"
