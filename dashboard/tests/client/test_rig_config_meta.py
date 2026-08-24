"""The rig's config provenance block (#1345).

Two things are under test here and they fail in different directions. The FILTER has to refuse a
rig that describes its own provenance in terms we did not define — the operator's only reason to
believe this line is that a rig cannot write it. The MAPPING has to keep apart the cases that look
alike and mean opposite things: a change we made, a change someone else made through a control
channel, a change made on the rig, a restore, and a change of ours the rig rolled back — which
reaches us wearing the same ``source`` and the same change id as the one that held.
"""

import pytest

from mining_dashboard.client.rig_config_meta import (
    HELD_STATUSES,
    REVERTED_STATUSES,
    config_origin,
    parse_config_meta,
)
from mining_dashboard.client.xmrig_client import parse_rigforge

GOOD = {
    "revision": "a1b2c3d4e5f60718",
    "changed_at": "2026-08-23T14:30:45Z",
    "source": "control",
    "last_change_id": "0f1e2d3c4b5a6978",
}


def test_a_well_formed_block_survives_whole():
    assert parse_config_meta(dict(GOOD)) == GOOD


def test_a_rig_that_has_never_recorded_a_change_keeps_its_revision():
    # What a fresh RigForge rig actually serves: the revision is recomputed from the running config
    # every time, so it is present even when the marker file that holds the other three does not
    # exist. Dropping the whole block here would throw away the one field that is always true.
    fresh = {"revision": "aaaabbbbccccdddd", "changed_at": None, "source": None}
    assert parse_config_meta(fresh) == {
        "revision": "aaaabbbbccccdddd",
        "changed_at": None,
        "source": None,
        "last_change_id": None,
    }


def test_a_rig_with_nothing_usable_reads_as_no_block_at_all():
    # Not an empty dict: an all-null block and an absent one mean the same thing to the operator,
    # and returning {} would make the UI render a provenance line with nothing in it.
    assert parse_config_meta({"revision": None, "source": None}) is None
    assert parse_config_meta({}) is None


def test_a_block_that_is_not_a_block_is_refused():
    for junk in (None, "control", 42, ["control"], True):
        assert parse_config_meta(junk) is None


def test_a_rig_cannot_invent_its_own_provenance():
    # The spoofing case, and the reason source is an allowlist rather than a pass-through. A rig
    # that is compromised or simply patched can put any string here, and a UI that repeats it would
    # let the rig testify about itself in words the operator reads as ours.
    for lie in ("pithead", "operator", "applied from the dashboard", "CONTROL", "", None, 1):
        assert parse_config_meta({**GOOD, "source": lie})["source"] is None


def test_a_wall_of_text_never_reaches_the_operator():
    assert parse_config_meta({**GOOD, "revision": "x" * 65})["revision"] is None
    assert parse_config_meta({**GOOD, "last_change_id": "y" * 4096})["last_change_id"] is None
    # Anything that is not a plausible id, including markup and whitespace padding.
    for junk in ("<b>rev</b>", "a1b2 c3d4", "rev/../..", None, 17, {"a": 1}):
        assert parse_config_meta({**GOOD, "revision": junk})["revision"] is None


def test_a_timestamp_the_rig_did_not_stamp_is_not_shown():
    # RigForge writes exactly one format (`date -u +%Y-%m-%dT%H:%M:%SZ`). Anything else cannot be
    # rendered as a time honestly, so it is dropped rather than passed to the browser to guess at.
    for junk in ("2026-08-23 14:30:45", "yesterday", "2026-08-23T14:30:45+02:00", 1756000000, None):
        assert parse_config_meta({**GOOD, "changed_at": junk})["changed_at"] is None


def test_a_control_change_we_have_a_record_of_and_that_held_is_ours():
    assert config_origin(GOOD, change_id_known=True, change_status="applied") == "here"


@pytest.mark.parametrize("status", ["rolled_back", "failed", "rejected"])
def test_a_control_change_our_history_says_did_not_hold_is_not_claimed_as_running(status):
    # The rig keeps naming a change its own rollback reverted, because RigForge re-stamps the same
    # change id when it restores the previous config. Only the row's status tells the two apart.
    assert config_origin(GOOD, change_id_known=True, change_status=status) == "reverted"


@pytest.mark.parametrize(
    "status",
    [
        # REACHABLE, and the reason this issue exists. ``accepted`` is what
        # ``add_worker_config_version`` writes when the rig returns a 202, and
        # ``reconcile_worker_config_status`` is the only thing that ever moves it off. A rollback
        # slower than the host runner's status-poll deadline leaves the row here forever, so the
        # rig names a change it has already thrown away while our row still says "accepted".
        "accepted",
        # Written only by the control-UPGRADE path (rigforge server.py's ``_record_worker_result``
        # with ``change_type="upgrade"``; its own comment reads "noop/throttled are upgrade-only").
        # Those rows DO land in ``worker_config`` and this scan DOES walk them — but an upgrade's
        # change id can never become a rig's ``last_change_id``, because ``_control_upgrade_do``
        # ends by exec'ing ``rigforge.sh upgrade`` as a CHILD PROCESS and
        # ``RIGFORGE_CONFIG_SOURCE`` / ``RIGFORGE_CONFIG_CHANGE_ID`` are declared ``local`` and
        # never exported, so the child stamps ``source=local`` with an empty id. One ``export`` on
        # that line would silently break that, and nothing at this call site would show it — which
        # is exactly why the cautious answer is asserted here rather than assumed.
        "noop",
        "throttled",
        # NOT reachable through today's writer: ``_record_worker_result`` filters on
        # ``_RECORDABLE_WORKER_STATUSES`` and ``reconcile_worker_config_status`` on
        # ``_RECONCILE_TERMINAL``, and no member of either is missing above. They are asserted
        # anyway, because that is the entire property an allowlist buys: a status nobody here
        # anticipated — a future RigForge outcome, a row from an older schema, a NULL column — is
        # refused BY CONSTRUCTION rather than by someone remembering to add it to a denylist.
        "pending",
        "unknown",
        "timeout",
        "error",
        None,
        "",
    ],
)
def test_a_change_our_history_cannot_confirm_held_is_never_claimed_as_running(status):
    assert config_origin(GOOD, change_id_known=True, change_status=status) == "unconfirmed"


def test_the_reassuring_verdict_is_reached_only_through_the_allowlist():
    # The property, stated as a test rather than as a comment: ``here`` is not the fall-through.
    # The first shape of this check returned ``here`` for everything outside REVERTED_STATUSES,
    # which is why every status above used to read as "Last changed from this dashboard".
    #
    # The emptiness guard below is load-bearing, not a formality. Without it every assertion in
    # this test is vacuous the moment ``HELD_STATUSES`` is empty: the loop does not run and
    # ``all()`` over nothing is True, so a test named for the allowlist passes with no allowlist
    # at all. Caught by mutation — emptying the tuple redded four other tests and left this one
    # green, which is the one result a test asserting this property must never give.
    assert HELD_STATUSES, "an empty allowlist makes every assertion below vacuous"
    for status in HELD_STATUSES:
        assert config_origin(GOOD, change_id_known=True, change_status=status) == "here"
    assert all(s not in REVERTED_STATUSES for s in HELD_STATUSES)
    # Omitting the argument entirely must not be the calm answer either — a caller that cannot say
    # what our row records has told us nothing, not that the change held.
    assert config_origin(GOOD, change_id_known=True) == "unconfirmed"


def test_a_control_change_we_have_no_record_of_is_not_claimed_as_ours():
    # The case worth having: an id minted by a rig's control server that never reached this
    # dashboard's history. Another host applied it, or our record of it is gone. Reporting it as
    # "applied from here" would be the exact lie this issue exists to stop.
    assert config_origin(GOOD, change_id_known=False) == "elsewhere"


def test_a_change_made_on_the_rig_says_so():
    assert config_origin({**GOOD, "source": "local"}, change_id_known=False) == "rig"


def test_a_restore_is_not_reported_as_someone_editing_the_rig():
    # RigForge stamps `restore` for its own automatic rollback after a failed change, so folding
    # this into "changed on the rig" would accuse a person of a change the rig made to itself.
    assert config_origin({**GOOD, "source": "restore"}, change_id_known=False) == "restored"
    assert config_origin({**GOOD, "source": "restore"}, change_id_known=True) == "restored"


def test_a_rig_that_recorded_nothing_claims_nothing():
    # A fresh rig and a rig whose config file was edited underneath RigForge are indistinguishable
    # from here, so this names neither.
    meta = parse_config_meta({"revision": "aaaabbbbccccdddd"})
    assert config_origin(meta, change_id_known=False) == "unrecorded"


def test_no_block_at_all_produces_no_verdict():
    # Distinct from "unrecorded": a rig too old to answer must leave the UI silent, not suspicious.
    assert config_origin(None, change_id_known=False) is None


def test_parse_rigforge_carries_the_block_through():
    # Asserts a value that is NOT what an absent block produces: `local`/that revision can only be
    # here if the pass-through ran. A test whose expected value equals the default proves nothing.
    parsed = parse_rigforge(
        {"rigforge": {"version": "1.8.0", "config_meta": {**GOOD, "source": "local"}}}
    )
    assert parsed["config_meta"]["source"] == "local"
    assert parsed["config_meta"]["revision"] == GOOD["revision"]


def test_a_rig_without_the_block_carries_none():
    assert parse_rigforge({"rigforge": {"version": "1.7.0"}})["config_meta"] is None
