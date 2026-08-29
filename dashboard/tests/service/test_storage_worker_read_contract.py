"""The return contract of ``StateManager.get_worker_config_history`` (#1409).

A new module rather than three more tests in ``test_storage_worker.py``: that file is 378 lines and
#1105 Phase 3 D6 cut it specifically to land under the 400-line budget target, so growing it by a
third of a class would buy it back a ceiling row three days after the split removed one.

What is being pinned here is one distinction, and only that: **None means the read FAILED; ``[]``
means the rig genuinely has no recorded changes.** Before #1409 both failure paths returned ``[]``,
which is indistinguishable from an empty history to every caller — so ``build_worker_detail`` read
"we hold no row for the rig's last change id" off a list that was empty because the read never ran,
and rendered the accusation "Last changed from another dashboard" over it.

Separating the two return values is what makes that answerable AT ALL; it is not itself the fix.
The verdict this feeds is tested in ``tests/client/test_rig_config_meta.py`` (the decision) and
``tests/web/test_worker_detail_meta.py`` (what the operator actually reads).
"""


class TestWorkerConfigHistoryReadFailure:
    def test_a_db_error_returns_none_not_an_empty_list(self, state_manager):
        # The `except sqlite3.Error` arm, made to raise for real rather than through a mocked
        # handler — this is the path an operator with a corrupt or migrating DB actually hits.
        state_manager.add_worker_config_version("rig1", "cid-1", "applied", {"DONATION": 5}, None)
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE worker_config")
        assert state_manager.get_worker_config_history("rig1") is None

    def test_no_connection_returns_none_not_an_empty_list(self, state_manager):
        # The other failure path, and the quieter one: `if not self._conn` raises nothing and logs
        # nothing, so it is invisible even to someone looking. The two are not equally observable,
        # which is most of why this was hard to see — and a test covering only the arm above goes
        # green against a fix to only the loud half.
        conn, state_manager._conn = state_manager._conn, None
        try:
            assert state_manager.get_worker_config_history("rig1") is None
        finally:
            state_manager._conn = conn

    def test_a_rig_with_no_recorded_changes_still_returns_an_empty_list(self, state_manager):
        # The REVERSE direction, and the reason this class is not one test. Make the method return
        # None whenever it has nothing to hand back and every assertion above still passes, while
        # "we could not read" and "there is nothing to read" collapse into one answer again — the
        # original defect, restored by way of its own fix.
        out = state_manager.get_worker_config_history("rig-never-touched")
        assert out == []
        assert out is not None
