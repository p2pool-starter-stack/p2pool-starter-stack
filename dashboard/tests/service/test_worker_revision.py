"""``note_worker_revision``: the observed-revision comparison behind #1551.

A new module rather than more of ``test_storage_worker.py``, which sits at its recorded file-budget
ceiling (451/451). The subject is the same store, so the tests-ROOT ``state_manager`` fixture from
``dashboard/tests/conftest.py`` serves here unchanged.

What is worth testing here is the CLASSIFIER, not the round-trip: the method's whole job is to tell
an edit nothing recorded (the revision moved, no new ``last_change_id``) from every neighbouring
case that must stay silent. Each test below is one side of that boundary, and the pairs are
deliberate — a test that only ever feeds it the positive case would pass just as well against a
method that flagged everything.
"""


def _meta(revision, last_change_id=None):
    """The two fields ``note_worker_revision`` reads, in the shape ``parse_config_meta`` returns."""
    return {
        "revision": revision,
        "last_change_id": last_change_id,
        "changed_at": None,
        "source": None,
    }


class TestFirstObservation:
    """A rig with no stored row accuses nobody, but is recorded so the NEXT poll can compare."""

    def test_first_sighting_is_silent(self, state_manager):
        assert state_manager.note_worker_revision("rig1", _meta("aaa")) is None

    def test_first_sighting_is_stored(self, state_manager):
        # The silence above must not be silence about nothing: the row has to land, or every poll
        # is a first sighting forever and the feature never fires.
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) is not None


class TestUnrecordedEdit:
    """The #1551 case: the revision moved and nothing recorded that it did."""

    def test_moved_with_no_change_id_either_side(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) == {
            "worker": "rig1",
            "before": "aaa",
            "after": "bbb",
        }

    def test_moved_while_change_id_stood_still(self, state_manager):
        # A rig that HAS recorded a change before, then gets hand-edited: the marker file keeps the
        # old id while the live revision moves. This is the exact shape #1542 leaves open.
        state_manager.note_worker_revision("rig1", _meta("aaa", "c1"))
        assert state_manager.note_worker_revision("rig1", _meta("bbb", "c1")) == {
            "worker": "rig1",
            "before": "aaa",
            "after": "bbb",
        }

    def test_reports_once_then_settles(self, state_manager):
        # The new revision is stored as it is reported, so a rig re-serving it is not a fresh edit
        # every poll. Without this the audit trail would grow a row per poll forever.
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) is None


class TestSilentCases:
    """Every neighbour of the positive case, each of which must NOT produce an accusation."""

    def test_revision_unchanged(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa", "c1"))
        assert state_manager.note_worker_revision("rig1", _meta("aaa", "c1")) is None

    def test_moved_with_a_new_change_id_was_recorded(self, state_manager):
        # Something DID record this one — #185 if we sent it, #530's rig-edit path if the rig
        # applied it locally. Flagging it here would double-report a change already accounted for.
        state_manager.note_worker_revision("rig1", _meta("aaa", "c1"))
        assert state_manager.note_worker_revision("rig1", _meta("bbb", "c2")) is None

    def test_change_id_appearing_for_the_first_time_is_recorded(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert state_manager.note_worker_revision("rig1", _meta("bbb", "c1")) is None

    def test_no_meta_at_all(self, state_manager):
        # A plain-xmrig rig, or one whose block failed validation upstream.
        assert state_manager.note_worker_revision("rig1", None) is None

    def test_meta_without_a_revision(self, state_manager):
        assert state_manager.note_worker_revision("rig1", _meta(None, "c1")) is None

    def test_unnamed_worker(self, state_manager):
        assert state_manager.note_worker_revision("", _meta("aaa")) is None

    def test_workers_do_not_share_a_row(self, state_manager):
        # PRIMARY KEY is the worker, so rig2's first sighting must not read rig1's revision as its
        # own "before" — that would accuse a rig of an edit that happened on a different machine.
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert state_manager.note_worker_revision("rig2", _meta("bbb")) is None


class TestFailsClosed:
    """A store that cannot answer accuses nobody, and does not raise into the poll loop."""

    def test_closed_connection(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager._conn = None
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) is None

    def test_read_error_is_silent_and_leaves_the_row_alone(self, state_manager):
        import sqlite3
        from unittest.mock import MagicMock

        state_manager.note_worker_revision("rig1", _meta("aaa"))

        # sqlite3.Connection's methods are read-only slots, so the error is staged by swapping the
        # handle for a mock rather than patching one method on the real one -- the same technique
        # ``test_storage_worker.py`` uses for its single-batch assertion.
        real_conn = state_manager._conn
        broken = MagicMock()
        broken.cursor.side_effect = sqlite3.OperationalError("database is locked")
        state_manager._conn = broken
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) is None
        state_manager._conn = real_conn

        # The failed poll wrote nothing, so the NEXT one still compares against "aaa" and the edit
        # is delayed rather than lost. That is the difference between failing closed and going blind.
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) == {
            "worker": "rig1",
            "before": "aaa",
            "after": "bbb",
        }


class TestDriftFromIsMaintained:
    """``drift_from`` (#1564): the column that lets Worker Inspect keep reporting the edit.

    Driven through the real store rather than by calling ``_next_drift_from`` with stand-in rows.
    The rule's whole subject is what gets STORED and read back across polls, and a dict stand-in
    would be a different object from the ``sqlite3.Row`` production subscripts — the tier that
    proves this honestly is the one that writes and re-reads.
    """

    def test_the_poll_that_reports_a_drift_records_where_it_came_from(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.get_worker_revision_drift("rig1", "bbb") == {
            "worker": "rig1",
            "before": "aaa",
            "after": "bbb",
        }

    def test_the_note_survives_the_polls_after_the_one_that_raised_it(self, state_manager):
        # The reason the column exists at all. ``note_worker_revision`` reports a drift ONCE, so
        # a line reading its return value would flash for a single poll and then reassure again
        # while the rig is still running the unrecorded config.
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        for _ in range(3):
            state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is not None

    def test_a_move_with_a_new_change_id_clears_it(self, state_manager):
        # The resolved case: we applied over the drift, or the rig recorded its own change. The
        # audit row stays in the Security panel; the Inspect line has nothing left to contradict.
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is not None  # armed
        state_manager.note_worker_revision("rig1", _meta("ccc", "c1"))
        assert state_manager.get_worker_revision_drift("rig1", "ccc") is None

    def test_a_second_drift_names_the_revision_it_moved_from(self, state_manager):
        # Not the original one. "before" is the config the rig was last seen running, which is
        # what an operator comparing against the rig in front of them can act on.
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        state_manager.note_worker_revision("rig1", _meta("ccc"))
        assert state_manager.get_worker_revision_drift("rig1", "ccc")["before"] == "bbb"

    def test_a_first_sighting_records_no_drift(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert state_manager.get_worker_revision_drift("rig1", "aaa") is None

    def test_a_rig_that_never_moved_records_no_drift(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa", "c1"))
        state_manager.note_worker_revision("rig1", _meta("aaa", "c1"))
        assert state_manager.get_worker_revision_drift("rig1", "aaa") is None


class TestTheReadIsGatedOnCurrency:
    """The note describes the config the rig is serving NOW, never its history."""

    def test_it_is_silent_once_the_rig_serves_a_different_revision(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        # The positive control for the assertion below: at the revision the drift produced, this
        # same stored row DOES answer. So the silence that follows is the gate, not an empty row.
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is not None
        assert state_manager.get_worker_revision_drift("rig1", "zzz") is None

    def test_it_says_nothing_when_the_rig_reports_no_revision(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.get_worker_revision_drift("rig1", None) is None

    def test_it_says_nothing_for_an_unnamed_worker(self, state_manager):
        assert state_manager.get_worker_revision_drift("", "bbb") is None

    def test_workers_do_not_share_a_drift(self, state_manager):
        # rig2 has drifted and rig1 has not. A read keyed on anything but the worker would print
        # rig2's accusation over rig1's Inspect line.
        state_manager.note_worker_revision("rig2", _meta("aaa"))
        state_manager.note_worker_revision("rig2", _meta("bbb"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.get_worker_revision_drift("rig2", "bbb") is not None
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is None


class TestTheReadFailsClosed:
    """A store that cannot answer renders no note, rather than one it cannot stand behind."""

    def test_closed_connection(self, state_manager):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is not None  # armed
        state_manager._conn = None
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is None

    def test_read_error(self, state_manager):
        import sqlite3
        from unittest.mock import MagicMock

        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is not None  # armed

        real_conn = state_manager._conn
        broken = MagicMock()
        broken.cursor.side_effect = sqlite3.OperationalError("database is locked")
        state_manager._conn = broken
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is None
        state_manager._conn = real_conn

        # The failed read changed nothing: the row is still there for the next poll to serve.
        assert state_manager.get_worker_revision_drift("rig1", "bbb") is not None
