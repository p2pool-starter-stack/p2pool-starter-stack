"""Schema migration, crash recovery and retention pruning for the StateManager store
(#1105 Phase 3, cut D6).

These four classes moved 1:1 and byte-identical out of ``tests/service/test_storage_service.py``,
which remains the master module for the core tables.  Nothing was edited in the move: the subject
module ``mining_dashboard/service/storage_service.py`` is NOT split, so no name is repointed.

Unlike the D2-D5 cuts there is no duplicated fixture block here.  ``state_manager`` and the autouse
``_isolate_db`` are defined in ``dashboard/tests/conftest.py`` -- the tests-ROOT conftest -- which
every module under ``dashboard/tests/`` inherits, so the standing duplicate-the-builders ruling
costs this cut nothing but its import block.
"""

import sqlite3
import time
from unittest.mock import MagicMock

from mining_dashboard.config.config import HISTORY_RETENTION_SEC
from mining_dashboard.service.storage_service import StateManager


class TestDbRecovery:
    """Corrupt-DB auto-heal (#489): a malformed DB is quarantined and rebuilt fresh instead of
    erroring on every write forever. Recovery is loud (db_reset_count) but non-fatal."""

    def _corrupt(self, path):
        # Not a SQLite file — connect() opens it lazily, but integrity_check / the first pragma
        # raises "file is not a database". This is what a truncated/overwritten DB looks like.
        with open(path, "wb") as f:
            f.write(b"this is not a sqlite database, it is garbage" * 8)

    def test_corrupt_db_at_startup_is_quarantined_and_rebuilt(self, tmp_path):
        db = str(tmp_path / "mining.db")
        self._corrupt(db)
        sm = StateManager(db_path=db)
        try:
            assert sm.db_reset_count == 1
            assert sm.last_db_reset is not None
            quarantine = sm.last_db_reset["quarantine"]
            assert quarantine and quarantine.endswith(tuple("0123456789Z"))
            import os

            assert os.path.exists(quarantine)  # bad file kept for post-mortem
            assert sm.is_db_healthy() is True  # fresh DB is writable
            # The fresh schema works: a write round-trips.
            sm.update_history(1000, p2pool_hr=5, xvb_hr=0)
            assert sm.get_history()[-1]["v_p2pool"] == 5
        finally:
            sm.close()

    def test_runtime_corruption_error_triggers_recovery(self):
        # A malformed error surfacing on a write at runtime routes through _db_error into recovery,
        # so the dashboard self-heals mid-run instead of erroring every cycle. :memory: has no file
        # to quarantine — it just rebuilds and keeps going.
        sm = StateManager(db_path=":memory:")
        try:
            sm._db_error(
                "History Update Error",
                sqlite3.DatabaseError("database disk image is malformed"),
            )
            assert sm.db_reset_count == 1
            assert sm.last_db_reset["quarantine"] is None
            assert sm.is_db_healthy() is True
            sm.update_history(500, p2pool_hr=3, xvb_hr=0)  # fresh in-memory DB is writable
            assert sm.get_history()[-1]["v_p2pool"] == 3
        finally:
            sm.close()

    def test_good_db_is_untouched(self, tmp_path):
        db = str(tmp_path / "ok.db")
        sm = StateManager(db_path=db)
        sm.close()
        sm2 = StateManager(db_path=db)  # reopen a healthy DB
        try:
            assert sm2.db_reset_count == 0
            assert sm2.last_db_reset is None
        finally:
            sm2.close()

    def test_corruption_error_classified_transient_is_not(self, state_manager):
        assert state_manager._is_corruption_error(
            sqlite3.DatabaseError("database disk image is malformed")
        )
        assert state_manager._is_corruption_error(sqlite3.DatabaseError("file is not a database"))
        # A retryable failure (locked, disk full) must NOT trigger a reset — that would throw away
        # history over a transient hiccup.
        assert not state_manager._is_corruption_error(
            sqlite3.OperationalError("database is locked")
        )

    def test_transient_write_error_flags_unhealthy_without_reset(self, state_manager):
        state_manager._db_error("History Update Error", sqlite3.OperationalError("disk I/O error"))
        assert state_manager.is_db_healthy() is False
        assert state_manager.db_reset_count == 0  # no reset for a transient error
        # #490: a transient blip must never read as "unrecoverable" — that's the narrow signal
        # dashboard.fail_closed gates the miner hold on, and this is exactly the false positive
        # it must not trip on.
        assert state_manager.is_db_unrecoverable() is False

    def test_recovery_failure_marks_unrecoverable(self, monkeypatch):
        # #490: the auto-heal REBUILD itself failing (disk full, permissions) is the narrow
        # "unrecoverable" signal — distinct from db_healthy, which also flips false on an
        # ordinary transient write error that must never gate the miner.
        sm = StateManager(db_path=":memory:")
        try:
            monkeypatch.setattr(
                sm, "_apply_schema", MagicMock(side_effect=sqlite3.OperationalError("disk full"))
            )
            sm._recover_corrupt_db("test: forced recovery failure")
            assert sm.is_db_unrecoverable() is True
            assert sm.is_db_healthy() is False
        finally:
            sm.close()

    def test_successful_recovery_clears_unrecoverable_flag(self):
        # A later recovery attempt that succeeds (e.g. the disk freed up) clears an earlier
        # failure — fail_closed's hold must release once the DB is actually healthy again.
        sm = StateManager(db_path=":memory:")
        try:
            sm.db_unrecoverable = True  # simulate a prior failed attempt
            sm._recover_corrupt_db("test: retry succeeds")
            assert sm.is_db_unrecoverable() is False
            assert sm.is_db_healthy() is True
        finally:
            sm.close()

    def test_prune_keeps_only_recent_quarantines(self, tmp_path):
        import os

        db = str(tmp_path / "m.db")
        sm = StateManager(db_path=db)
        try:
            for stamp in (
                "20260101T000000Z",
                "20260102T000000Z",
                "20260103T000000Z",
                "20260104T000000Z",
            ):
                open(f"{db}.corrupt-{stamp}", "w").close()
            sm._prune_quarantined()
            kept = sorted(f for f in os.listdir(tmp_path) if ".corrupt-" in f)
            assert len(kept) == 3  # oldest pruned, newest 3 kept
            assert "m.db.corrupt-20260101T000000Z" not in kept
        finally:
            sm.close()


class TestPersistenceAndMigration:
    def test_state_persists_across_instances(self, tmp_path):
        db = str(tmp_path / "state.db")
        sm1 = StateManager(db_path=db)
        sm1.update_xvb_stats(mode="XVB", avg_1h=777.0)
        sm1.add_share(time.time(), 100)
        sm1.close()

        sm2 = StateManager(db_path=db)  # triggers load() from disk
        assert sm2.get_xvb_stats()["avg_1h"] == 777.0
        assert len(sm2.get_shares()) == 1
        sm2.close()

    def test_legacy_kv_keys_migrated_on_load(self, tmp_path):
        db = str(tmp_path / "legacy.db")
        sm = StateManager(db_path=db)
        # Inject legacy-named keys directly, then reload.
        with sm._conn:
            sm._conn.executemany(
                "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)",
                [("xvb_1h_avg", "123.0"), ("xvb_24h_avg", "456.0")],
            )
        sm.load()
        xvb = sm.get_xvb_stats()
        assert xvb["avg_1h"] == 123.0
        assert xvb["avg_24h"] == 456.0
        sm.close()

    def test_corrupted_kv_value_skipped(self, tmp_path):
        db = str(tmp_path / "corrupt.db")
        sm = StateManager(db_path=db)
        with sm._conn:
            sm._conn.execute(
                "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)",
                ("xvb_avg_1h", "not-a-number"),
            )
        sm.load()  # must not raise
        assert sm.get_xvb_stats()["avg_1h"] == 0.0  # falls back to default
        sm.close()


class TestSchemaMigration:
    """The upgrade path: opening a DB created by an older version must migrate in place
    without losing data. These exercise branches a fresh DB never hits."""

    def test_history_timestamp_backfilled_from_iso_on_upgrade(self, tmp_path):
        # Intent: a pre-timestamp history table (only the original t/v columns) must gain the
        # v_p2pool/v_xvb/timestamp columns AND have timestamp backfilled from the ISO `t`
        # string — otherwise old points become undatable and drop out of the chart/retention.
        db = str(tmp_path / "old_schema.db")
        # Recent UTC ISO strings (SQLite's strftime('%s', t) treats t as UTC) so the migrated
        # rows fall inside load()'s 30-day retention window and aren't filtered out.
        now = time.time()
        t1 = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now - 7200))  # 2h ago
        t2 = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now - 3600))  # 1h ago
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE history (t TEXT, v REAL)")  # the original schema
        conn.execute("INSERT INTO history (t, v) VALUES (?, ?)", (t1, 1000.0))
        conn.execute("INSERT INTO history (t, v) VALUES (?, ?)", (t2, 1100.0))
        conn.commit()
        conn.close()

        sm = StateManager(db_path=db)  # __init__ runs _create_tables (no-op) + _migrate_db
        try:
            hist = sm.get_history()
            assert len(hist) == 2
            assert all(h["timestamp"] > 0 for h in hist), "timestamp backfilled from ISO t"
            # ordering preserved: the earlier ISO time sorts first (load() orders by timestamp)
            assert hist[0]["timestamp"] < hist[1]["timestamp"]
            # the new split-rate columns default to 0, not NULL
            assert hist[0]["v_p2pool"] == 0 and hist[0]["v_xvb"] == 0
            # and the #168 per-window columns are present + default 0 on migrated rows
            assert hist[0]["v_p2pool_1h"] == 0 and hist[0]["v_xvb_24h"] == 0
        finally:
            sm.close()

    def test_per_window_columns_added_on_upgrade(self, tmp_path):
        # Intent (#168): a DB at the previous schema (t/v/v_p2pool/v_xvb/timestamp, no per-window
        # columns) gains the per-window columns in place; existing rows read 0 there (capture is
        # forward-only) while their original 10m split is preserved untouched.
        db = str(tmp_path / "pre_168.db")
        now = time.time()
        t1 = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now - 3600))
        conn = sqlite3.connect(db)
        conn.execute(
            "CREATE TABLE history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL)"
        )
        conn.execute(
            "INSERT INTO history VALUES (?, ?, ?, ?, ?)", (t1, 800.0, 800.0, 0.0, now - 3600)
        )
        conn.commit()
        conn.close()

        sm = StateManager(db_path=db)
        try:
            cols = {info[1] for info in sm._conn.execute("PRAGMA table_info(history)").fetchall()}
            for c in (
                "v_p2pool_1m",
                "v_xvb_1m",
                "v_p2pool_1h",
                "v_xvb_1h",
                "v_p2pool_12h",
                "v_xvb_12h",
                "v_p2pool_24h",
                "v_xvb_24h",
            ):
                assert c in cols, f"migration missing {c}"
            old = sm.get_history()[-1]
            assert old["v_p2pool"] == 800.0  # original 10m split preserved
            assert old["v_p2pool_1h"] == 0  # forward-only: no per-window data pre-#168
            # a new write after the upgrade fills the per-window columns
            sm.update_history(900, p2pool_hr=900, xvb_hr=0, windows={"1h": (950, 0)})
            assert sm.get_history()[-1]["v_p2pool_1h"] == 950
        finally:
            sm.close()

    def test_orphaned_workers_table_dropped_on_upgrade(self, tmp_path):
        # Intent (#144): the dead known_workers persistence layer was removed, so opening a DB
        # that still has its orphaned `workers` table drops it in place — tidying old installs
        # without touching history/shares/kv. The worker list is now sourced live from the
        # xmrig-proxy, never from the DB. Also asserts the in-memory state key is gone.
        db = str(tmp_path / "with_workers.db")
        conn = sqlite3.connect(db)
        conn.execute(
            "CREATE TABLE history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL)"
        )
        conn.execute("CREATE TABLE workers (name TEXT PRIMARY KEY, ip TEXT, last_seen REAL)")
        conn.execute("INSERT INTO workers VALUES (?, ?, ?)", ("rig1", "10.0.0.1", 123.0))
        conn.commit()
        conn.close()

        sm = StateManager(db_path=db)  # __init__ runs _migrate_db -> DROP TABLE IF EXISTS workers
        try:
            tables = {
                r[0]
                for r in sm._conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
            assert "workers" not in tables, "orphaned workers table dropped (#144)"
            assert "known_workers" not in sm.state, "dead known_workers state key removed (#144)"
            assert {"history", "kv_store", "shares"} <= tables, "core tables left intact"
        finally:
            sm.close()

    def test_worker_config_type_column_added_on_upgrade(self, tmp_path):
        # Intent (#1014): a pre-`type` worker_config table (the #185 original schema) gains the
        # column in place, and an existing row — necessarily a config apply, since rig upgrades
        # were never recorded before this — reads back type='apply', not NULL/blank.
        db = str(tmp_path / "pre_1014.db")
        conn = sqlite3.connect(db)
        conn.execute(
            "CREATE TABLE worker_config (id INTEGER PRIMARY KEY AUTOINCREMENT, worker TEXT, "
            "change_id TEXT, ts REAL, status TEXT, changes TEXT, reason TEXT)"
        )
        conn.execute(
            "INSERT INTO worker_config (worker, change_id, ts, status, changes, reason) "
            "VALUES ('rig1', 'cid1', 100.0, 'applied', '{}', NULL)"
        )
        conn.commit()
        conn.close()

        sm = StateManager(db_path=db)
        try:
            cols = {
                info[1] for info in sm._conn.execute("PRAGMA table_info(worker_config)").fetchall()
            }
            assert "type" in cols
            history = sm.get_worker_config_history("rig1")
            assert len(history) == 1
            assert history[0]["type"] == "apply"
        finally:
            sm.close()

    def test_worker_config_revision_drift_from_added_on_upgrade(self, tmp_path):
        # Intent (#1564): worker_config_revision is CREATE TABLE IF NOT EXISTS, so an install that
        # has been running since #1551 keeps its pre-drift_from table forever and the Inspect note
        # would be silently absent on exactly the rigs with the most history to have drifted.
        db = str(tmp_path / "pre_1564.db")
        conn = sqlite3.connect(db)
        conn.execute(
            "CREATE TABLE worker_config_revision "
            "(worker TEXT PRIMARY KEY, revision TEXT, last_change_id TEXT, ts REAL)"
        )
        conn.execute(
            "INSERT INTO worker_config_revision (worker, revision, last_change_id, ts) "
            "VALUES ('rig1', 'aaa', NULL, 100.0)"
        )
        conn.commit()
        conn.close()

        sm = StateManager(db_path=db)
        try:
            info = sm._conn.execute("PRAGMA table_info(worker_config_revision)").fetchall()
            assert "drift_from" in {c[1] for c in info}
            # The backfilled NULL accuses nobody, and the row it carried is still the one the next
            # poll compares against — an upgrade must not read as a first sighting.
            assert sm.get_worker_revision_drift("rig1", "aaa") is None
            assert sm.note_worker_revision("rig1", {"revision": "bbb"}) == {
                "worker": "rig1",
                "before": "aaa",
                "after": "bbb",
            }
            assert sm.get_worker_revision_drift("rig1", "bbb") is not None
        finally:
            sm.close()


class TestRetention:
    """Long-running behavior: history/workers must not grow unbounded. Tests are white-box
    (they backdate timestamps) so they don't need to actually wait days."""

    def test_history_older_than_retention_pruned_from_memory(self, state_manager):
        # Intent: appending a fresh sample drops in-memory points older than the 30-day window
        # (the popleft loop), so the deque can't grow without bound on a long-running dashboard.
        state_manager.state["hashrate_history"].append(
            {
                "t": "old",
                "v": 1.0,
                "v_p2pool": 0,
                "v_xvb": 0,
                "timestamp": time.time() - HISTORY_RETENTION_SEC - 3600,  # 30d + 1h ago
            }
        )
        assert len(state_manager.get_history()) == 1
        state_manager.update_history(2000.0)  # a fresh sample at "now"
        hist = state_manager.get_history()
        assert len(hist) == 1 and hist[0]["v"] == 2000.0  # the ancient point was pruned

    def test_old_history_pruned_from_db_when_cleanup_fires(self, state_manager, monkeypatch):
        # Intent: the probabilistic DB cleanup actually deletes expired rows when it fires, so
        # the on-disk DB stays bounded. We force the 5% path deterministically.
        old_ts = time.time() - HISTORY_RETENTION_SEC - 10 * 24 * 3600  # 40 days ago
        with state_manager._db_lock:
            state_manager._conn.execute(
                "INSERT INTO history (t, v, v_p2pool, v_xvb, timestamp) VALUES (?,?,?,?,?)",
                ("old", 1.0, 0, 0, old_ts),
            )
            state_manager._conn.commit()
        monkeypatch.setattr("mining_dashboard.service.storage_service.random.random", lambda: 0.0)
        state_manager.update_history(2000.0)
        with state_manager._db_lock:
            remaining = state_manager._conn.execute(
                "SELECT COUNT(*) FROM history WHERE timestamp < ?",
                (time.time() - HISTORY_RETENTION_SEC,),
            ).fetchone()[0]
        assert remaining == 0, "expired DB rows are pruned"
