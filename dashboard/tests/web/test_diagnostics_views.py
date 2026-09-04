"""Service Diagnostics routes (#913 doctor detail, #943 log tail).

The behaviours proven here are the ones that live in THIS container: the CSRF gate, the request
shape that reaches the spool, and — the one worth stating plainly — that the container check is a
SHAPE check and not an allowlist. The host owns the allowlist, the line cap and the redaction;
those are proven in tests/stack against the real runner, not here against a fake.
"""

import json

import pytest

from mining_dashboard.service import control_service, diagnostics_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import create_app

CONTROL_HEADERS = {"X-Pithead-Control": "1"}


@pytest.fixture
def spool(tmp_path, monkeypatch):
    """Enable the control channel and point both services at a throwaway spool."""
    (tmp_path / "requests").mkdir()
    (tmp_path / "results").mkdir()
    monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    monkeypatch.setattr(control_service.config, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    return tmp_path


@pytest.fixture
async def diag_client(aiohttp_client, spool):
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, {}))
    yield cli
    sm.close()


def spooled(spool):
    """The single request the spool holds, parsed. Asserts there is exactly one, so a test can
    never read the leftovers of an earlier submit and call it this one's."""
    files = list((spool / "requests").glob("*.json"))
    assert len(files) == 1, files
    return json.loads(files[0].read_text())


class TestDiagRoutesDisabled:
    async def test_both_routes_404_when_the_control_channel_is_off(
        self, aiohttp_client, monkeypatch
    ):
        # Off means 404, not 403 — the route does not exist, matching the rest of the channel.
        monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", False)
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, {}))
        try:
            for path in ("/api/control/diag-doctor", "/api/control/diag-logs"):
                resp = await cli.post(path, headers=CONTROL_HEADERS, json={"container": "tor"})
                assert resp.status == 404, path
        finally:
            sm.close()


class TestDiagDoctor:
    async def test_requires_the_control_header(self, diag_client):
        assert (await diag_client.post("/api/control/diag-doctor")).status == 403

    async def test_202_and_spools_a_closed_request(self, diag_client, spool):
        resp = await diag_client.post(
            "/api/control/diag-doctor", headers={**CONTROL_HEADERS, "X-Auth-User": "admin"}
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        # Closed shape: exactly these keys. A doctor run takes no operator input, so there is no
        # field here for one to ride in on.
        assert spooled(spool) == {"id": body["id"], "action": "diag-doctor", "actor": "admin"}

    async def test_a_missing_auth_user_spools_an_empty_actor_not_a_crash(self, diag_client, spool):
        resp = await diag_client.post("/api/control/diag-doctor", headers=CONTROL_HEADERS)
        assert resp.status == 202
        assert spooled(spool)["actor"] == ""

    async def test_a_spool_failure_is_a_500_that_names_no_path(self, diag_client, monkeypatch):
        monkeypatch.setattr(
            diagnostics_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests"
        )
        resp = await diag_client.post("/api/control/diag-doctor", headers=CONTROL_HEADERS)
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())


class TestDiagLogs:
    async def test_requires_the_control_header(self, diag_client):
        resp = await diag_client.post("/api/control/diag-logs", json={"container": "tor"})
        assert resp.status == 403

    async def test_a_non_json_body_is_a_400(self, diag_client):
        resp = await diag_client.post(
            "/api/control/diag-logs", headers=CONTROL_HEADERS, data="not json"
        )
        assert resp.status == 400

    @pytest.mark.parametrize("body", [[], "a string", 42, None])
    async def test_valid_json_that_is_not_an_object_is_a_400_not_a_500(
        self, diag_client, spool, body
    ):
        # These are all valid JSON with no .get — the client's error, so 400. Without the type
        # check they raise past the handler and aiohttp answers 500.
        resp = await diag_client.post("/api/control/diag-logs", headers=CONTROL_HEADERS, json=body)
        assert resp.status == 400
        assert list((spool / "requests").glob("*.json")) == []

    @pytest.mark.parametrize(
        "container",
        [
            None,
            "",
            123,
            "tor p2pool",  # a separator that would be two words to the host's `for` loop
            "tor;rm -rf /",
            "../../etc/passwd",
            "TOR",  # compose names are lowercase
            "-leading-dash",
            "x" * 64,  # one past the length the shape check allows
        ],
    )
    async def test_a_malformed_container_is_a_400_and_spools_nothing(
        self, diag_client, spool, container
    ):
        resp = await diag_client.post(
            "/api/control/diag-logs", headers=CONTROL_HEADERS, json={"container": container}
        )
        assert resp.status == 400
        assert list((spool / "requests").glob("*.json")) == []

    async def test_a_wellformed_but_unlisted_container_still_spools(self, diag_client, spool):
        """THE TRUST BOUNDARY, asserted rather than described. `wallet-rpc` is a real compose
        service the host deliberately REFUSES. This container must not pre-judge that: it spools
        the request and lets the host answer "rejected", because a second allowlist here is how
        the two drift — and the drift would read as a dashboard bug."""
        resp = await diag_client.post(
            "/api/control/diag-logs",
            headers=CONTROL_HEADERS,
            json={"container": "wallet-rpc", "lines": 10},
        )
        assert resp.status == 202
        assert spooled(spool)["container"] == "wallet-rpc"

    @pytest.mark.parametrize("lines", [0, -1, "50", 1.5, True, False, None])
    async def test_a_malformed_line_count_is_a_400_and_spools_nothing(
        self, diag_client, spool, lines
    ):
        # True/False are here on purpose: bool subclasses int, so an isinstance check that forgets
        # it would spool `{"lines": true}` as a request for one line.
        resp = await diag_client.post(
            "/api/control/diag-logs",
            headers=CONTROL_HEADERS,
            json={"container": "tor", "lines": lines},
        )
        assert resp.status == 400
        assert list((spool / "requests").glob("*.json")) == []

    async def test_202_and_spools_a_closed_request(self, diag_client, spool):
        resp = await diag_client.post(
            "/api/control/diag-logs",
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
            json={"container": "monerod", "lines": 25},
        )
        assert resp.status == 202
        body = await resp.json()
        assert spooled(spool) == {
            "id": body["id"],
            "action": "diag-logs",
            "actor": "admin",
            "container": "monerod",
            "lines": 25,
        }

    async def test_an_absent_line_count_defaults_to_the_hosts_cap(self, diag_client, spool):
        resp = await diag_client.post(
            "/api/control/diag-logs", headers=CONTROL_HEADERS, json={"container": "tor"}
        )
        assert resp.status == 202
        assert spooled(spool)["lines"] == diagnostics_service.MAX_TAIL_LINES

    async def test_an_over_cap_count_is_spooled_as_asked_because_the_host_clamps(
        self, diag_client, spool
    ):
        """Not a gap: the bound is a HOST property. Refusing here would only move the check to the
        side an attacker writing the spool directly can skip, and would make the dashboard the
        thing that has to stay in step with the host's cap."""
        resp = await diag_client.post(
            "/api/control/diag-logs",
            headers=CONTROL_HEADERS,
            json={"container": "tor", "lines": 10_000},
        )
        assert resp.status == 202
        assert spooled(spool)["lines"] == 10_000

    async def test_a_spool_failure_is_a_500_that_names_no_path(self, diag_client, monkeypatch):
        monkeypatch.setattr(
            diagnostics_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests"
        )
        resp = await diag_client.post(
            "/api/control/diag-logs", headers=CONTROL_HEADERS, json={"container": "tor"}
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())
