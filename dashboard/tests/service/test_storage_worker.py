"""The worker_config and worker_history tables in the StateManager store (#1105 Phase 3,
cut D6).

These five classes and one module-level test moved 1:1 and byte-identical out of
``tests/service/test_storage_service.py``, which remains the master module for the core tables.
Nothing was edited in the move: the subject module ``mining_dashboard/service/storage_service.py``
is NOT split, so no name is repointed.

``TestWorkerHashrateByConfig`` is one of the file's cross-table classes -- it bridges
``worker_config`` and ``worker_history``.  Both tables are in this module, so the bridge is not
split across the cut.

Unlike the D2-D5 cuts there is no duplicated fixture block here.  ``state_manager`` and the autouse
``_isolate_db`` are defined in ``dashboard/tests/conftest.py`` -- the tests-ROOT conftest -- which
every module under ``dashboard/tests/`` inherits, so the standing duplicate-the-builders ruling
costs this cut nothing but its import block.
"""

import time
from unittest.mock import MagicMock

from mining_dashboard.config.config import HISTORY_RETENTION_SEC
from mining_dashboard.service import storage_service


class TestWorkerHistory:
    """Per-rig hashrate/share history (#196 Wave-0): 30-day retention, batched executemany write."""

    def test_add_and_get_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_worker_history(
            [
                {"ts": t0, "name": "rig1", "h15": 1000.0, "accepted": 10, "rejected": 1},
                {"ts": t0, "name": "rig2", "h15": 2000.0, "accepted": 20, "rejected": 0},
            ]
        )
        rows = state_manager.get_worker_history()
        assert {r["name"] for r in rows} == {"rig1", "rig2"}
        assert len(rows) == 2

    def test_add_is_a_single_batch_call(self, state_manager, monkeypatch):
        # Intent: one poll's worker rows land via ONE executemany, not N execute() calls per row.
        # sqlite3.Connection's methods are read-only slots (can't monkeypatch the real instance),
        # so swap in a MagicMock connection for this one narrow assertion.
        mock_conn = MagicMock()
        monkeypatch.setattr(state_manager, "_conn", mock_conn)
        t0 = time.time()
        state_manager.add_worker_history(
            [
                {"ts": t0, "name": "rig1", "h15": 1.0, "accepted": 1, "rejected": 0},
                {"ts": t0, "name": "rig2", "h15": 2.0, "accepted": 2, "rejected": 0},
                {"ts": t0, "name": "rig3", "h15": 3.0, "accepted": 3, "rejected": 0},
            ]
        )
        assert mock_conn.executemany.call_count == 1
        values = mock_conn.executemany.call_args.args[1]
        assert len(values) == 3

    def test_get_since_filters_the_window(self, state_manager):
        t0 = time.time()
        state_manager.add_worker_history(
            [{"ts": t0 - 1000, "name": "rig1", "h15": 1.0, "accepted": 0, "rejected": 0}]
        )
        state_manager.add_worker_history(
            [{"ts": t0, "name": "rig1", "h15": 2.0, "accepted": 0, "rejected": 0}]
        )
        rows = state_manager.get_worker_history(since=t0 - 10)
        assert [r["h15"] for r in rows] == [2.0]

    def test_empty_batch_is_a_noop(self, state_manager):
        state_manager.add_worker_history([])
        assert state_manager.get_worker_history() == []

    def test_old_rows_pruned_from_db_when_cleanup_fires(self, state_manager, monkeypatch):
        old_ts = time.time() - HISTORY_RETENTION_SEC - 10 * 24 * 3600  # 40 days ago
        with state_manager._db_lock:
            state_manager._conn.execute(
                "INSERT INTO worker_history (ts, name, h15, accepted, rejected) VALUES (?,?,?,?,?)",
                (old_ts, "rig1", 1.0, 0, 0),
            )
            state_manager._conn.commit()
        monkeypatch.setattr("mining_dashboard.service.storage_service.random.random", lambda: 0.0)
        state_manager.add_worker_history(
            [{"ts": time.time(), "name": "rig1", "h15": 2.0, "accepted": 0, "rejected": 0}]
        )
        with state_manager._db_lock:
            remaining = state_manager._conn.execute(
                "SELECT COUNT(*) FROM worker_history WHERE ts < ?",
                (time.time() - HISTORY_RETENTION_SEC,),
            ).fetchone()[0]
        assert remaining == 0

    def test_write_error_flags_table_and_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE worker_history")
        state_manager.add_worker_history(
            [{"ts": time.time(), "name": "rig1", "h15": 1.0, "accepted": 0, "rejected": 0}]
        )
        assert state_manager.is_db_healthy() is False
        assert state_manager.get_table_health()["worker_history"]["healthy"] is False

    def test_reads_tolerate_a_missing_table(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE worker_history")
        assert state_manager.get_worker_history() == []

    def test_get_name_filters_to_one_rig(self, state_manager):
        t0 = time.time()
        state_manager.add_worker_history(
            [
                {"ts": t0, "name": "rig1", "h15": 1.0, "accepted": 0, "rejected": 0},
                {"ts": t0, "name": "rig2", "h15": 2.0, "accepted": 0, "rejected": 0},
            ]
        )
        rows = state_manager.get_worker_history(name="rig1")
        assert [r["name"] for r in rows] == ["rig1"]


class TestWorkerHashrateByConfig:
    """Correlates worker_history samples to the worker_config version active at each sample's
    ts (#492, rides #185's config timeline + #196's hashrate series)."""

    def test_no_applied_versions_returns_empty(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid1", "rejected", {"a": 1}, "bad", ts=100)
        assert state_manager.get_worker_hashrate_by_config("rig1") == []

    def test_samples_bucketed_by_version_boundary(self, state_manager):
        # v1 applied at t=100, v2 applied at t=200. Samples before t=100 have no known version and
        # are dropped; samples in [100, 200) belong to v1, samples >= 200 belong to v2.
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_config_version("rig1", "cid2", "applied", {"a": 2}, None, ts=200)
        state_manager.add_worker_history(
            [{"ts": 50, "name": "rig1", "h15": 999.0, "accepted": 0, "rejected": 0}]
        )
        state_manager.add_worker_history(
            [{"ts": 120, "name": "rig1", "h15": 1000.0, "accepted": 0, "rejected": 0}]
        )
        state_manager.add_worker_history(
            [{"ts": 180, "name": "rig1", "h15": 2000.0, "accepted": 0, "rejected": 0}]
        )
        state_manager.add_worker_history(
            [{"ts": 250, "name": "rig1", "h15": 4000.0, "accepted": 0, "rejected": 0}]
        )
        rows = state_manager.get_worker_hashrate_by_config("rig1")
        # Newest first, matching get_worker_config_history.
        assert [r["change_id"] for r in rows] == ["cid2", "cid1"]
        v2, v1 = rows
        assert v1["sample_count"] == 2
        assert v1["avg_h15"] == 1500.0
        assert v1["min_h15"] == 1000.0
        assert v1["max_h15"] == 2000.0
        assert v2["sample_count"] == 1
        assert v2["avg_h15"] == 4000.0

    def test_version_with_no_samples_yet_has_none_aggregates(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_history(
            [{"ts": 150, "name": "rig1", "h15": 1000.0, "accepted": 0, "rejected": 0}]
        )
        state_manager.add_worker_config_version("rig1", "cid2", "applied", {"a": 2}, None, ts=200)
        rows = state_manager.get_worker_hashrate_by_config("rig1")
        newest = rows[0]
        assert newest["change_id"] == "cid2"
        assert newest["sample_count"] == 0
        assert newest["avg_h15"] is None
        assert newest["min_h15"] is None
        assert newest["max_h15"] is None

    def test_non_applied_versions_are_not_boundaries(self, state_manager):
        # A rejected/failed change never became the active config, so it must not split a segment.
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_config_version("rig1", "cid2", "rejected", {"a": 2}, "bad", ts=150)
        state_manager.add_worker_history(
            [{"ts": 175, "name": "rig1", "h15": 5000.0, "accepted": 0, "rejected": 0}]
        )
        rows = state_manager.get_worker_hashrate_by_config("rig1")
        assert len(rows) == 1
        assert rows[0]["change_id"] == "cid1"
        assert rows[0]["sample_count"] == 1

    def test_applied_upgrade_is_also_a_boundary(self, state_manager):
        # #1014: hashrate_by_config must split on an applied rig upgrade the same way it splits on
        # an applied config change — otherwise a version change misattributes the build's effect.
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_config_version(
            "rig1", "cid2", "applied", {"version": "v1.12.0"}, None, ts=200, change_type="upgrade"
        )
        state_manager.add_worker_history(
            [{"ts": 150, "name": "rig1", "h15": 1000.0, "accepted": 0, "rejected": 0}]
        )
        state_manager.add_worker_history(
            [{"ts": 250, "name": "rig1", "h15": 5000.0, "accepted": 0, "rejected": 0}]
        )
        rows = state_manager.get_worker_hashrate_by_config("rig1")
        assert [r["change_id"] for r in rows] == ["cid2", "cid1"]
        assert (
            rows[0]["avg_h15"] == 5000.0
        )  # post-upgrade sample bucketed into the upgrade's window
        assert rows[1]["avg_h15"] == 1000.0  # pre-upgrade sample stays with the config version

    def test_other_workers_hashrate_is_excluded(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_history(
            [
                {"ts": 150, "name": "rig1", "h15": 1000.0, "accepted": 0, "rejected": 0},
                {"ts": 150, "name": "rig2", "h15": 9999.0, "accepted": 0, "rejected": 0},
            ]
        )
        rows = state_manager.get_worker_hashrate_by_config("rig1")
        assert rows[0]["sample_count"] == 1
        assert rows[0]["avg_h15"] == 1000.0

    def test_since_bounds_the_samples_but_not_the_version_timeline(self, state_manager):
        # A version applied before `since` can still be the active version for samples inside the
        # window — `since` only filters which SAMPLES are read, not which versions exist.
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_history(
            [{"ts": 120, "name": "rig1", "h15": 1000.0, "accepted": 0, "rejected": 0}]
        )
        state_manager.add_worker_history(
            [{"ts": 500, "name": "rig1", "h15": 3000.0, "accepted": 0, "rejected": 0}]
        )
        rows = state_manager.get_worker_hashrate_by_config("rig1", since=400)
        assert rows[0]["change_id"] == "cid1"
        assert rows[0]["sample_count"] == 1
        assert rows[0]["avg_h15"] == 3000.0


class TestWorkerConfigReconcile:
    """Reconcile a stuck-'accepted' #185 history row to its now-known terminal outcome (#579): a
    rig rollback slower than the host runner's 20s status-poll deadline (#517/#543) is honestly
    recorded 'accepted' and never revisited otherwise."""

    def _seed(self, state_manager, status, change_id="cid-1", worker="rig1"):
        state_manager.add_worker_config_version(worker, change_id, status, {"max_temp_c": 80}, None)

    def _status_of(self, state_manager, worker="rig1", change_id="cid-1"):
        rows = [
            r
            for r in state_manager.get_worker_config_history(worker)
            if r["change_id"] == change_id
        ]
        assert len(rows) == 1
        return rows[0]

    def test_accepted_row_becomes_terminal(self, state_manager):
        self._seed(state_manager, "accepted")
        state_manager.reconcile_worker_config_status(
            "cid-1", "rolled_back", "miner did not return to a live hashrate"
        )
        row = self._status_of(state_manager)
        assert row["status"] == "rolled_back"
        assert row["reason"] == "miner did not return to a live hashrate"

    def test_accepted_row_becomes_terminal_for_the_1009_vocabulary(self, state_manager):
        # #1009: failed/noop/throttled — the rigforge#320 members #579's original three-status
        # allowlist dropped — must reconcile an accepted row exactly like applied/rejected/
        # rolled_back always have.
        for status in ("failed", "noop", "throttled"):
            self._seed(state_manager, "accepted", change_id=f"cid-{status}")
            state_manager.reconcile_worker_config_status(f"cid-{status}", status, "rig-supplied")
            row = self._status_of(state_manager, change_id=f"cid-{status}")
            assert row["status"] == status
            assert row["reason"] == "rig-supplied"

    def test_applied_row_is_never_overwritten(self, state_manager):
        # A genuinely terminal row must survive even a (stale/duplicate) reconcile report.
        self._seed(state_manager, "applied")
        state_manager.reconcile_worker_config_status("cid-1", "rolled_back", "late report")
        row = self._status_of(state_manager)
        assert row["status"] == "applied"
        assert row["reason"] is None

    def test_rolled_back_row_is_never_overwritten(self, state_manager):
        self._seed(state_manager, "rolled_back")
        state_manager.reconcile_worker_config_status("cid-1", "applied", "late report")
        assert self._status_of(state_manager)["status"] == "rolled_back"

    def test_rejected_row_is_never_overwritten(self, state_manager):
        self._seed(state_manager, "rejected")
        state_manager.reconcile_worker_config_status("cid-1", "applied", "late report")
        assert self._status_of(state_manager)["status"] == "rejected"

    def test_unknown_change_id_is_a_noop(self, state_manager):
        self._seed(state_manager, "accepted")
        state_manager.reconcile_worker_config_status("no-such-id", "rolled_back")
        assert self._status_of(state_manager)["status"] == "accepted"

    def test_non_terminal_status_is_a_noop(self, state_manager):
        # A defensive guard: reconcile() is only ever called with a terminal status by
        # parse_worker_control_status, but a bad caller must not be able to write 'accepted',
        # 'running', or 'started' (rigforge#320's in-flight upgrade marker) back over itself.
        self._seed(state_manager, "accepted")
        state_manager.reconcile_worker_config_status("cid-1", "running")
        state_manager.reconcile_worker_config_status("cid-1", "accepted")
        state_manager.reconcile_worker_config_status("cid-1", "started")
        assert self._status_of(state_manager)["status"] == "accepted"

    def test_write_error_flags_db_unhealthy(self, state_manager):
        self._seed(state_manager, "accepted")
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE worker_config")
        state_manager.reconcile_worker_config_status("cid-1", "rolled_back")
        assert state_manager.is_db_healthy() is False

    def test_reads_and_writes_after_close_are_safe(self, state_manager):
        state_manager.close()
        state_manager.reconcile_worker_config_status("cid-1", "rolled_back")  # must not raise


class TestWorkerConfigChangeKnown:
    """#530: whether a change_id was ever spooled by THIS dashboard — the rig-edit detector's
    only question. Only ``add_worker_config_version`` (the dashboard's own worker-apply write)
    ever populates ``worker_config``, so an unknown change_id means the RIG applied it."""

    def test_known_change_id_is_true(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid-1", "accepted", {}, None)
        assert state_manager.worker_config_change_known("cid-1") is True

    def test_unknown_change_id_is_false(self, state_manager):
        assert state_manager.worker_config_change_known("no-such-id") is False

    def test_empty_change_id_is_false(self, state_manager):
        assert state_manager.worker_config_change_known("") is False
        assert state_manager.worker_config_change_known(None) is False

    def test_after_close_is_false(self, state_manager):
        state_manager.close()
        assert state_manager.worker_config_change_known("cid-1") is False

    def test_lookup_error_fails_open_true(self, state_manager):
        # A DB hiccup during the lookup must not manufacture a false rig-edit report — fail toward
        # treating the change_id as known (quiet), not toward flagging it.
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE worker_config")
        assert state_manager.worker_config_change_known("cid-1") is True


class TestWorkerConfigType:
    """worker_config.type (#1014) distinguishes a config apply from a one-click rig upgrade so
    the change history can show it and hashrate_by_config can attribute a build change correctly."""

    def test_default_type_is_apply(self, state_manager):
        # An ordinary worker-apply call never passes change_type — must default to 'apply', not
        # blank/None, so get_last_applied_worker_config's type check keeps working unmodified.
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"DONATION": 2}, None)
        assert state_manager.get_worker_config_history("rig1")[0]["type"] == "apply"

    def test_upgrade_type_round_trips(self, state_manager):
        state_manager.add_worker_config_version(
            "rig1", "cid1", "applied", {"version": "v1.12.0"}, None, change_type="upgrade"
        )
        row = state_manager.get_worker_config_history("rig1")[0]
        assert row["type"] == "upgrade"
        assert row["changes"] == {"version": "v1.12.0"}

    def test_last_applied_config_excludes_upgrade_rows(self, state_manager):
        # An applied upgrade's changes = {"version": ...} must never leak into the editor prefill
        # (it isn't a writable config key at all) — only 'apply'-type applied rows merge.
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"DONATION": 2}, None)
        state_manager.add_worker_config_version(
            "rig1", "cid2", "applied", {"version": "v1.12.0"}, None, change_type="upgrade"
        )
        assert state_manager.get_last_applied_worker_config("rig1") == {"DONATION": 2}


def test_reconcile_terminal_matches_the_parser_verbatim():
    """The reconciler's allowlist and the feed parser's must never drift apart.

    They are deliberately declared separately (the parser lives with the client, the allowlist
    with the store, and neither should import the other for a six-string tuple) — so this is the
    thing that keeps the two honest: a status the parser hands over must be one the store will
    act on, or a terminal outcome silently stops reconciling and history rows freeze at accepted,
    which is the exact bug this pair was widened to fix.
    """
    from mining_dashboard.client.xmrig_client import _CONTROL_TERMINAL

    assert storage_service._RECONCILE_TERMINAL == _CONTROL_TERMINAL
