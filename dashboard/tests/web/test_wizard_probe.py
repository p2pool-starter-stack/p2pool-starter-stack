"""The remote-node probe report's server half (#1889).

Before provisioning commits, the HOST dials every remote node the config asked for and refuses
if one does not answer — `preflight_remote_nodes`, called from `12-firstboot-wizard.sh`. Beside
that refusal it publishes `node-probe.json`, the report that says WHY. These tests pin what the
wizard's state API does with it.

The distinction they exist for: **an absent report is not a failed one.** An all-local machine
probes nothing and a host older than the report writes no file, and in both cases `ok` is
missing from the parsed dict exactly as it would be from a truncated one. Reading a falsy
default there would block every machine that runs its own nodes, so PRESENCE — `ok` arriving as
a real bool — is the whole check.

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


def _row(**over):
    """One probe row in the shape 10-installer-preseed.sh emits."""
    row = {
        "target": "monero",
        "host": "node.lan",
        "port": 18081,
        "ok": True,
        "checked": "rpc",
        "reason": "ok",
        "detail": "reached node.lan:18081 and verified it with a live rpc check",
        "elapsed_ms": 12,
    }
    row.update(over)
    return row


def _report(**over):
    rep = {"ok": True, "configured": 1, "probed": 1, "probes": [_row()]}
    rep.update(over)
    return rep


# --- absent is not failed --------------------------------------------------------------------


async def test_node_probe_is_always_a_key_and_is_null_when_no_report_was_written(client):
    """The client asserts on null, never on absence — so the key has to be there either way."""
    await _auth(client)
    s = await _state(client)
    assert "node_probe" in s
    assert s["node_probe"] is None


async def test_a_machine_that_probed_nothing_is_not_reported_as_a_failure(client, spool):
    """The defect this file exists for. An all-local machine writes no report, and the parsed
    dict is then `{}` — whose `ok` is missing exactly as a FAILED report's would be if we read
    it by truthiness. The two must not collapse: one blocks provisioning, the other is the
    healthy default state of every machine running its own nodes."""
    await _auth(client)
    absent = (await _state(client))["node_probe"]

    spool.joinpath("node-probe.json").write_text(json.dumps(_report(ok=False)))
    failed = (await _state(client))["node_probe"]

    assert absent is None
    assert failed is not None and failed["ok"] is False


# --- a report that exists is passed through whole -----------------------------------------


async def test_a_passing_report_is_served_verbatim(client, spool):
    spool.joinpath("node-probe.json").write_text(json.dumps(_report()))
    await _auth(client)
    assert (await _state(client))["node_probe"] == _report()


async def test_a_failing_report_keeps_every_row_so_the_page_can_say_which_leg_failed(client, spool):
    """Monero contributes two rows to Tari's one, and the operator needs the one that failed
    named — a report reduced to its top-level verdict cannot say which."""
    rows = [
        _row(checked="rpc"),
        _row(checked="zmq", port=18083, ok=False, reason="refused", detail="cannot reach"),
    ]
    spool.joinpath("node-probe.json").write_text(
        json.dumps({"ok": False, "configured": 2, "probed": 2, "probes": rows})
    )
    await _auth(client)
    served = (await _state(client))["node_probe"]
    assert served["probes"] == rows
    assert [p["checked"] for p in served["probes"]] == ["rpc", "zmq"]


async def test_nothing_configured_is_a_pass_and_reaches_the_page_as_one(client, spool):
    """0 of 0 PASSES. `all()` over an empty array is true and that is the CORRECT answer for an
    all-local config — `configured` is what separates it from a run that probed nothing of the
    three it was asked for."""
    spool.joinpath("node-probe.json").write_text(
        json.dumps({"ok": True, "configured": 0, "probed": 0, "probes": []})
    )
    await _auth(client)
    served = (await _state(client))["node_probe"]
    assert served["ok"] is True
    assert (served["configured"], served["probed"]) == (0, 0)


async def test_a_run_that_probed_fewer_than_it_was_asked_is_served_as_a_failure(client, spool):
    """The skipped-endpoint case: a SKIPPED endpoint emits no row at all, so the page renders it
    from the `probed < configured` gap and the host has already called it not-ok."""
    spool.joinpath("node-probe.json").write_text(
        json.dumps({"ok": False, "configured": 3, "probed": 0, "probes": []})
    )
    await _auth(client)
    served = (await _state(client))["node_probe"]
    assert served["ok"] is False
    assert served["probed"] < served["configured"]


async def test_every_reason_the_host_can_emit_survives_the_trip(client, spool):
    """The emitter has SEVEN reasons, not the two the first contract named, and the page
    enumerates them — so a value dropped in transit would render as the neutral fallback and
    look like a rendering choice rather than a lost field."""
    reasons = ["ok", "protocol", "timeout", "refused", "auth", "missing-tool", "unknown"]
    rows = [_row(reason=r, ok=(r == "ok")) for r in reasons]
    spool.joinpath("node-probe.json").write_text(
        json.dumps({"ok": False, "configured": len(rows), "probed": len(rows), "probes": rows})
    )
    await _auth(client)
    served = (await _state(client))["node_probe"]
    assert [p["reason"] for p in served["probes"]] == reasons


# --- a broken report blocks nothing ----------------------------------------------------------


@pytest.mark.parametrize(
    "written",
    [
        pytest.param("{ not json", id="unparseable"),
        pytest.param("[]", id="a list, not an object"),
        pytest.param('"ok"', id="a bare string"),
        pytest.param("{}", id="an empty object"),
        pytest.param('{"configured": 2, "probed": 0}', id="counts but no verdict"),
        pytest.param('{"ok": "true"}', id="ok as a STRING, not a bool"),
        pytest.param('{"ok": 1}', id="ok as 1 — truthy, and still not a bool"),
        pytest.param('{"ok": null}', id="ok explicitly null"),
    ],
)
async def test_a_report_that_carries_no_real_verdict_reads_as_no_report(client, spool, written):
    """Fails open, like every other spool reader: a broken file blocks nothing.

    The string and integer cases pin the mechanism rather than its effect. `isinstance(x, bool)`
    is not truthiness — `"true"` and `1` are both truthy and neither is a verdict the host
    wrote, and a check written as `if report.get("ok") is not None` would let all three of the
    last cases through while still passing every other test in this file.
    """
    spool.joinpath("node-probe.json").write_text(written)
    await _auth(client)
    assert (await _state(client))["node_probe"] is None


async def test_the_report_is_behind_the_token_gate_like_the_rest_of_the_state(client, spool):
    """It names hosts and ports on the operator's LAN, so it is not readable unauthenticated."""
    spool.joinpath("node-probe.json").write_text(json.dumps(_report()))
    r = await client.get("/api/wizard-state")
    assert r.status == 401
    assert "node_probe" not in await r.json()
