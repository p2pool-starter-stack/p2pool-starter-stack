"""A host verdict never outlives the config it judged (#1889).

Beside its refusal the host publishes `node-probe.json` — the report naming which remote node
did not answer — exactly as it publishes `error.txt` for the reason. Both describe ONE
submission. Nothing on the host removes either: `preflight_remote_nodes` (10-installer-preseed.sh)
only ever writes, and its single call site sits inside the accept arm of the wizard loop, so every
arm that hands the form back earlier leaves the previous report untouched. The survivor is
typically a PASSING report, because the host writes one on the pass path too — and once the setup
page renders it, a stale pass tells the operator the nodes were reached when nothing has dialled
them yet.

The clear therefore lives where a new submission ARRIVES — the four spool-writing entry points
this server has — rather than on each handback arm the host might grow later. A fifth arm added
to the host tomorrow inherits the fix; a per-arm removal would not.

They live beside `test_wizard.py` rather than in it because that file is at its budget ceiling.
"""

import json

import pytest
from aiohttp import FormData
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import wizard

CFG = json.dumps({"monero": {"wallet_address": "4A"}, "tari": {"wallet_address": "t"}})


@pytest.fixture
def spool(tmp_path, monkeypatch):
    sd = tmp_path / "spool"
    sd.mkdir()
    monkeypatch.setenv("WIZARD_SPOOL", str(sd))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    sd.joinpath("config.reference.json").write_text(json.dumps({"p2pool": {"pool": "mini"}}))
    return sd


@pytest.fixture
def installer(spool):
    spool.joinpath("disks.tsv").write_text(
        "nvme0n1\t931.5G\tSamsung SSD 990\tS6P1NF0T\tempty\n"
        "sda\t3.6T\tWDC WD40EFRX\tWD-WCC7K3\tpithead-with-data\n"
    )
    return spool


@pytest.fixture
async def client(spool):
    c = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await c.start_server()
    yield c
    await c.close()


async def _auth(client, token="pit-X7KM2Q"):  # noqa: S107 — the test fixture's token, not a secret
    return await client.post("/auth", data={"token": token}, allow_redirects=False)


def _arm(spool):
    """The previous attempt's verdict, PASSING — the shape that misleads. A failing report left
    standing is merely confusing; a passing one is read as an answer about the config in hand.
    Asserting it landed is the point: a fixture that never armed passes for the wrong reason."""
    spool.joinpath("node-probe.json").write_text(
        json.dumps({"ok": True, "configured": 1, "probed": 1, "probes": []})
    )
    spool.joinpath("error.txt").write_text("the node at 10.0.0.9:18081 did not answer")
    assert (spool / "node-probe.json").exists()
    assert (spool / "error.txt").exists()


def _archive_form(**extra):
    form = FormData()
    form.add_field(
        "archive", b"Salted__fixture", filename="b.tar.gz.enc", content_type="application/gzip"
    )
    form.add_field("passphrase", "hunter2")
    for k, v in extra.items():
        form.add_field(k, v)
    return form


# --- every entry point that accepts a submission voids the last verdict ----------------------


async def test_a_config_submission_voids_the_previous_report(client, spool):
    _arm(spool)
    await _auth(client)
    assert (await client.post("/submit", data={"config": CFG})).status == 200
    assert not (spool / "node-probe.json").exists()
    # The error it has always cleared goes with it — same file, same reason, one helper.
    assert not (spool / "error.txt").exists()


async def test_a_rig_submission_voids_the_previous_report(client, spool):
    """A rig writes no config.json at all, so its report is stale in the strongest sense: the
    machine is not even the role the probe ran for."""
    _arm(spool)
    await _auth(client)
    r = await client.post("/submit", data={"role": "rig", "rig_pool": "pithead.local:3333"})
    assert r.status == 200
    assert not (spool / "node-probe.json").exists()


async def test_a_bare_keep_install_request_voids_the_previous_report(client, installer):
    """Keep-everything submits no config candidate — the arm that most obviously has nothing
    for a node report to be about."""
    _arm(installer)
    await _auth(client)
    r = await client.post("/submit", data={"disk": "sda", "confirm": "sda", "wipe": "keep"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    assert not (installer / "node-probe.json").exists()


async def test_a_restore_submission_voids_the_previous_report(client, spool):
    _arm(spool)
    await _auth(client)
    assert (await client.post("/submit-restore", data=_archive_form())).status == 200
    assert not (spool / "node-probe.json").exists()


# --- the control: a submission the server REFUSES must leave the report alone -----------------
# Without these the four rows above are an enumeration that only ever came back one way, and a
# helper that unlinked the file unconditionally at import would pass all of them.


async def test_a_refused_submission_leaves_the_report_alone(client, spool):
    _arm(spool)
    await _auth(client)
    assert (await client.post("/submit", data={"config": "{not json"})).status == 400
    assert (spool / "node-probe.json").exists()
    assert (spool / "error.txt").exists()


async def test_an_unauthed_submission_leaves_the_report_alone(client, spool):
    _arm(spool)
    r = await client.post("/submit", data={"config": CFG}, allow_redirects=False)
    assert r.status == 302
    assert (spool / "node-probe.json").exists()


async def test_a_wrongly_confirmed_disk_leaves_the_report_alone(client, installer):
    """The gate refuses before the clear, not after — a mistyped confirmation is not a
    submission, and the operator keeps the report the page is showing them."""
    _arm(installer)
    await _auth(client)
    r = await client.post("/submit", data={"disk": "sda", "confirm": "sdb", "wipe": "keep"})
    assert r.status == 400
    assert (installer / "node-probe.json").exists()
