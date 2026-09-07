"""What the wizard serves a machine that has never been configured (#1855, #1848).

The state API hands the page a config built from two sources: `config.reference.json`, which the
host publishes, and the page's own answers for a machine with no configuration yet. Those two
disagree on exactly one key now, and the disagreement is the point of #1855 — the reference says
`tari.mode: "local"` and must keep saying it, while a NEW machine is served `"off"`.

That split is easy to get wrong in the direction nobody sees: a page whose components can render
"No" but whose served config says "local" shows every new operator a Yes, and the whole finding
survives the fix. So these pin the SERVED value, not the component.

They live beside `test_wizard.py` rather than in it because that file is at its budget ceiling,
and they carry their own fixtures for the same reason its three other siblings do.
"""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import wizard

# The host's published reference, trimmed to what these read. `tari.mode` is "local" here because
# that is what config.reference.json says: a config that omits the key means local, which is what
# keeps a 1.x install merge-mining across the 2.0 upgrade.
REFERENCE = {
    "monero": {"wallet_address": "", "mode": "local", "prune": True},
    "tari": {"wallet_address": "", "mode": "local"},
    "p2pool": {"pool": "mini"},
    "xvb": {"enabled": True},
}


@pytest.fixture
def spool(tmp_path, monkeypatch):
    sd = tmp_path / "spool"
    sd.mkdir()
    monkeypatch.setenv("WIZARD_SPOOL", str(sd))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    sd.joinpath("config.reference.json").write_text(json.dumps(REFERENCE))
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
    await _auth(client)
    return await (await client.get("/api/wizard-state")).json()


async def test_a_new_machine_is_served_a_decline_the_reference_does_not_carry(client):
    """The finding: a fresh install showed Tari coming up for an operator who never asked."""
    s = await _state(client)
    assert s["config"]["tari"]["mode"] == "off"
    # The reference the same response carries is untouched, and that is not incidental: the page
    # diffs against it to decide what to write, and the host reads a missing key as "local". If
    # this ever came back "off", `strip_defaults` would drop the decline as a no-op default and
    # the machine would merge-mine anyway.
    assert s["reference"]["tari"]["mode"] == "local"


async def test_the_page_default_does_not_reach_a_machine_that_already_answered(client, spool):
    """The migration guard, at the seam where it actually acts."""
    for attempt, expected in (
        # An install that chose local keeps local — the obvious half.
        ({"tari": {"mode": "local"}}, "local"),
        # The half that matters: a 1.x config predates the question entirely. It is still a
        # machine WITH answers, so it falls through to the reference's "local" and is never
        # handed the new machine's decline. Serving "off" here would tell an upgraded install it
        # had declined merge-mining, and submitting that page would write the decline back.
        ({"monero": {"wallet_address": "4AAA"}}, "local"),
    ):
        spool.joinpath("last-attempt.json").write_text(json.dumps(attempt))
        assert (await _state(client))["config"]["tari"]["mode"] == expected, attempt


async def test_a_rejected_attempt_keeps_the_decline_the_operator_just_made(client, spool):
    # The same path carries a submission the host bounced. An operator who answered No, hit a
    # validation error on some other field, and got the form back must not find Tari switched
    # back on underneath the error.
    spool.joinpath("last-attempt.json").write_text(json.dumps({"tari": {"mode": "off"}}))
    assert (await _state(client))["config"]["tari"]["mode"] == "off"


async def test_the_raffle_is_served_from_the_reference_and_not_pinned_by_the_page(client, spool):
    """#1848 is opt-OUT, so the page has no answer of its own to add here.

    Asserted by moving the reference and watching the served value follow, rather than by
    reading the page's own defaults: a value that merely happens to equal the reference today
    proves nothing about where it came from.
    """
    assert (await _state(client))["config"]["xvb"]["enabled"] is True
    spool.joinpath("config.reference.json").write_text(
        json.dumps({**REFERENCE, "xvb": {"enabled": False}})
    )
    assert (await _state(client))["config"]["xvb"]["enabled"] is False
