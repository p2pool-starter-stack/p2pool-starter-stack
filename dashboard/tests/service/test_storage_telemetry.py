"""The periodic telemetry series tables in the StateManager store -- chart events, share
stats, blocks, network history and disk growth (#1105 Phase 3, cut D6).

These seven classes moved 1:1 and byte-identical out of ``tests/service/test_storage_service.py``,
which remains the master module for the core tables.  Nothing was edited in the move: the subject
module ``mining_dashboard/service/storage_service.py`` is NOT split, so no name is repointed.

``TestTelemetryTablesAfterClose`` is one of the file's cross-table classes: it asserts the
after-close behaviour of every telemetry table at once, including ``xvb_history`` and
``worker_history`` whose own classes moved to the sibling modules.  It is placed here by what it
tests -- the telemetry tables as a set -- rather than by any single table.

Unlike the D2-D5 cuts there is no duplicated fixture block here.  ``state_manager`` and the autouse
``_isolate_db`` are defined in ``dashboard/tests/conftest.py`` -- the tests-ROOT conftest -- which
every module under ``dashboard/tests/`` inherits, so the standing duplicate-the-builders ruling
costs this cut nothing but its import block.
"""

import sqlite3
import time

from mining_dashboard.config.config import HISTORY_RETENTION_SEC
from mining_dashboard.service.storage_service import NETWORK_HISTORY_RETENTION_SEC, StateManager


class TestChartEvents:
    """Degradation/recovery markers for the chart (#99): in-memory tally, disk persistence, and
    tolerance of a pre-migration DB with no events table."""

    def test_add_and_get_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_event(t0, "loss", "-62%")
        state_manager.add_event(t0 + 100, "recovered", "")
        evs = state_manager.get_events()
        assert [e["type"] for e in evs] == ["loss", "recovered"]
        assert evs[0] == {"ts": t0, "type": "loss", "detail": "-62%"}
        # returns a copy — mutating it doesn't corrupt stored state
        evs.clear()
        assert len(state_manager.get_events()) == 2

    def test_old_events_pruned_from_memory(self, state_manager):
        state_manager.add_event(1.0, "loss", "ancient")  # ts well before the retention cutoff
        state_manager.add_event(time.time(), "recovered", "fresh")
        details = [e["detail"] for e in state_manager.get_events()]
        assert details == ["fresh"]

    def test_events_survive_reload(self, tmp_path):
        db = str(tmp_path / "events.db")
        sm = StateManager(db_path=db)
        sm.add_event(time.time(), "loss", "-50%")
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            evs = sm2.get_events()
            assert len(evs) == 1 and evs[0]["type"] == "loss"
        finally:
            sm2.close()

    def test_load_tolerates_missing_share_stats_table(self, tmp_path):
        # Same upgrade path for the #116 table: a pre-migration DB must open without error and
        # report an empty series.
        db = str(tmp_path / "legacy2.db")
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT)")
        conn.commit()
        conn.close()
        sm = StateManager(db_path=db)
        try:
            assert sm.get_share_stats() == []
        finally:
            sm.close()

    def test_load_tolerates_missing_events_table(self, tmp_path):
        # Upgrade path: a DB written by a pre-#99 build has no events table. Opening it must not
        # crash and must report no events. (StateManager creates the table on open, so load() then
        # finds it empty; the sqlite3.Error guard in load() is defence-in-depth for that ordering.)
        db = str(tmp_path / "legacy.db")
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT)")
        conn.commit()
        conn.close()
        sm = StateManager(db_path=db)
        try:
            assert sm.get_events() == []
        finally:
            sm.close()


class TestShareStatsSeries:
    """Per-poll share-health deltas (#116): in-memory tally, disk persistence, retention pruning.
    (Pre-migration-DB tolerance rides with the events check in TestChartEvents above.)"""

    def test_add_and_get_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_share_stats(t0, accepted=10, rejected=1)
        state_manager.add_share_stats(t0 + 30, accepted=8, invalid=2, expired=1)
        rows = state_manager.get_share_stats()
        assert rows[0] == {"ts": t0, "accepted": 10, "rejected": 1, "invalid": 0, "expired": 0}
        assert rows[1] == {
            "ts": t0 + 30,
            "accepted": 8,
            "rejected": 0,
            "invalid": 2,
            "expired": 1,
        }
        # returns a copy — mutating it doesn't corrupt stored state
        rows.clear()
        assert len(state_manager.get_share_stats()) == 2

    def test_old_rows_pruned_from_memory(self, state_manager):
        state_manager.add_share_stats(1.0, accepted=1)  # ts well before the retention cutoff
        state_manager.add_share_stats(time.time(), accepted=2)
        assert [r["accepted"] for r in state_manager.get_share_stats()] == [2]

    def test_rows_survive_reload(self, tmp_path):
        db = str(tmp_path / "share_stats.db")
        sm = StateManager(db_path=db)
        sm.add_share_stats(time.time(), accepted=10, rejected=1)
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            rows = sm2.get_share_stats()
            assert len(rows) == 1 and rows[0]["accepted"] == 10 and rows[0]["rejected"] == 1
        finally:
            sm2.close()

    def test_old_rows_pruned_from_db_when_cleanup_fires(self, state_manager, monkeypatch):
        # Force the probabilistic 5% prune path deterministically, like the history prune test.
        old_ts = time.time() - HISTORY_RETENTION_SEC - 10 * 24 * 3600  # 40 days ago
        with state_manager._db_lock:
            state_manager._conn.execute(
                "INSERT INTO share_stats (ts, accepted, rejected, invalid, expired) "
                "VALUES (?,?,?,?,?)",
                (old_ts, 1, 0, 0, 0),
            )
            state_manager._conn.commit()
        monkeypatch.setattr("mining_dashboard.service.storage_service.random.random", lambda: 0.0)
        state_manager.add_share_stats(time.time(), accepted=5)
        with state_manager._db_lock:
            remaining = state_manager._conn.execute(
                "SELECT COUNT(*) FROM share_stats WHERE ts < ?",
                (time.time() - HISTORY_RETENTION_SEC,),
            ).fetchone()[0]
        assert remaining == 0, "expired delta rows are pruned"

    def test_write_error_flags_db_unhealthy(self, state_manager):
        # Route failures through _db_error so the #131 persistence badge trips.
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE share_stats")
        state_manager.add_share_stats(time.time(), accepted=1)
        assert state_manager.is_db_healthy() is False

    def test_load_tolerates_unreadable_table(self, tmp_path):
        # Defence-in-depth guard in load(): a share_stats table with an alien schema (SELECT
        # fails) must load as an empty series, not crash the whole startup load.
        db = str(tmp_path / "alien.db")
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE share_stats (wrong TEXT)")
        conn.commit()
        conn.close()
        sm = StateManager(db_path=db)
        try:
            assert sm.get_share_stats() == []
        finally:
            sm.close()


class TestBlocks:
    """Pool block-found events (#196 Wave-0): permanent — never pruned, unlike the four
    retention-bound telemetry tables below."""

    def test_add_and_get_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_block(t0, height=3_100_000, difficulty=123456.0)
        rows = state_manager.get_blocks()
        assert rows == [{"ts": t0, "height": 3_100_000, "difficulty": 123456.0}]

    def test_get_since_filters_the_window(self, state_manager):
        t0 = time.time()
        state_manager.add_block(t0 - 1000, height=1, difficulty=1.0)
        state_manager.add_block(t0, height=2, difficulty=2.0)
        rows = state_manager.get_blocks(since=t0 - 10)
        assert [r["height"] for r in rows] == [2]

    def test_never_pruned(self, state_manager, monkeypatch):
        # Force the probabilistic-prune roll to "always fire" — blocks has no prune code path at
        # all, so an ancient row must survive regardless.
        old_ts = time.time() - HISTORY_RETENTION_SEC - 10 * 24 * 3600  # 40 days ago
        state_manager.add_block(old_ts, height=1, difficulty=1.0)
        monkeypatch.setattr("mining_dashboard.service.storage_service.random.random", lambda: 0.0)
        state_manager.add_block(time.time(), height=2, difficulty=2.0)
        assert len(state_manager.get_blocks()) == 2

    def test_write_error_flags_table_and_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE blocks")
        state_manager.add_block(time.time(), height=1, difficulty=1.0)
        assert state_manager.is_db_healthy() is False
        assert state_manager.get_table_health()["blocks"]["healthy"] is False

    def test_reads_tolerate_a_missing_table(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE blocks")
        assert state_manager.get_blocks() == []


class TestNetworkHistory:
    """Difficulty/height/reward/pool-hashrate over time (#196 Wave-0): 90-day retention, DB-only."""

    def test_add_and_get_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_network_history(
            t0, difficulty=1e12, height=3_100_000, reward=0.6, pool_hashrate=5e6
        )
        rows = state_manager.get_network_history()
        assert rows == [
            {
                "ts": t0,
                "difficulty": 1e12,
                "height": 3_100_000,
                "reward": 0.6,
                "pool_hashrate": 5e6,
            }
        ]

    def test_get_since_filters_the_window(self, state_manager):
        t0 = time.time()
        state_manager.add_network_history(t0 - 1000, height=1)
        state_manager.add_network_history(t0, height=2)
        rows = state_manager.get_network_history(since=t0 - 10)
        assert [r["height"] for r in rows] == [2]

    def test_old_rows_pruned_from_db_when_cleanup_fires(self, state_manager, monkeypatch):
        old_ts = time.time() - NETWORK_HISTORY_RETENTION_SEC - 24 * 3600  # 91 days ago
        with state_manager._db_lock:
            state_manager._conn.execute(
                "INSERT INTO network_history (ts, difficulty, height, reward, pool_hashrate) "
                "VALUES (?,?,?,?,?)",
                (old_ts, 1.0, 1, 0.0, 0.0),
            )
            state_manager._conn.commit()
        monkeypatch.setattr("mining_dashboard.service.storage_service.random.random", lambda: 0.0)
        state_manager.add_network_history(time.time(), difficulty=2.0)
        with state_manager._db_lock:
            remaining = state_manager._conn.execute(
                "SELECT COUNT(*) FROM network_history WHERE ts < ?",
                (time.time() - NETWORK_HISTORY_RETENTION_SEC,),
            ).fetchone()[0]
        assert remaining == 0

    def test_retention_is_90_days_not_30(self):
        assert NETWORK_HISTORY_RETENTION_SEC == 90 * 24 * 3600

    def test_write_error_flags_table_and_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE network_history")
        state_manager.add_network_history(time.time())
        assert state_manager.is_db_healthy() is False
        assert state_manager.get_table_health()["network_history"]["healthy"] is False

    def test_reads_tolerate_a_missing_table(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE network_history")
        assert state_manager.get_network_history() == []


class TestDiskGrowth:
    """monerod DB size + host disk usage over time (#196 Wave-0): permanent, DB-only."""

    def test_add_and_get_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_disk_growth(
            t0, monero_db_bytes=200_000_000_000, disk_used_gb=210.5, disk_total_gb=500.0
        )
        rows = state_manager.get_disk_growth()
        assert rows == [
            {
                "ts": t0,
                "monero_db_bytes": 200_000_000_000,
                "disk_used_gb": 210.5,
                "disk_total_gb": 500.0,
            }
        ]

    def test_get_since_filters_the_window(self, state_manager):
        t0 = time.time()
        state_manager.add_disk_growth(t0 - 1000, monero_db_bytes=1)
        state_manager.add_disk_growth(t0, monero_db_bytes=2)
        rows = state_manager.get_disk_growth(since=t0 - 10)
        assert [r["monero_db_bytes"] for r in rows] == [2]

    def test_never_pruned(self, state_manager, monkeypatch):
        old_ts = time.time() - HISTORY_RETENTION_SEC - 10 * 24 * 3600  # 40 days ago
        state_manager.add_disk_growth(old_ts, monero_db_bytes=1)
        monkeypatch.setattr("mining_dashboard.service.storage_service.random.random", lambda: 0.0)
        state_manager.add_disk_growth(time.time(), monero_db_bytes=2)
        assert len(state_manager.get_disk_growth()) == 2

    def test_write_error_flags_table_and_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE disk_growth")
        state_manager.add_disk_growth(time.time())
        assert state_manager.is_db_healthy() is False
        assert state_manager.get_table_health()["disk_growth"]["healthy"] is False

    def test_reads_tolerate_a_missing_table(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE disk_growth")
        assert state_manager.get_disk_growth() == []


class TestTelemetryTableHealth:
    """Per-table 'last successful write' health signal (#196 Wave-0), mirroring db_healthy so a
    hook that silently stops writing (the whole poll loop is one try/except) is visible."""

    def test_starts_healthy_with_no_write_yet(self, state_manager):
        health = state_manager.get_table_health()
        assert set(health) == {
            "blocks",
            "xvb_history",
            "network_history",
            "disk_growth",
            "worker_history",
        }
        for row in health.values():
            assert row == {"healthy": True, "last_write": None}

    def test_last_write_stamps_on_success(self, state_manager):
        t0 = time.time()
        state_manager.add_block(t0, height=1, difficulty=1.0)
        assert state_manager.get_table_health()["blocks"] == {"healthy": True, "last_write": t0}
        # untouched tables stay at their default
        assert state_manager.get_table_health()["xvb_history"]["last_write"] is None

    def test_returns_a_copy(self, state_manager):
        state_manager.add_block(time.time(), height=1, difficulty=1.0)
        health = state_manager.get_table_health()
        health["blocks"]["healthy"] = False
        assert state_manager.get_table_health()["blocks"]["healthy"] is True

    def test_a_closed_handle_reads_unhealthy_for_every_table(self, state_manager):
        # #1615: the closed-handle guard returns before either stamp, so the RAW entries stay
        # healthy while every write is dropped -- get_table_health folds the handle in instead.
        state_manager.add_block(time.time(), height=1, difficulty=1.0)
        # Control against a derivation that is wrong in the other direction: a write that DID
        # land, on a live handle, still reads healthy.
        assert state_manager.get_table_health()["blocks"]["healthy"] is True
        state_manager.close()
        assert [t for t, row in state_manager.get_table_health().items() if row["healthy"]] == []
        # ...and the raw dict is untouched, so the fix is at the read and not a fifth stamp.
        assert state_manager.table_health["blocks"]["healthy"] is True

    def test_last_write_survives_a_closed_handle(self, state_manager):
        # `last_write` is a historical fact about a write that landed; only `healthy` is derived.
        t0 = time.time()
        state_manager.add_block(t0, height=1, difficulty=1.0)
        state_manager.close()
        assert state_manager.get_table_health()["blocks"] == {"healthy": False, "last_write": t0}

    def test_a_failed_recovery_reads_unhealthy(self, state_manager, monkeypatch):
        # The production path #1615 reports, rather than close(): _recover_corrupt_db's reconnect
        # raises, `_conn` stays None for good, and every telemetry write is dropped from then on.
        def boom(*_a, **_kw):
            raise sqlite3.OperationalError("unable to open database file")

        monkeypatch.setattr("mining_dashboard.service.storage_service.sqlite3.connect", boom)
        state_manager._recover_corrupt_db("test: forced reconnect failure")
        assert state_manager.is_db_unrecoverable() is True
        state_manager.add_block(time.time(), height=1, difficulty=1.0)
        assert state_manager.get_table_health()["blocks"]["healthy"] is False


class TestTelemetryTablesAfterClose:
    """After close() the connection is None — every v1.7 telemetry-table accessor must no-op /
    read empty, never raise (mirrors TestPayouts.test_reads_and_writes_after_close_are_safe)."""

    def test_all_five_tables_are_safe_after_close(self, state_manager):
        state_manager.close()
        state_manager.add_block(time.time(), height=1, difficulty=1.0)
        state_manager.add_xvb_history(time.time())
        state_manager.add_network_history(time.time())
        state_manager.add_disk_growth(time.time())
        state_manager.add_worker_history(
            [{"ts": time.time(), "name": "rig1", "h15": 1.0, "accepted": 0, "rejected": 0}]
        )
        assert state_manager.get_blocks() == []
        assert state_manager.get_xvb_history() == []
        assert state_manager.get_network_history() == []
        assert state_manager.get_disk_growth() == []
        assert state_manager.get_worker_history() == []
