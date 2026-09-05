"""The lone-surrogate binds on the unauthenticated worker feed (#1696).

A new module for the same reason ``test_worker_revision.py`` is one: ``test_storage_worker.py``,
where these three methods are otherwise tested, sits at its recorded file-budget ceiling (451/451).
The subject is the same store, so the tests-ROOT ``state_manager`` fixture from
``dashboard/tests/conftest.py`` serves here unchanged.

The file is named for a defect CLASS rather than a method because that is what it is: one input
class reaching three separate binds. A rig chooses ``change_id``, its own worker ``name`` and
``reason`` on the enriched read feed; ``json.loads`` hands a lone surrogate back verbatim; sqlite3
encodes a TEXT parameter as strict UTF-8 and raises ``UnicodeEncodeError``. That is a ``ValueError``
and NOT a ``sqlite3.Error``, so it walked through every fail-closed handler in the store and out
through the caller's ``asyncio.to_thread``, aborting the poll step — an unauthenticated LAN device
stopping a step of the poll with one character.

Three binds were swept and left alone, each for a reason rather than by omission:
``revision`` and ``last_change_id`` reach ``note_worker_revision`` only through
``parse_config_meta``, whose ``_TOKEN_RE`` charset a surrogate cannot match; and the two readers
``get_worker_config_change`` and ``get_worker_revision_drift`` take a route-supplied worker name
beside an already-tokenised id. What is NOT swept here is every other table this worker name
reaches outside this store — that is a wider question than this issue.

Every hostile case below is paired with a control, because "did not raise" is the weakest
assertion there is: ``TestTheSurrogateIsGenuinelyHostile`` proves the fixture value really does
break a bind on THIS connection, so a green run here is the guard working rather than a value that
was never dangerous in the first place.
"""

import pytest

from mining_dashboard.service import worker_config_store

# A lone high surrogate: legal inside a JSON string, handed back verbatim by ``json.loads``, and
# refused by every strict UTF-8 encoder — including the one sqlite3 uses on a TEXT parameter.
SURROGATE = "\ud800"


def _meta(revision, last_change_id=None):
    """The fields ``note_worker_revision`` reads, in the shape ``parse_config_meta`` returns."""
    return {
        "revision": revision,
        "last_change_id": last_change_id,
        "changed_at": None,
        "source": None,
    }


class TestTheSurrogateIsGenuinelyHostile:
    """POSITIVE CONTROL for every class below, and the reason they are worth reading.

    An absence assertion is satisfied by any mechanism at all, including the fixture never having
    been dangerous. Both halves are asserted: the value still breaks a real bind on this exact
    connection, and it is TRUTHY — every guarded method here already returns early on a falsy
    argument, so an empty hostile fixture would turn each test below into a test of that branch.
    """

    def test_a_bare_bind_of_it_still_raises(self, state_manager):
        with state_manager._db_lock, pytest.raises(UnicodeEncodeError):
            state_manager._conn.execute("SELECT ?", (SURROGATE,))

    def test_it_is_not_falsy(self):
        assert SURROGATE


class TestChangeIdBind:
    """Site 1 — ``worker_config_change_known``, the bind this issue reports."""

    def test_a_surrogate_change_id_does_not_abort_the_poll(self, state_manager):
        assert state_manager.worker_config_change_known(SURROGATE) is False

    def test_it_answers_false_rather_than_the_fail_open_true(self, state_manager):
        """The DIRECTION is the load-bearing half here, not the absence of the raise.

        This method fails OPEN on a ``sqlite3.Error`` — ``True`` means "this dashboard spooled that
        change", which SUPPRESSES the out-of-band rig-edit audit row. Folding the encode failure
        into that same handler, which is what widening every ``except`` to one tuple would have
        done, hands a rogue rig an opt-out from being audited for the price of one character.

        ``False`` is also the true answer, and this test grounds that claim rather than
        asserting it: ``add_worker_config_version`` is the only writer to ``worker_config``, its
        own bind refuses the same value, and so no non-encodable id has ever been a row here.
        """
        state_manager.add_worker_config_version("rig1", SURROGATE, "accepted", {}, None)
        assert state_manager.get_worker_config_history("rig1") == []
        assert state_manager.worker_config_change_known(SURROGATE) is False

    def test_the_fail_open_direction_still_holds_for_a_db_error(self, state_manager):
        # CONTROL on the narrowing: the #530 behaviour this sits beside must be untouched. A DB
        # hiccup must still not manufacture a false rig-edit report.
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE worker_config")
        assert state_manager.worker_config_change_known("cid-1") is True

    def test_a_clean_change_id_is_unaffected(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid-1", "accepted", {}, None)
        assert state_manager.worker_config_change_known("cid-1") is True


class TestWorkerNameBind:
    """Site 2 — the rig-chosen worker NAME in ``note_worker_revision``.

    Not the path the issue reports and not reachable through ``parse_worker_control_status`` at
    all. ``note_revision_drift`` runs BEFORE the caller's terminal-control-status guard, so this
    bind is reached on every poll of any rig serving a valid ``revision`` — no control block and no
    terminal outcome needed.
    """

    def test_a_surrogate_worker_name_does_not_abort_the_poll(self, state_manager):
        assert state_manager.note_worker_revision(SURROGATE, _meta("aaa")) is None

    def test_it_stays_silent_on_the_move_it_could_not_store(self, state_manager):
        """The disclosed cost, asserted rather than left to a docstring.

        A name we cannot store is one we cannot compare against, so a rig naming itself with a
        surrogate is never checked for drift. That is permanent for as long as it keeps the name,
        and it is NOT the one-poll delay this method's ordinary closed-failure note describes —
        stating it as such would be the milder claim rather than the true one.
        """
        state_manager.note_worker_revision(SURROGATE, _meta("aaa"))
        assert state_manager.note_worker_revision(SURROGATE, _meta("bbb")) is None

    def test_a_clean_name_still_detects_the_same_move(self, state_manager):
        # CONTROL: the identical two-poll sequence under an encodable name. Without it the pair
        # above reads exactly the same against a method that had stopped detecting anything.
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) == {
            "worker": "rig1",
            "before": "aaa",
            "after": "bbb",
        }


class TestReasonBind:
    """Site 3 — ``reason`` in ``reconcile_worker_config_status``, which neither the issue nor its
    recon comment names.

    Reachable only once the rig holds a real ``change_id`` of ours, which it comes by honestly: we
    sent it the change. It can then echo that id back with a terminal status and a lone surrogate
    in the free-prose ``reason``, and the bind is the same abort as site 1.
    """

    def _seed(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid-1", "accepted", {}, None)

    def _row(self, state_manager):
        rows = state_manager.get_worker_config_history("rig1")
        assert len(rows) == 1
        return rows[0]

    def test_a_surrogate_reason_does_not_abort_the_poll(self, state_manager):
        self._seed(state_manager)
        state_manager.reconcile_worker_config_status("cid-1", "applied", SURROGATE)
        assert self._row(state_manager)["status"] == "applied"

    def test_the_prose_is_dropped_and_the_outcome_is_not(self, state_manager):
        """The direction this site turns on, and it is not the same one as site 1.

        ``reason`` is display prose beside the outcome; ``status`` is the terminal outcome the
        reconciler exists to catch up. Refusing the whole call over the prose would strand the row
        on ``accepted`` for as long as the rig kept resending it — the exact state #579 was written
        to clear, reintroduced by the fix for a different defect.
        """
        self._seed(state_manager)
        state_manager.reconcile_worker_config_status("cid-1", "applied", SURROGATE)
        assert self._row(state_manager)["reason"] is None

    def test_a_clean_reason_is_still_recorded_verbatim(self, state_manager):
        # CONTROL: the drop is specific to the value sqlite refuses, not a reason field that quietly
        # stopped being written at all.
        self._seed(state_manager)
        state_manager.reconcile_worker_config_status("cid-1", "applied", "rig said so")
        assert self._row(state_manager)["reason"] == "rig said so"

    def test_a_surrogate_change_id_reconciles_nothing_and_does_not_raise(self, state_manager):
        # The other field on this call, in its own direction: an id nothing could have written
        # matches no row, so the seeded row stays exactly as it was.
        self._seed(state_manager)
        state_manager.reconcile_worker_config_status(SURROGATE, "applied", None)
        assert self._row(state_manager)["status"] == "accepted"


class TestTheBindablePredicate:
    """``_bindable`` itself — the one place the three sites share, so its own edges are worth
    holding rather than inferring from the three callers above."""

    def test_a_plain_string_is_bindable(self):
        assert worker_config_store._bindable("cid-1") is True

    def test_a_lone_surrogate_is_not(self):
        assert worker_config_store._bindable(SURROGATE) is False

    def test_non_strings_are_left_to_the_bind_itself(self):
        # ``reason`` is optional and ``change_id`` can arrive as None. The predicate answers about
        # the strings it is handed and takes no position on any other type.
        assert worker_config_store._bindable(None, 7, b"bytes") is True

    def test_one_bad_value_among_good_ones_is_still_caught(self):
        # The verdict accumulates rather than returning from inside the handler, so this is the
        # shape that would break first: a later clean value must not overwrite an earlier refusal.
        assert worker_config_store._bindable("cid-1", SURROGATE, "rig1") is False
        assert worker_config_store._bindable(SURROGATE, "cid-1") is False

    def test_no_argument_at_all_is_bindable(self):
        assert worker_config_store._bindable() is True
