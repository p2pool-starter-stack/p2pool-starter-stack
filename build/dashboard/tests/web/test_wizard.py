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


# --- the destructive install path (combined submit: config + disk + wipe on one page) -------

_CFG = '{"monero": {"wallet_address": "4' + "A" * 94 + '"}, "tari": {"wallet_address": "t"}}'


async def _submit_install(client, disk="nvme0n1", confirm=None, wipe=None):
    data = {"config": _CFG, "disk": disk, "confirm": confirm if confirm is not None else disk}
    if wipe is not None:
        data["wipe"] = wipe
    return await client.post("/submit", data=data)


async def test_target_must_be_one_the_host_offered(client, installer):
    await _auth(client)
    r = await _submit_install(client, disk="sdz")
    assert r.status == 400
    assert not (installer / "install-request").exists()
    # A rejected disk must not half-accept the config either — one page, one atomic answer.
    assert not (installer / "config.json.candidate").exists()


async def test_confirmation_must_match_the_chosen_disk(client, installer):
    await _auth(client)
    r = await _submit_install(client, confirm="nvme0n")
    assert r.status == 400
    assert not (installer / "install-request").exists()


async def test_unauthed_install_writes_nothing(client, installer):
    r = await client.post(
        "/submit",
        data={"config": _CFG, "disk": "nvme0n1", "confirm": "nvme0n1"},
        allow_redirects=False,
    )
    assert r.status == 302
    assert not (installer / "install-request").exists()


async def test_valid_request_is_written_and_carries_the_wipe_mode(client, installer):
    # sda is the fixture's disk with a previous install — the only kind where wipe means anything.
    await _auth(client)
    r = await _submit_install(client, disk="sda", wipe="data")
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tdata"


async def test_wipe_mode_defaults_to_keep_and_rejects_inventions(client, installer):
    await _auth(client)
    assert (await _submit_install(client, disk="sda")).status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    r = await _submit_install(client, disk="sda", wipe="everything")
    assert r.status == 400


async def test_keep_everything_submits_no_config_and_gets_no_handoff_machinery(client, installer):
    # The preserved config wins: a keep reinstall must write ONLY the install request. A config
    # candidate here would regenerate the dashboard password and show a card the machine never
    # serves — the exact bench-reported bug.
    await _auth(client)
    r = await client.post("/submit", data={"disk": "sda", "confirm": "sda", "wipe": "keep"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    assert not (installer / "config.json").exists()
    assert not (installer / "last-attempt.json").exists()


async def test_installer_state_serves_a_published_prefill(client, seeded, installer):
    # A reinstall's pre-fill: the HOST mounts the target's previous /data read-only, strips
    # the secrets and publishes the remainder as last-attempt.json — the state API is the only
    # channel to the page, and it must merge that pre-fill over the defaults exactly as the
    # pre-seed path's does.
    installer.joinpath("last-attempt.json").write_text(
        json.dumps({"monero": {"wallet_address": "4PREV"}, "tari": {"mode": "remote"}})
    )
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["stage"] == "installer"
    assert s["config"]["monero"]["wallet_address"] == "4PREV"
    assert s["config"]["tari"]["mode"] == "remote"
    assert s["config"]["monero"]["prune"] is True  # the defaults still fill the gaps


async def test_a_broken_prefill_degrades_to_defaults_not_an_error(client, seeded, installer):
    # The pre-fill is pure convenience: an unparseable file means the form opens on the
    # documented defaults, with no error shown and nothing blocked.
    installer.joinpath("last-attempt.json").write_text("{not json")
    await _auth(client)
    r = await client.get("/api/wizard-state")
    assert r.status == 200
    s = await r.json()
    assert s["config"]["monero"]["wallet_address"] == ""
    assert s["error"] is None


async def test_keep_submit_leaves_a_published_prefill_alone(client, installer):
    # keep collapses the form and no config crosses. The pre-fill exists for the fresh/data
    # paths where the operator re-answers; an untouched keep must neither consume it nor
    # write anything beside the install request.
    installer.joinpath("last-attempt.json").write_text('{"monero": {"wallet_address": "4PREV"}}')
    await _auth(client)
    r = await client.post("/submit", data={"disk": "sda", "confirm": "sda", "wipe": "keep"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    assert not (installer / "config.json").exists()
    assert json.loads((installer / "last-attempt.json").read_text()) == {
        "monero": {"wallet_address": "4PREV"}
    }


async def test_keep_with_a_crafted_config_still_takes_the_keep_branch(client, installer):
    await _auth(client)
    r = await client.post(
        "/submit", data={"config": _CFG, "disk": "sda", "confirm": "sda", "wipe": "keep"}
    )
    assert r.status == 200
    assert not (installer / "config.json").exists()


async def test_fresh_disk_with_default_wipe_keep_is_a_normal_install(client, installer):
    # The client sends wipe=keep (its default) on EVERY submit; a blank disk must still take
    # the full config path — the gate caught this 400ing every fresh install.
    await _auth(client)
    r = await _submit_install(client, disk="nvme0n1", wipe="keep")
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert (installer / "config.json").exists()


async def test_keep_on_a_blank_disk_falls_through_to_a_normal_install(client, installer):
    # The page never offers keep on a blank disk; a bare submit there is treated as a fresh
    # install whose (empty) config the HOST rejects with a named reason — the server does not
    # guess intent. The no-JS form path made an early 400 impossible to distinguish from a
    # legitimate field submit; the gate caught exactly that as a broken fresh install.
    await _auth(client)
    r = await client.post("/submit", data={"disk": "nvme0n1", "confirm": "nvme0n1", "wipe": "keep"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert (installer / "config.json").exists()


async def test_wipe_is_normalized_to_keep_on_a_disk_with_nothing_to_wipe(client, installer):
    # nvme0n1 is empty in the fixture: "wipe" is meaningless there, and the page never offers
    # it — a crafted request is normalized rather than trusted.
    await _auth(client)
    r = await _submit_install(client, disk="nvme0n1", wipe="all")
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"


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


# --- the credentials handoff ----------------------------------------------------------------
# Generated on the machine, shown exactly once on the page over the same TLS the operator typed
# secrets into, held until they confirm it is saved — the page goes dark during provisioning.


async def test_handoff_requires_auth(client, spool):
    spool.joinpath("handoff.json").write_text('{"username":"admin"}')
    assert (await client.get("/api/handoff")).status == 401


async def test_handoff_404s_until_the_host_publishes_it(client, spool):
    await _auth(client)
    assert (await client.get("/api/handoff")).status == 404


async def test_handoff_serves_what_the_host_published(client, spool):
    spool.joinpath("handoff.json").write_text(
        json.dumps(
            {"username": "admin", "password": "x" * 32, "dashboard": "https://pithead.local"}
        )
    )
    await _auth(client)
    h = await (await client.get("/api/handoff")).json()
    assert h["username"] == "admin" and len(h["password"]) == 32


async def test_ack_needs_auth_and_a_published_handoff(client, spool):
    r = await client.post("/handoff-ack", allow_redirects=False)
    assert r.status == 302
    await _auth(client)
    assert (await client.post("/handoff-ack")).status == 400  # nothing published yet
    assert not (spool / "handoff-ack").exists()
    spool.joinpath("handoff.json").write_text("{}")
    assert (await client.post("/handoff-ack")).status == 200
    assert (spool / "handoff-ack").read_text() == "1"


# --- the server owns the stage --------------------------------------------------------------
# A refresh must never walk backwards into an editable form after a config was accepted, and the
# client must not infer the step: a bench session refreshed mid-provision and was handed the
# setup form again.


async def test_stage_is_setup_before_anything_is_submitted(client, seeded):
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "setup"


async def test_stage_becomes_handoff_when_credentials_are_published(client, seeded):
    seeded.joinpath("applied").write_text("1")
    seeded.joinpath("handoff.json").write_text(json.dumps({"username": "admin", "password": "p"}))
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["stage"] == "handoff"
    # The card's contents ride the SAME payload the page already polls — no second fetch to race.
    assert s["handoff"]["username"] == "admin"


async def test_stage_becomes_done_after_the_ack(client, seeded):
    seeded.joinpath("handoff.json").write_text("{}")
    seeded.joinpath("handoff-ack").write_text("1")
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["stage"] == "done"
    assert s["handoff"] is None  # nothing left to save


async def test_stage_is_done_while_provisioning_so_a_refresh_cannot_re_edit(client, seeded):
    seeded.joinpath("applied").write_text("1")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "done"


async def test_stage_reports_installing_once_the_install_starts(client, installer):
    # The HOST writes this marker when it begins the erase (after the credentials ack) —
    # a pending install-request alone is still editable and must stay on the form.
    installer.joinpath("installing").write_text("1")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "installing"


async def test_stage_stays_on_the_combined_form_while_a_request_is_pending(client, installer):
    installer.joinpath("install-request").write_text("sda\tkeep")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "installer"


async def test_ack_on_the_installer_means_installing_not_provisioning(client, installer):
    # Same ack, two meanings: on an installed machine it releases provisioning ("done"), on the
    # installation medium it releases the erase — the page must show the switch-off steps.
    installer.joinpath("handoff-ack").write_text("1")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "installing"


# --- the role select (#797 R3): the RigForge role travels on its own channel -----------------
# Pithead is the default and the absence of a role field — every submit above this section IS
# the regression bar for it. The rig role never touches config.json: three answers on their own
# spool file, the HOST validates reachability and owns everything after.


async def test_rig_submit_writes_the_request_and_role_and_no_config(client, seeded):
    await _auth(client)
    r = await client.post(
        "/submit",
        data={
            "role": "rig",
            "rig_pool": "pithead.local:3333",
            "rig_worker": "shed-3",
            "rig_password": "fixture-stratum-pw",
        },
    )
    assert r.status == 200
    req = json.loads((seeded / "rig-request.json").read_text())
    assert req == {
        "pool": "pithead.local:3333",
        "worker": "shed-3",
        "stratum_password": "fixture-stratum-pw",
    }
    assert (seeded / "role").read_text() == "rig"
    # None of the coordinator machinery: no config candidate, no retry attempt.
    assert not (seeded / "config.json").exists()
    assert not (seeded / "last-attempt.json").exists()


async def test_rig_pool_must_look_like_host_port(client, seeded):
    await _auth(client)
    for bad in ("", "pithead.local", "pithead.local:", ":3333", "pithead.local:zzz"):
        r = await client.post("/submit", data={"role": "rig", "rig_pool": bad})
        assert r.status == 400, bad
        assert "host:port" in (await r.json())["error"]
    assert not (seeded / "rig-request.json").exists()


async def test_rig_empty_worker_and_password_are_omitted(client, seeded):
    # The HOST fills the worker default (its own hostname); an empty password is no password.
    await _auth(client)
    await client.post("/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333"})
    assert json.loads((seeded / "rig-request.json").read_text()) == {"pool": "10.0.0.5:3333"}


async def test_rig_on_the_installer_takes_the_same_disk_gates(client, installer):
    # Identical erase discipline in every role: offered target, exact retype, fixed wipe set.
    await _auth(client)
    base = {"role": "rig", "rig_pool": "10.0.0.5:3333"}
    assert (
        await client.post("/submit", data={**base, "disk": "sdz", "confirm": "sdz"})
    ).status == 400
    r = await client.post("/submit", data={**base, "disk": "nvme0n1", "confirm": "nvme0n"})
    assert r.status == 400
    # A rejected disk half-accepts nothing — one page, one atomic answer.
    assert not (installer / "install-request").exists()
    assert not (installer / "rig-request.json").exists()
    r = await client.post("/submit", data={**base, "disk": "nvme0n1", "confirm": "nvme0n1"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert (installer / "rig-request.json").exists()


async def test_run_from_this_stick_is_first_class_for_the_rig_role_only(client, installer):
    # "usb" is not a disk: nothing is erased, so NO install request — the answers still travel.
    await _auth(client)
    r = await client.post(
        "/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333", "disk": "usb"}
    )
    assert r.status == 200
    assert not (installer / "install-request").exists()
    assert (installer / "rig-request.json").exists()
    # Any other role naming "usb" hits the inventory gate: the host never offered it.
    r = await client.post("/submit", data={"config": _CFG, "disk": "usb", "confirm": "usb"})
    assert r.status == 400


async def test_rig_keep_on_a_preserved_disk_stays_a_keep(client, installer):
    # keep means KEEP in every role: the survivor config wins, no role change crosses.
    await _auth(client)
    r = await client.post(
        "/submit",
        data={
            "role": "rig",
            "rig_pool": "10.0.0.5:3333",
            "disk": "sda",
            "confirm": "sda",
            "wipe": "keep",
        },
    )
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    assert not (installer / "rig-request.json").exists()
    assert not (installer / "role").exists()


async def test_state_carries_the_hosts_rig_defaults_and_fails_open(client, seeded):
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["rig_defaults"] == {}  # nothing published — the fields open empty
    seeded.joinpath("rig-defaults.json").write_text(
        '{"pool": "pithead.local:3333", "worker": "hp"}'
    )
    s = await (await client.get("/api/wizard-state")).json()
    assert s["rig_defaults"] == {"pool": "pithead.local:3333", "worker": "hp"}
    seeded.joinpath("rig-defaults.json").write_text("{broken")
    s = await (await client.get("/api/wizard-state")).json()
    assert s["rig_defaults"] == {}


async def test_status_narrates_the_rig_save_without_promising_a_dashboard(client, spool):
    spool.joinpath("role").write_text("rig")
    spool.joinpath("applied").write_text("1")
    body = await (await client.get("/status")).text()
    assert "Rig settings saved" in body
    assert "dashboard" not in body.lower()


async def test_rig_submit_clears_a_previous_error(client, seeded):
    seeded.joinpath("error.txt").write_text("old error")
    await _auth(client)
    await client.post("/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333"})
    assert not (seeded / "error.txt").exists()


async def test_unauthed_rig_submit_writes_nothing(client, seeded):
    r = await client.post(
        "/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333"}, allow_redirects=False
    )
    assert r.status == 302
    assert not (seeded / "rig-request.json").exists()


# --- the dashboard-login choice -------------------------------------------------------------


async def test_auth_mode_rides_beside_the_config(client, seeded):
    # "no login" is an empty password, which is also what "not chosen" looks like — the choice
    # cannot be encoded in the config without colliding with a real one.
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg), "auth_mode": "none"})
    assert (seeded / "auth-mode").read_text() == "none"


async def test_an_unknown_auth_mode_is_ignored(client, seeded):
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg), "auth_mode": "whatever"})
    assert not (seeded / "auth-mode").exists()
