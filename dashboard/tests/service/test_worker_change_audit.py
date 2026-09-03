"""Revision-drift, the flood cap it shares with rig-edit, and row-id separation (#1551, #724, #1566).

Tier 1, against a real in-memory ``StateManager`` — a drift row has to be provable in the durable
table, not merely "the mock was called", because the whole feature is a permanent audit row.
"""

import asyncio
from unittest.mock import MagicMock

from mining_dashboard.service.data_service import _RIG_EDIT_CAP_PER_HOUR, DataService
from mining_dashboard.service.storage_service import StateManager


def _svc():
    sm = StateManager(db_path=":memory:")
    return DataService(sm, MagicMock(), MagicMock()), sm


def _body(revision, change_id=None):
    """An enriched worker body carrying the shape ``parse_config_meta`` returns."""
    return {"rigforge": {"config_meta": {"revision": revision, "last_change_id": change_id}}}


def _poll(svc, worker, revision, change_id=None):
    """One poll of one worker through the real caller, so the wiring is what is under test."""
    asyncio.run(svc._reconcile_worker_config([{"name": worker}], [_body(revision, change_id)]))


def _rig_edit(svc, worker, change_id):
    """One poll of one worker down the RIG-EDIT branch: a terminal outcome this dashboard never
    spooled, which is a change the rig applied on its own."""
    ctrl = {"rigforge": {"control": {"change_id": change_id, "status": "applied"}}}
    asyncio.run(svc._reconcile_worker_config([{"name": worker}], [ctrl]))


def _rows(sm, action):
    return [e for e in sm.get_audit_events() if e["action"] == action]


class TestDriftIsRecorded:
    def test_a_revision_move_with_no_new_change_id_writes_a_drift_row(self):
        # The #1542 door: a hand-edit underneath RigForge moves the revision and stamps nothing.
        svc, sm = _svc()
        try:
            _poll(svc, "rig1", "aaa")
            _poll(svc, "rig1", "bbb")
            drift = _rows(sm, "rig-drift")
            assert len(drift) == 1
            assert drift[0]["actor"] == "rig1"
            assert "aaa" in drift[0]["keys"] and "bbb" in drift[0]["keys"]
        finally:
            sm.close()

    def test_it_fires_with_no_terminal_control_status_present(self):
        # The reason the call sits BEFORE the control-status guard: a fresh RigForge rig serves a
        # real revision with no terminal outcome beside it. Guarded first, this case is invisible.
        svc, sm = _svc()
        try:
            _poll(svc, "rig1", "aaa")
            _poll(svc, "rig1", "bbb")
            assert len(_rows(sm, "rig-drift")) == 1
        finally:
            sm.close()


class TestSilentCases:
    def test_first_sighting_is_not_drift(self):
        svc, sm = _svc()
        try:
            _poll(svc, "rig1", "aaa")
            assert _rows(sm, "rig-drift") == []
        finally:
            sm.close()

    def test_an_unmoved_revision_is_not_drift(self):
        svc, sm = _svc()
        try:
            _poll(svc, "rig1", "aaa")
            _poll(svc, "rig1", "aaa")
            assert _rows(sm, "rig-drift") == []
        finally:
            sm.close()

    def test_a_move_with_a_new_change_id_is_not_drift(self):
        # Something DID record that change — this detection is only for what nothing else sees.
        svc, sm = _svc()
        try:
            _poll(svc, "rig1", "aaa", "c1")
            _poll(svc, "rig1", "bbb", "c2")
            assert _rows(sm, "rig-drift") == []
        finally:
            sm.close()

    def test_a_body_with_no_config_meta_is_a_quiet_noop(self):
        svc, sm = _svc()
        try:
            asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], [{"rigforge": {}}]))
            asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], [{}]))
            asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], [None]))
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    def test_an_unnamed_worker_is_a_quiet_noop(self):
        svc, sm = _svc()
        try:
            asyncio.run(svc._reconcile_worker_config([{}], [_body("aaa")]))
            asyncio.run(svc._reconcile_worker_config([{}], [_body("bbb")]))
            assert sm.get_audit_events() == []
        finally:
            sm.close()


class TestFloodIsBounded:
    """#724 applied to a new field. Without this the wiring reopens a closed issue."""

    def test_a_fresh_revision_every_poll_is_capped(self):
        # A rogue rig incrementing its revision clears the deterministic-id dedup every time, so
        # unbounded this writes one PERMANENT row per poll. audit_events has no retention DELETE.
        svc, sm = _svc()
        try:
            for i in range(_RIG_EDIT_CAP_PER_HOUR + 8):
                _poll(svc, "rogue", f"rev-{i}")
            # The first poll is a first sighting, so it establishes the baseline without a row.
            assert len(_rows(sm, "rig-drift")) == _RIG_EDIT_CAP_PER_HOUR
        finally:
            sm.close()

    def test_the_flood_is_never_silent_and_the_marker_names_drift(self):
        svc, sm = _svc()
        try:
            for i in range(_RIG_EDIT_CAP_PER_HOUR + 8):
                _poll(svc, "rogue", f"rev-{i}")
            markers = _rows(sm, "rate-limited")
            assert len(markers) == 1
            assert markers[0]["actor"] == "rogue"
            assert markers[0]["status"] == "dropped"
            # The ruling's requirement: WHICH detection tipped the shared budget, not merely that
            # something did. "capped" alone does not tell an operator where to look.
            assert "revision-drift" in markers[0]["keys"]
        finally:
            sm.close()

    def test_the_cap_is_per_worker_a_flood_does_not_starve_another_rig(self):
        svc, sm = _svc()
        try:
            for i in range(_RIG_EDIT_CAP_PER_HOUR + 5):
                _poll(svc, "rogue", f"rev-{i}")
            _poll(svc, "goodrig", "aaa")
            _poll(svc, "goodrig", "bbb")
            good = [e for e in sm.get_audit_events() if e["actor"] == "goodrig"]
            assert len(good) == 1
            assert good[0]["action"] == "rig-drift"
        finally:
            sm.close()

    def test_drift_and_rig_edit_share_one_budget(self):
        # One untrusted feed, one bound. Two windows would double what a rogue rig can make
        # permanent, which is the thing the cap exists to stop.
        svc, sm = _svc()
        try:
            # cap + 2 polls, because the FIRST is a first sighting: it writes no row and spends
            # no budget. Off-by-one here is why this test failed on its first run with cap polls,
            # which leaves exactly one allowance unspent and lets the rig-edit row through.
            for i in range(_RIG_EDIT_CAP_PER_HOUR + 2):
                _poll(svc, "rogue", f"rev-{i}")
            assert len(_rows(sm, "rig-drift")) == _RIG_EDIT_CAP_PER_HOUR
            ctrl = {"rigforge": {"control": {"change_id": "cid-1", "status": "applied"}}}
            asyncio.run(svc._reconcile_worker_config([{"name": "rogue"}], [ctrl]))
            # The budget was spent by drift, so the rig-edit row is dropped rather than granted a
            # second allowance of its own.
            assert _rows(sm, "rig-edit") == []
        finally:
            sm.close()


class TestTheFeedIsValidatedBeforeTheStoreSeesIt:
    """``worker_results`` is the RAW rig body, and this is the only thing that validates it.

    ``get_stats`` returns the rig's parsed JSON with ``api_ok`` bolted on; the merge that calls
    ``parse_rigforge`` runs later in the poll, on a different object. So the sibling detection on
    this same line (``parse_worker_control_status``) does its own type-checking, and so must this.
    The tests above cannot see a missing parse: they hand in a body that is ALREADY token-shaped,
    supplying the very validation production has to perform for itself.
    """

    def test_a_hostile_revision_never_reaches_the_permanent_row_id(self):
        # event_id is the ONE field _record_audit_event does not pass through audit_service._clean,
        # and nothing downstream truncates audit_events.id. Unvalidated, a rig picks its own
        # primary key: measured at 5011 chars carrying NUL, a newline and markup.
        svc, sm = _svc()
        try:
            hostile = "X" * 4980 + "\n<script>\x00 ;DROP"
            _poll(svc, "rig1", "a" * 16)
            _poll(svc, "rig1", hostile)
            assert _rows(sm, "rig-drift") == []
        finally:
            sm.close()

    def test_a_legitimate_revision_still_writes_a_short_clean_id(self):
        # The other half of the pair: the guard above must refuse the wall of text WITHOUT
        # refusing the 16-hex revision RigForge actually mints, or it has broken the feature.
        svc, sm = _svc()
        try:
            _poll(svc, "rig1", "a" * 16)
            _poll(svc, "rig1", "b" * 16)
            drift = _rows(sm, "rig-drift")
            assert len(drift) == 1
            assert drift[0]["id"] == "rig-drift:rig1:" + "b" * 16
        finally:
            sm.close()

    def test_a_non_string_revision_is_a_quiet_noop(self):
        # Every field is remote-supplied and nothing constrains its JSON type.
        svc, sm = _svc()
        try:
            _poll(svc, "rig1", "a" * 16)
            for junk in (12345, {"nested": "dict"}, ["list"], True):
                _poll(svc, "rig1", junk)
            assert _rows(sm, "rig-drift") == []
        finally:
            sm.close()


class TestRowIdsSeparateOneDetectionFromAnother:
    """#1566, proved against the real table because the failure mode is SILENT.

    The row id is the ``audit_events`` PRIMARY KEY and the writer uses ``INSERT OR IGNORE``, so two
    detections that mint one id neither raise nor land as two rows — the second is DROPPED. Under
    the old bare-"-" join both components were rig-chosen, so a device could pick them.
    """

    def test_the_table_really_does_drop_a_second_row_on_a_repeated_id(self):
        """The mechanism control, first on purpose. Every test below asserts that two detections
        become two rows, and that claim is worth nothing until this table has been SHOWN to
        collapse them when the ids do match."""
        svc, sm = _svc()
        try:
            for keys in ("first", "second"):
                asyncio.run(
                    svc._record_audit_event(
                        "rig-edit", "w", "rig-edit", "applied", keys, event_id="fixed-id"
                    )
                )
            rows = sm.get_audit_events()
            assert len(rows) == 1
            assert rows[0]["keys"] == "first"  # the SECOND write is the one lost, silently
        finally:
            sm.close()

    def test_two_rig_edits_that_used_to_share_an_id_land_as_two_rows(self):
        svc, sm = _svc()
        try:
            # Measured against this same caller in the issue: ("victim-chg1", "extra") and
            # ("victim", "chg1-extra") both minted "rig-edit-victim-chg1-extra".
            assert "victim-chg1-extra" == "-".join(("victim-chg1", "extra"))
            assert "victim-chg1-extra" == "-".join(("victim", "chg1-extra"))
            _rig_edit(svc, "victim-chg1", "extra")
            _rig_edit(svc, "victim", "chg1-extra")
            rows = _rows(sm, "rig-edit")
            assert len(rows) == 2
            assert len({r["id"] for r in rows}) == 2
        finally:
            sm.close()

    def test_two_drift_rows_that_used_to_share_an_id_land_as_two_rows(self):
        """The same ambiguity on the sibling detection. Both halves of ``rig-drift-{worker}-
        {revision}`` are rig-chosen too, so fixing only the rig-edit id would leave this open."""
        svc, sm = _svc()
        try:
            assert "rig-1-2" == "-".join(("rig-1", "2")) == "-".join(("rig", "1-2"))
            _poll(svc, "rig-1", "aaa")  # first sighting: baselines, writes nothing
            _poll(svc, "rig-1", "2")
            _poll(svc, "rig", "aaa")
            _poll(svc, "rig", "1-2")
            rows = _rows(sm, "rig-drift")
            assert len(rows) == 2
            assert len({r["id"] for r in rows}) == 2
        finally:
            sm.close()

    def test_a_rig_edit_row_can_no_longer_suppress_another_workers_cap_marker(self):
        """Shape 1 of the issue, end to end. A device presenting as ``ratelimited-{victim}`` and
        reporting the victim's window start minted EXACTLY the victim's own marker id; landing
        first, it made ``INSERT OR IGNORE`` drop the marker and the flood lost its Security-panel
        row. The warning still logs either way, so the panel row is the whole loss."""
        svc, sm = _svc()
        try:
            _poll(svc, "victim", "rev-0")  # first sighting — no row, no budget, no window
            _poll(svc, "victim", "rev-1")  # first real drift — this is what opens the window
            window = int(svc._rig_edit_window["victim"][0])

            _rig_edit(svc, "ratelimited-victim", str(window))
            forged = [e for e in sm.get_audit_events() if e["actor"] == "ratelimited-victim"]
            # Two fixture controls, because the test below could otherwise go green from the
            # attack never arming rather than from the fix working: the forged row LANDED, and the
            # third assertion shows the two ids really were the same string under the old join —
            # so the second assertion is the fix, not an arbitrary inequality.
            assert len(forged) == 1
            assert forged[0]["id"] != f"rig-edit-ratelimited-victim-{window}"
            assert "-".join(("rig-edit-ratelimited", "victim", str(window))) == "-".join(
                ("rig-edit", "ratelimited-victim", str(window))
            )

            for i in range(2, _RIG_EDIT_CAP_PER_HOUR + 8):
                _poll(svc, "victim", f"rev-{i}")
            markers = _rows(sm, "rate-limited")
            assert len(markers) == 1
            assert markers[0]["actor"] == "victim"
        finally:
            sm.close()

    def test_a_lone_surrogate_worker_name_records_a_row_instead_of_raising(self):
        """The id is now BUILT in the poll loop rather than only cleaned at the sink, which puts an
        encode where there was none, and nothing upstream rejects a lone surrogate in a worker name.

        The WORKER NAME is the position deliberately: measured per position, a surrogate
        ``change_id`` never reaches the escape at all — ``worker_config_change_known`` hands it to
        sqlite first and sqlite refuses it, which is a separate pre-existing raise on this path and
        not what this test is about. Written against the reachable half, this goes RED without
        ``errors="surrogatepass"``; written against the other it would have gone red for sqlite's
        reason and proved nothing about the escape."""
        svc, sm = _svc()
        try:
            _rig_edit(svc, "\ud800", "chg1")
            rows = _rows(sm, "rig-edit")
            assert len(rows) == 1
            assert rows[0]["id"] == "rig-edit:%ED%A0%80:chg1"
        finally:
            sm.close()
