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
            "monero_remote_host": "192.168.1.10",
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
    # last-attempt.json is deliberate — it is what refills the form after a rejection. What
    # must not survive is a half-written temp file beside the atomic rename target.
    assert sorted(p.name for p in spool.iterdir()) == ["config.json", "last-attempt.json"]
    assert not [p for p in spool.iterdir() if p.name.startswith(".")]


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


# --- installer mode -------------------------------------------------------------------------
# The host writes disks.tsv when it booted from removable media. Everything here guards a step
# that ERASES a disk, so the tests are about what the page refuses, not what it accepts.

DISKS = (
    "nvme0n1\t931.5G\tSamsung SSD 990\tS6P1NF0T\tempty\n"
    "sda\t3.6T\tWDC WD40EFRX\tWD-WCC7K3\tpithead-with-data\n"
)


@pytest.fixture
def installer(spool):
    (spool / "disks.tsv").write_text(DISKS)
    return spool


async def test_authed_lands_on_installer_when_host_offers_disks(client, installer):
    r = await client.post("/auth", data={"token": "pit-X7KM2Q"}, allow_redirects=False)
    assert r.headers["Location"] == "/install"


async def test_setup_form_is_the_landing_page_without_installer_mode(client, spool):
    r = await client.post("/auth", data={"token": "pit-X7KM2Q"}, allow_redirects=False)
    assert r.headers["Location"] == "/setup"


async def test_picker_shows_model_size_serial_and_never_preselects(client, installer):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    body = await (await client.get("/install")).text()
    for expected in ("nvme0n1", "931.5G", "Samsung SSD 990", "S6P1NF0T", "3.6T"):
        assert expected in body
    # A disk must never be the default choice — the first click has to be deliberate.
    assert 'value="" selected disabled' in body
    # Reinstall-vs-erase has to be visible before choosing, not after.
    assert "KEEPS existing data" in body
    assert "ERASES everything on it" in body


async def test_target_must_be_one_the_host_offered(client, installer):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/install", data={"disk": "sdz", "confirm": "sdz"})
    assert r.status == 400
    assert not (installer / "install-target").exists()


async def test_confirmation_must_match_the_chosen_disk(client, installer):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/install", data={"disk": "nvme0n1", "confirm": "nvme0n"})
    assert r.status == 400
    assert not (installer / "install-target").exists()


async def test_unauthed_install_post_writes_nothing(client, installer):
    r = await client.post(
        "/install", data={"disk": "nvme0n1", "confirm": "nvme0n1"}, allow_redirects=False
    )
    assert r.status == 302
    assert not (installer / "install-target").exists()


async def test_valid_request_is_written_for_the_host(client, installer):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/install", data={"disk": "nvme0n1", "confirm": "nvme0n1"})
    assert r.status == 200
    assert (installer / "install-target").read_text() == "nvme0n1"


async def test_installer_status_is_distinct_from_provisioning(client, installer):
    assert "Copying the system" in await (await client.get("/status")).text()
    (installer / "installed").write_text("1")
    body = await (await client.get("/status")).text()
    # Starts with "Installed" — the page's poll keys on that to reveal the shutdown notice.
    assert body.startswith("Installed")
    assert "switching itself off" in body


# --- the expanded question set --------------------------------------------------------------
# build_config SHAPES answers; the host's parse_and_validate_config decides. These assert the
# shape, and especially that unanswered questions are omitted rather than written empty — an
# empty string is a value and would override the documented default.


def _cfg(**over):
    form = {"monero_wallet": "4" + "A" * 94, "pool": "mini"}
    form.update(over)
    return wizard.build_config(form)


def test_both_wallets_always_flow_to_the_host_validator():
    # tari.mode is local|remote only — there is no Monero-only mode, and the wizard must not
    # invent one. An empty address passes through so the HOST produces the rejection.
    cfg = _cfg(tari_wallet="")
    assert cfg["tari"]["wallet_address"] == ""
    assert "tari_required" not in cfg.get("dashboard", {})


def test_remote_monero_carries_ports_and_defaults_them():
    cfg = _cfg(monero_mode="remote", monero_remote_host="10.0.0.5", monero_remote_rpc="1234")
    assert cfg["monero"]["remote"] == {"host": "10.0.0.5", "rpc_port": 1234, "zmq_port": 18083}


def test_non_numeric_ports_fall_back_rather_than_crash():
    cfg = _cfg(monero_mode="remote", monero_remote_host="h", monero_remote_rpc="not-a-port")
    assert cfg["monero"]["remote"]["rpc_port"] == 18081


def test_remote_auth_only_written_when_asked_for():
    plain = _cfg(monero_mode="remote", monero_remote_host="h")
    assert "node_username" not in plain["monero"]
    authed = _cfg(
        monero_mode="remote",
        monero_remote_host="h",
        monero_remote_auth="1",
        monero_remote_user="u",
        monero_remote_pass="p",
    )
    assert authed["monero"]["node_username"] == "u"


def test_remote_tari_is_independent_of_monero():
    cfg = _cfg(tari_wallet="t", tari_mode="remote", tari_remote_host="10.0.0.9")
    assert cfg["tari"]["remote"] == {"host": "10.0.0.9", "grpc_port": 18142}
    assert cfg["monero"].get("mode") != "remote"


def test_local_miner_and_timezone_are_omitted_unless_chosen():
    default = _cfg(tari_wallet="t")
    assert "local_miner" not in default
    assert "timezone" not in default.get("dashboard", {})
    chosen = _cfg(tari_wallet="t", local_miner="1", timezone="Europe/Berlin")
    assert chosen["local_miner"]["enabled"] is True
    assert chosen["dashboard"]["timezone"] == "Europe/Berlin"


def test_clearnet_sync_applies_to_both_chains():
    cfg = _cfg(tari_wallet="t", clearnet_sync="true")
    assert cfg["monero"]["clearnet_initial_sync"] is True
    assert cfg["tari"]["clearnet_initial_sync"] is True


async def test_address_guidance_is_on_the_page(client, spool):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    body = await (await client.get("/setup")).text()
    # A pasted subaddress is the most common way to misconfigure this, so the page must say so
    # before the operator submits, not after.
    assert "subaddress" in body
    assert "Paste these" in body


# --- transcription forgiveness --------------------------------------------------------------
# The operator copies the token from a console, often on a phone that autocapitalizes. Case and
# the pit- prefix carry no entropy; neither may fail a correct transcription.


@pytest.mark.parametrize(
    "typed",
    ["pit-X7KM2Q", "PIT-X7KM2Q", "pit-x7km2q", "X7KM2Q", "x7km2q", "  pit-X7KM2Q  "],
)
async def test_token_transcription_variants_all_pass(client, typed):
    r = await client.post("/auth", data={"token": typed}, allow_redirects=False)
    assert r.status == 302


async def test_wrong_token_still_fails(client):
    r = await client.post("/auth", data={"token": "pit-WRONGX"})
    assert r.status == 403


# --- host-provided strings are data, not markup ---------------------------------------------


async def test_disk_fields_are_html_escaped(client, spool):
    (spool / "disks.tsv").write_text("sda\t1T\tACME <Turbo> & Co\tSN&1\tempty\n")
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    body = await (await client.get("/install")).text()
    assert "ACME &lt;Turbo&gt; &amp; Co" in body
    assert "<Turbo>" not in body


async def test_new_install_attempt_clears_stale_error(client, installer):
    (installer / "error.txt").write_text("previous failure")
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/install", data={"disk": "nvme0n1", "confirm": "nvme0n1"})
    assert r.status == 200
    assert not (installer / "error.txt").exists()


# --- mode isolation and cookie scope --------------------------------------------------------


async def test_setup_form_redirects_to_install_in_installer_mode(client, installer):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.get("/setup", allow_redirects=False)
    assert r.status == 302
    assert r.headers["Location"] == "/install"


async def test_install_form_redirects_to_setup_without_installer_mode(client, spool):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.get("/install", allow_redirects=False)
    assert r.status == 302
    assert r.headers["Location"] == "/setup"


async def test_session_cookie_is_samesite_strict(client):
    # /install erases a disk; the cookie that authorizes it must never ride a cross-site request.
    r = await client.post("/auth", data={"token": "pit-X7KM2Q"}, allow_redirects=False)
    assert "SameSite=Strict" in r.headers.get("Set-Cookie", "")


def test_prune_defaults_to_pruned_and_only_full_is_written():
    # prune is TRUE in the reference, so the common answer must emit nothing; a disk that cannot
    # hold 320 GB is the normal appliance case, and silence keeps the documented default.
    assert "prune" not in _cfg(tari_wallet="t")["monero"]
    assert "prune" not in _cfg(tari_wallet="t", prune="true")["monero"]
    assert _cfg(tari_wallet="t", prune="false")["monero"]["prune"] is False


async def test_picker_puts_the_consequence_before_the_truncation_point(client, installer):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    body = await (await client.get("/install")).text()
    # A <select> truncates on the right. The erase/keep verdict must sit right after the disk
    # name — bench testing cut off exactly these words in the collapsed control.
    assert "nvme0n1 — ERASES everything on it" in body
    assert "sda — KEEPS existing data" in body
    # And it must be restated where nothing truncates.
    assert 'id="verdict"' in body


# --- the post-install shutdown ----------------------------------------------------------
# There is deliberately no button. An operator who pulls the stick before pressing anything
# takes the running filesystem — and the control — with it; a bench session hit that twice.


async def test_install_page_has_no_button_to_sequence_wrongly(client, installer):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/install", data={"disk": "nvme0n1", "confirm": "nvme0n1"})
    body = await r.text()
    assert "/reboot" not in body
    # The procedure, in order, and nothing else: switch off, remove, switch on.
    assert body.index("switch itself off") < body.index("Remove the USB stick")
    assert body.index("Remove the USB stick") < body.index("Switch it back on")


async def test_reboot_endpoint_is_gone(client, installer):
    (installer / "installed").write_text("1")
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/reboot")
    assert r.status == 404
    assert not (installer / "reboot-request").exists()


# --- the JSON pane is the configuration -----------------------------------------------------
# The fields write into it, so what the operator sees is exactly what gets applied.


@pytest.fixture
def seeded(spool):
    spool.joinpath("config.reference.json").write_text(
        json.dumps({
            "monero": {"wallet_address": "", "mode": "local", "prune": True},
            "tari": {"wallet_address": "", "mode": "local"},
            "p2pool": {"pool": "mini"},
            "tor": {"auto_heal": False},
        })
    )
    return spool


async def test_setup_page_embeds_the_effective_config(client, seeded):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    body = await (await client.get("/setup")).text()
    assert 'id="cfg-seed"' in body and 'id="cfg"' in body
    assert "data-path=" in body


async def test_submitted_json_is_what_gets_written(client, seeded):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    cfg = {"monero": {"wallet_address": "4XYZ", "prune": True}, "tari": {"wallet_address": "t"}}
    r = await client.post("/submit", data={"config": json.dumps(cfg)})
    assert r.status == 200
    written = json.loads((seeded / "config.json").read_text())
    assert written["monero"]["wallet_address"] == "4XYZ"


async def test_keys_at_their_default_are_not_written(client, seeded):
    # A config that pins every default would freeze them; the appliance receives improved
    # defaults through updates. Effective configuration is identical either way.
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    cfg = {"monero": {"wallet_address": "4XYZ", "prune": True, "mode": "local"},
           "tari": {"wallet_address": "t"}, "p2pool": {"pool": "mini"}, "tor": {"auto_heal": False}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    written = json.loads((seeded / "config.json").read_text())
    assert "prune" not in written["monero"]     # equals the default
    assert "mode" not in written["monero"]      # equals the default
    assert "p2pool" not in written               # entirely default
    assert written["monero"]["wallet_address"] == "4XYZ"  # differs, so it is kept


async def test_a_changed_default_is_written(client, seeded):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    cfg = {"monero": {"wallet_address": "4XYZ", "prune": False}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    assert json.loads((seeded / "config.json").read_text())["monero"]["prune"] is False


async def test_malformed_json_is_refused_and_comes_back(client, seeded):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/submit", data={"config": "{not json"})
    assert r.status == 400
    assert "Not valid JSON" in await r.text()
    assert not (seeded / "config.json").exists()


async def test_a_rejected_attempt_is_offered_back_for_editing(client, seeded):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    cfg = {"monero": {"wallet_address": "4TYPO"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    (seeded / "error.txt").write_text("bad wallet")
    body = await (await client.get("/setup")).text()
    assert "4TYPO" in body      # no retyping a 95-character address to fix one field
    assert "bad wallet" in body


async def test_a_browser_without_javascript_still_works(client, seeded):
    # The pane never populates without JS, so the plain form fields remain the fallback.
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    r = await client.post("/submit", data={"monero_wallet": "4" + "A" * 94, "tari_wallet": "t",
                                           "pool": "mini", "config": ""})
    assert r.status == 200
    assert json.loads((seeded / "config.json").read_text())["monero"]["wallet_address"].startswith("4")



# --- chain size belongs to a node we run ----------------------------------------------------


def test_prune_is_ignored_for_a_remote_node():
    # The chain lives on someone else's machine; claiming a shape for it is a lie in the config.
    cfg = _cfg(tari_wallet="t", monero_mode="remote", monero_remote_host="h", prune="false")
    assert "prune" not in cfg["monero"]


def test_prune_still_applies_to_a_local_node():
    assert _cfg(tari_wallet="t", prune="false")["monero"]["prune"] is False


async def test_chain_size_is_nested_under_the_local_node(client, spool):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    body = await (await client.get("/setup")).text()
    # It sits inside a collapsible block, like the remote-node fields, so it is only visible
    # once "run the bundled node" is the answer.
    assert 'class="when" id="mlocal"' in body
    assert body.index('id="mlocal"') < body.index('id="prune"')


# --- sidechains and optional alerts ---------------------------------------------------------


async def test_all_three_sidechains_are_offered(client, spool):
    await client.post("/auth", data={"token": "pit-X7KM2Q"})
    body = await (await client.get("/setup")).text()
    for tier in ("mini", "nano", "main"):
        assert f'value="{tier}"' in body


def test_sidechain_defaults_to_mini():
    assert _cfg(tari_wallet="t")["p2pool"]["pool"] == "mini"
    assert _cfg(tari_wallet="t", pool="nano")["p2pool"]["pool"] == "nano"


def test_alerts_are_omitted_unless_filled_in():
    cfg = _cfg(tari_wallet="t")
    assert "healthchecks" not in cfg and "telegram" not in cfg


def test_healthchecks_url_is_written_when_given():
    cfg = _cfg(tari_wallet="t", healthchecks_url="https://hc-ping.com/abc")
    assert cfg["healthchecks"]["ping_url"] == "https://hc-ping.com/abc"


def test_telegram_needs_both_halves_or_neither():
    # A token with no chat id cannot deliver anything, and writing enabled=true on a broken
    # pair would fail the host's validation on a blank the operator never meant to set.
    assert "telegram" not in _cfg(tari_wallet="t", telegram_token="123:ABC")
    assert "telegram" not in _cfg(tari_wallet="t", telegram_chat="999")
    both = _cfg(tari_wallet="t", telegram_token="123:ABC", telegram_chat="999")
    assert both["telegram"] == {"enabled": True, "bot_token": "123:ABC", "chat_id": "999"}
