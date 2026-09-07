"""Legacy-config and failed-install recovery at the wizard server boundary."""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import wizard
from mining_dashboard.wizard_config import prepare_config

REFERENCE = {
    "monero": {"wallet_address": "", "mode": "local"},
    "tari": {"wallet_address": "", "mode": "local"},
    "xvb": {"enabled": True, "url": "", "donor_id": ""},
    "dashboard": {"auth": {"password": ""}},
    "workers": {"list": []},
}


@pytest.fixture
def spool(tmp_path, monkeypatch):
    path = tmp_path / "spool"
    path.mkdir()
    path.joinpath("config.reference.json").write_text(json.dumps(REFERENCE))
    path.joinpath("disks.tsv").write_text("sda\t1T\tFixture disk\tSAFE123\tpithead-with-data\n")
    monkeypatch.setenv("WIZARD_SPOOL", str(path))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-RECOV1")
    return path


@pytest.fixture
async def client(spool):
    value = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await value.start_server()
    yield value
    await value.close()


async def _auth(client):
    response = await client.post("/auth", data={"token": "pit-RECOV1"}, allow_redirects=False)
    assert response.status == 302


async def _state(client):
    return await (await client.get("/api/wizard-state")).json()


def test_prepare_config_moves_both_removed_1x_shapes_before_schema_filtering():
    old_workers = [{"name": "shed", "host": "rig.local", "token": "fixture-token"}]
    prepared, changes = prepare_config(
        {
            "xmrig_proxy": {"enabled": False, "url": "http://xvb.invalid"},
            "dashboard": {"workers": old_workers},
        },
        REFERENCE,
    )
    assert prepared["xvb"] == {"enabled": False, "url": "http://xvb.invalid"}
    assert prepared["workers"]["list"] == old_workers
    assert "xmrig_proxy" not in prepared
    assert "workers" not in prepared["dashboard"]
    assert changes == [
        "xmrig_proxy.enabled → xvb.enabled",
        "xmrig_proxy.url → xvb.url",
        "dashboard.workers → workers.list",
    ]


def test_populated_legacy_workers_replace_an_empty_canonical_default_and_drop_unknown_fields():
    prepared, changes = prepare_config(
        {
            "dashboard": {
                "workers": [{"name": "shed", "host": "rig.local", "api_token": "drop-me"}]
            },
            "workers": {"list": []},
        },
        REFERENCE,
    )
    assert prepared["workers"]["list"] == [{"name": "shed", "host": "rig.local"}]
    assert changes == [
        "dashboard.workers → workers.list",
        "workers.list[].api_token removed",
    ]


@pytest.mark.parametrize("malformed", [{}, 0])
def test_malformed_legacy_workers_reach_the_host_type_guard(malformed):
    prepared, _changes = prepare_config(
        {"dashboard": {"workers": malformed}, "workers": {"list": []}}, REFERENCE
    )
    assert prepared["workers"]["list"] == malformed


def test_malformed_canonical_workers_conflict_with_populated_legacy_workers():
    with pytest.raises(ValueError, match="workers.list and dashboard.workers"):
        prepare_config(
            {"dashboard": {"workers": [{"name": "shed"}]}, "workers": {"list": 0}},
            REFERENCE,
            reject_legacy_conflicts=True,
        )


@pytest.mark.parametrize("malformed", [[], 0, "bad"])
def test_malformed_xmrig_proxy_reaches_the_host_under_its_canonical_name(malformed):
    prepared, changes = prepare_config({"xmrig_proxy": malformed}, REFERENCE)
    assert prepared == {"xvb": malformed}
    assert changes == ["xmrig_proxy → xvb"]


def test_malformed_xmrig_proxy_conflicts_with_a_different_canonical_value():
    with pytest.raises(ValueError, match="xvb and xmrig_proxy"):
        prepare_config(
            {"xmrig_proxy": 0, "xvb": {"enabled": True}},
            REFERENCE,
            reject_legacy_conflicts=True,
        )


def test_current_names_win_and_unknown_names_are_removed_without_values_in_the_summary():
    prepared, changes = prepare_config(
        {
            "xvb": {"enabled": True},
            "xmrig_proxy": {"enabled": False},
            "monero": {"wallet_address": "4SECRET", "invented": "credential-value"},
            "unknown": {"password": "do-not-render"},
        },
        REFERENCE,
    )
    assert prepared == {"xvb": {"enabled": True}, "monero": {"wallet_address": "4SECRET"}}
    assert changes == [
        "xmrig_proxy.enabled removed",
        "monero.invented removed",
        "unknown removed",
    ]
    assert not any(value in " ".join(changes) for value in ("credential-value", "do-not-render"))


def test_submission_refuses_conflicting_legacy_and_current_names():
    with pytest.raises(ValueError, match="xvb.enabled and xmrig_proxy.enabled"):
        prepare_config(
            {"xvb": {"enabled": True}, "xmrig_proxy": {"enabled": False}},
            REFERENCE,
            reject_legacy_conflicts=True,
        )


async def test_legacy_reinstall_prefill_is_migrated_before_defaults_are_merged(client, spool):
    spool.joinpath("last-attempt.json").write_text(
        json.dumps(
            {
                "xmrig_proxy": {"enabled": False},
                "monero": {"wallet_address": "4PREVIOUS"},
                "unknown_1x_key": True,
            }
        )
    )
    await _auth(client)
    state = await _state(client)
    assert state["stage"] == "installer"
    assert state["config"]["xvb"]["enabled"] is False
    assert state["config"]["monero"]["wallet_address"] == "4PREVIOUS"
    assert "xmrig_proxy" not in state["config"]
    assert "unknown_1x_key" not in state["config"]
    assert state["config_changes"] == [
        "xmrig_proxy.enabled → xvb.enabled",
        "unknown_1x_key removed",
    ]


async def test_submit_spools_only_known_names_and_keeps_known_credentials(client, spool):
    await _auth(client)
    submitted = {
        "monero": {"wallet_address": "4PAYOUT", "removed_password": "do-not-keep"},
        "dashboard": {"auth": {"password": "fixture-login-password"}},
        "xmrig_proxy": {"enabled": False},
    }
    response = await client.post(
        "/submit",
        data={
            "config": json.dumps(submitted),
            "auth_mode": "set",
            "disk": "sda",
            "confirm": "sda",
            "wipe": "data",
        },
    )
    assert response.status == 200
    attempt = json.loads(spool.joinpath("last-attempt.json").read_text())
    written = json.loads(spool.joinpath("config.json").read_text())
    assert attempt["monero"] == {"wallet_address": "4PAYOUT"}
    assert attempt["dashboard"]["auth"]["password"] == "fixture-login-password"
    assert attempt["xvb"]["enabled"] is False
    assert "xmrig_proxy" not in attempt
    assert written == attempt
    summary = json.loads(spool.joinpath("config-changes.json").read_text())["changes"]
    assert summary == [
        "xmrig_proxy.enabled → xvb.enabled",
        "monero.removed_password removed",
    ]
    assert "fixture-login-password" not in " ".join(summary)
    for name in ("last-attempt.json", "config-changes.json", "install-attempt.json"):
        assert spool.joinpath(name).stat().st_mode & 0o777 == 0o600


async def test_submit_does_not_hide_a_legacy_conflict_from_host_validation(client, spool):
    await _auth(client)
    response = await client.post(
        "/submit",
        data={"config": json.dumps({"xvb": {"enabled": True}, "xmrig_proxy": {"enabled": False}})},
    )
    assert response.status == 400
    assert "xvb.enabled and xmrig_proxy.enabled" in (await response.json())["error"]
    assert not spool.joinpath("config.json").exists()


async def test_failed_install_refresh_and_return_keep_safe_editable_fields(client, spool):
    await _auth(client)
    submitted = {
        "monero": {"wallet_address": "4PAYOUT"},
        "dashboard": {"auth": {"password": "fixture-login-password"}},
    }
    await client.post(
        "/submit",
        data={
            "config": json.dumps(submitted),
            "auth_mode": "set",
            "disk": "sda",
            "confirm": "sda",
            "wipe": "data",
        },
    )
    # The host owns these writes. An error is terminal even if its old progress marker survives.
    spool.joinpath("installing").write_text("1")
    spool.joinpath("error.txt").write_text("remote Tari node did not answer")
    failed = await _state(client)
    assert failed["stage"] == "failed"
    assert failed["error"] == "remote Tari node did not answer"
    assert failed["config"]["monero"]["wallet_address"] == "4PAYOUT"
    assert failed["config"]["dashboard"]["auth"]["password"] == "fixture-login-password"
    assert failed["install_attempt"] == {"disk": "sda", "wipe": "data"}
    assert failed["auth_mode"] == "set"
    assert "confirm" not in failed["install_attempt"]

    response = await client.post("/retry")
    assert response.status == 200
    reopened = await _state(client)
    assert reopened["stage"] == "installer"
    assert reopened["error"] is None
    assert reopened["config"]["monero"]["wallet_address"] == "4PAYOUT"
    assert not spool.joinpath("installing").exists()


async def test_prefill_migration_notice_survives_submit_and_host_failure(client, spool):
    spool.joinpath("last-attempt.json").write_text(
        json.dumps({"xmrig_proxy": {"enabled": False}, "monero": {"wallet_address": "4OLD"}})
    )
    await _auth(client)
    prefill = await _state(client)
    response = await client.post(
        "/submit",
        data={
            "config": json.dumps(prefill["config"]),
            "disk": "sda",
            "confirm": "sda",
            "wipe": "data",
        },
    )
    assert response.status == 200
    spool.joinpath("error.txt").write_text("node unavailable")
    failed = await _state(client)
    assert failed["stage"] == "failed"
    assert failed["config"]["monero"]["wallet_address"] == "4OLD"
    assert failed["config"]["xvb"]["enabled"] is False
    assert failed["config_changes"] == ["xmrig_proxy.enabled → xvb.enabled"]


async def test_retry_is_authenticated_and_only_opens_a_real_failure(client, spool):
    unauth = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await unauth.start_server()
    try:
        assert (await unauth.post("/retry", allow_redirects=False)).status == 302
    finally:
        await unauth.close()
    await _auth(client)
    assert (await client.post("/retry")).status == 409
    assert not spool.joinpath("error.txt").exists()


async def test_valid_install_marker_still_reports_installing(client, spool):
    spool.joinpath("installing").write_text("1")
    await _auth(client)
    assert (await _state(client))["stage"] == "installing"
