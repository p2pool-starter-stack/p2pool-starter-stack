"""What the wizard server publishes as an unconfigured machine's starting point (#1830).

A sibling of ``test_wizard.py`` rather than more rows inside it: that file sits at its recorded
ceiling in ``docs/dev/file-budget.tsv``, and ceilings only go down. Its ``spool``/``client``
fixtures are module-local, so this module carries its own copies.

The half the operator SEES — the role select reading these back — is pinned where the dashboard
tests its frontend: ``node --test`` over ``tests/frontend/wizardrole.test.mjs``.
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
    # The published reference as a real machine has it: local_miner is a documented key and it
    # is documented OFF (#593). Without it here BOTH rows below could pass on a missing key.
    sd.joinpath("config.reference.json").write_text(
        json.dumps(
            {
                "monero": {"wallet_address": "", "mode": "local", "prune": True},
                "p2pool": {"pool": "mini"},
                "local_miner": {"enabled": False},
            }
        )
    )
    return sd


@pytest.fixture
async def client(spool):
    c = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await c.start_server()
    yield c
    await c.close()


async def _state(client):
    await client.post("/auth", data={"token": "pit-X7KM2Q"}, allow_redirects=False)  # noqa: S106
    return await (await client.get("/api/wizard-state")).json()


async def test_an_unconfigured_machine_starts_with_the_built_in_miner_on(client):
    # The page's own default, not the product's: the role select opens on "Pithead + RigForge",
    # and that role IS this switch. The reference it is published beside still reads off, which
    # is what the CLI wizard and every existing install keep.
    s = await _state(client)
    assert s["config"]["local_miner"]["enabled"] is True
    assert s["reference"]["local_miner"]["enabled"] is False


async def test_a_configuration_that_already_exists_wins_whole_over_that_default(client, spool):
    # The control, and the reason the default does not merge UNDERNEATH a previous config: an
    # operator pre-seed (12-firstboot-wizard.sh:162), the reinstall pre-fill read off the target
    # disk (10-installer-preseed.sh:220) and a rejected submission all arrive as
    # last-attempt.json, and strip_defaults drops local_miner entirely when it is off. Layered
    # under one of those, this page would read a deliberate Pithead-only machine as
    # "Pithead + RigForge" and switch its miner on behind the operator.
    spool.joinpath("last-attempt.json").write_text(
        json.dumps({"monero": {"wallet_address": "4KEEP"}})
    )
    s = await _state(client)
    assert s["config"]["local_miner"]["enabled"] is False
    assert s["config"]["monero"]["wallet_address"] == "4KEEP"
