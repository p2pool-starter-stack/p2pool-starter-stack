"""Click-to-adopt (#893) at the route level: ``handle_control_preview`` — the SAME endpoint every
other config edit uses, no new write route — pre-validates a proposal's newly-appended
``workers.list[]`` entries before it ever spools to the host-side runner.

This is the dashboard's own defense-in-depth mirror of pithead's ``control_approval_gate`` add-only
exception (the actual security authority, exercised at commit); these tests prove the mirror is
WIRED IN to the real request handler, not just correct in isolation (that's
``tests/service/test_worker_adopt.py``). Each rejection test would pass right through (200/202,
request spooled) if the guard call in ``handle_control_preview`` were removed or its condition
inverted — that is the mutation each one kills.
"""

import json

import pytest

from mining_dashboard.service import control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import create_app

CONTROL_HEADERS = {"X-Pithead-Control": "1"}


@pytest.fixture
def control_spool(tmp_path, monkeypatch):
    """Control channel on, one already-adopted rig live in config.json."""
    host_config = tmp_path / "config.json"
    host_config.write_text(
        json.dumps(
            {
                "p2pool": {"pool": "mini"},
                "dashboard": {"auth": {"username": "admin", "password": "correct horse"}},
                "workers": {
                    "list": [
                        {"name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok1"}
                    ]
                },
            }
        )
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
    return tmp_path


@pytest.fixture
async def control_client(aiohttp_client, control_spool):
    sm = StateManager(db_path=":memory:")
    data = {"workers": [], "shares": [], "global_sync": False}
    cli = await aiohttp_client(create_app(sm, data))
    yield cli
    sm.close()


def _proposed(live_list, *new_entries):
    return {"workers": {"list": [*live_list, *new_entries]}}


LIVE_RIG1 = {"name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok1"}


class TestAdoptGuardOnPreview:
    async def test_appending_a_well_formed_rig_reaches_the_spool(
        self, control_client, control_spool
    ):
        proposed = _proposed(
            [LIVE_RIG1],
            {"name": "rig2", "host": "10.0.0.10", "control_port": 8082, "token": "tok2"},
        )
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        # No runner in this test, so a well-formed proposal is accepted and left pending — the
        # request landed in the spool rather than being 400'd by the adopt guard.
        assert resp.status == 202
        body = await resp.json()
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        assert req["config"]["workers"]["list"][-1]["name"] == "rig2"

    async def test_no_new_entries_is_unaffected(self, control_client, control_spool):
        # A completely unrelated edit (no workers.list touch at all) must not trip the adopt guard.
        resp = await control_client.post(
            "/api/control/preview",
            json={"config": {"p2pool": {"pool": "main"}}},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202

    async def test_malformed_host_on_new_rig_refused_before_spooling(
        self, control_client, control_spool
    ):
        proposed = _proposed(
            [LIVE_RIG1],
            {"name": "rig2", "host": "10.0.0.10:9999", "control_port": 8082, "token": "tok2"},
        )
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert "rig2" in await resp.text()
        # Refused before it ever reached the spool — the requests/ dir stays empty.
        assert list((control_spool / "requests").glob("*.json")) == []

    async def test_new_rig_pointed_at_loopback_refused_before_spooling(
        self, control_client, control_spool
    ):
        # The critical SSRF case (a well-formed but internally-addressed entry): a compromised
        # dashboard could otherwise append a phantom descriptor at 127.0.0.1 and immediately dial
        # it via /api/control/worker-apply, which resolves strictly from the host's own
        # config.json — this guard must catch it here, before anything reaches the spool.
        proposed = _proposed(
            [LIVE_RIG1],
            {"name": "evil", "host": "127.0.0.1", "control_port": 8000, "token": "attacker"},
        )
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert "evil" in await resp.text()
        assert list((control_spool / "requests").glob("*.json")) == []

    @pytest.mark.parametrize(
        "host", ["2130706433", "0177.0.0.1", "0x7f000001", "127.1", "010.0.0.1"]
    )
    async def test_new_rig_with_an_alternate_ip_encoding_of_loopback_refused(
        self, control_client, control_spool, host
    ):
        # The bypass a security review found: each of these clears HOST_RE's charset (digits,
        # dots, and — for the hex case — letters, all allowed) and is what curl's own
        # numeric-address parser resolves to 127.0.0.1/8.0.0.1, exactly like the literal form
        # above — the route-level guard must refuse all of them, not just the obvious spelling.
        proposed = _proposed(
            [LIVE_RIG1], {"name": "evil", "host": host, "control_port": 8000, "token": "attacker"}
        )
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400, host
        assert list((control_spool / "requests").glob("*.json")) == []

    @pytest.mark.parametrize(
        "host",
        ["localhost.", "LOCALHOST.", "localhost.localdomain", "ip6-localhost", "ip6-loopback"],
    )
    async def test_new_rig_with_a_localhost_alias_or_root_terminated_form_refused(
        self, control_client, control_spool, host
    ):
        # Round-4 finding: a security review verified each of these live (getent hosts + curl)
        # resolves to loopback on this stack's own target OS, and none of them matched the
        # original literal `host == "localhost"` check — the route-level guard must refuse all of
        # them, not just the bare spelling.
        proposed = _proposed(
            [LIVE_RIG1], {"name": "evil", "host": host, "control_port": 8000, "token": "attacker"}
        )
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400, host
        assert list((control_spool / "requests").glob("*.json")) == []

    async def test_new_rig_missing_token_refused(self, control_client, control_spool):
        proposed = _proposed([LIVE_RIG1], {"name": "rig2", "host": "10.0.0.10"})
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert list((control_spool / "requests").glob("*.json")) == []

    async def test_new_rig_bad_control_port_refused(self, control_client, control_spool):
        proposed = _proposed(
            [LIVE_RIG1], {"name": "rig2", "host": "10.0.0.10", "control_port": 0, "token": "tok2"}
        )
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_repointing_an_existing_rigs_host_is_not_pre_refused_by_the_adopt_guard(
        self, control_client, control_spool
    ):
        # The adopt guard only pre-validates NEW entries — repointing an EXISTING one isn't "new"
        # (test_worker_adopt.py proves that at the unit level), so it must sail past this guard
        # and reach the spool. The host's own add-only gate is the one that refuses it, at commit
        # (bash-side, not exercised here) — this test only pins that this guard doesn't double up
        # on that job and accidentally block something it was never meant to police.
        proposed = _proposed([{**LIVE_RIG1, "host": "ATTACKER"}])
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 202
