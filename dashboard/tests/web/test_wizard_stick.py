"""Run-from-USB narration: a rig set up to RUN FROM the stick is never shown the installer's
"Copying the system to the disk…" (#1835).

Nothing is copied to any disk on that path — the rig is provisioned in place and starts mining
— so both things the page can read must agree: /status and the stage the frontend polls. A
sibling assertion pins the DISK-install path in every case, because a fix that merely deleted
the install narration would pass a one-sided test while breaking the path that needs it.

A new file rather than rows in test_wizard.py: that file is at its file-budget ceiling.
"""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import wizard

RIG = {"role": "rig", "rig_pool": "10.0.0.5:3333"}


@pytest.fixture
def spool(tmp_path, monkeypatch):
    sd = tmp_path / "spool"
    sd.mkdir()
    monkeypatch.setenv("WIZARD_SPOOL", str(sd))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    return sd


@pytest.fixture
def installer(spool):
    """The host booted from removable media and published a disk inventory."""
    spool.joinpath("disks.tsv").write_text("nvme0n1\t931.5G\tSamsung SSD 990\tS6P1NF0T\tempty\n")
    return spool


@pytest.fixture
async def client(spool):
    c = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await c.start_server()
    yield c
    await c.close()


async def _auth(client):
    return await client.post(
        "/auth",
        data={"token": "pit-X7KM2Q"},  # noqa: S106 — the fixture's token, not a secret
        allow_redirects=False,
    )


async def _status(client):
    return await (await client.get("/status")).text()


# --- the marker ------------------------------------------------------------------------------


async def test_the_marker_is_a_per_submission_fact_not_a_one_way_write(client, installer):
    """Every submission RESTATES the medium. A one-way write is the whole bug in mirror image: a
    stick choice left by an earlier attempt would mute the install narration on a later real
    install. Nothing here clears the marker by hand — if it did, the second half could not fail."""
    await _auth(client)
    assert (await client.post("/submit", data={**RIG, "disk": "usb"})).status == 200
    assert (installer / "stick").read_text() == "1"
    assert json.loads((installer / "rig-request.json").read_text()) == {"pool": "10.0.0.5:3333"}

    r = await client.post(
        "/submit", data={**RIG, "disk": "nvme0n1", "confirm": "nvme0n1", "wipe": "all"}
    )
    assert r.status == 200
    assert (installer / "stick").read_text() == "0"


async def test_a_retarget_after_a_failed_stick_attempt_gets_the_install_narration_back(
    client, installer
):
    """The reachable sequence, in one boot: the stick attempt is rejected by the host, the operator
    retargets to the internal disk, and the real install must narrate as a real install — including
    the remove-the-stick instruction, which the frontend gates on the "Installed" prefix."""
    await _auth(client)
    await client.post("/submit", data={**RIG, "disk": "usb"})
    # The host fails the dial and drops the request; the page returns to the form with the error.
    (installer / "error.txt").write_text("pool unreachable")
    (installer / "rig-request.json").unlink()

    await client.post(
        "/submit", data={**RIG, "disk": "nvme0n1", "confirm": "nvme0n1", "wipe": "all"}
    )
    assert "Copying the system to the disk" in await _status(client)
    (installer / "installed").write_text("1")
    body = await _status(client)
    assert body.startswith("Installed")
    assert "remove the USB stick" in body


async def test_a_rig_off_the_medium_leaves_the_marker_inert(client, spool):
    """Not on the installation medium: the marker is written but can never read as a stick run."""
    await _auth(client)
    assert (await client.post("/submit", data=RIG)).status == 200
    assert (spool / "stick").read_text() == "0"


# --- /status ---------------------------------------------------------------------------------


async def test_a_stick_run_is_never_told_the_system_is_being_copied(client, installer):
    """The reported bug: the page sat on the install text while the rig was already mining."""
    await _auth(client)
    await client.post("/submit", data={**RIG, "disk": "usb"})

    # Before the host applies: waiting, not copying.
    body = await _status(client)
    assert "Copying" not in body
    assert "Waiting" in body

    # After it applies: the in-place rig text, which says where the machine actually went.
    (installer / "applied").write_text("1")
    body = await _status(client)
    assert "Copying" not in body
    assert "Rig settings saved" in body
    assert "Workers view" in body


async def test_a_disk_install_is_still_told_the_system_is_being_copied(client, installer):
    """The sibling that makes the assertion above narrow: the install path is untouched."""
    await _auth(client)
    await client.post(
        "/submit", data={**RIG, "disk": "nvme0n1", "confirm": "nvme0n1", "wipe": "all"}
    )
    assert "Copying the system to the disk" in await _status(client)

    (installer / "installed").write_text("1")
    assert "switching itself off" in await _status(client)


async def test_a_stick_run_still_surfaces_a_host_rejection(client, installer):
    """Taking the in-place branch must not cost the stick path its error narration."""
    await _auth(client)
    await client.post("/submit", data={**RIG, "disk": "usb"})
    (installer / "error.txt").write_text("pool unreachable")
    body = await _status(client)
    assert "Copying" not in body
    assert "Rejected: pool unreachable" in body


# --- the stage the frontend polls ------------------------------------------------------------


async def test_an_applied_stick_run_is_done_not_installing(client, installer):
    """wizard_stage drives the Installing card, so it has to agree with /status."""
    await _auth(client)
    await client.post("/submit", data={**RIG, "disk": "usb"})
    (installer / "applied").write_text("1")
    assert wizard.wizard_stage() == "done"


async def test_an_applied_disk_install_is_still_installing(client, installer):
    """The sibling: without the marker the same spool state is an install."""
    await _auth(client)
    await client.post(
        "/submit", data={**RIG, "disk": "nvme0n1", "confirm": "nvme0n1", "wipe": "all"}
    )
    (installer / "applied").write_text("1")
    assert wizard.wizard_stage() == "installing"
