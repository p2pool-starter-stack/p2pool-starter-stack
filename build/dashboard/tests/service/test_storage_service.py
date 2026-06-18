import sqlite3
import time

import pytest

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.config.config import TIER_DEFAULTS, HISTORY_RETENTION_SEC


class TestDefaults:
    def test_get_tiers(self, state_manager):
        assert state_manager.get_tiers() == TIER_DEFAULTS

    def test_default_xvb_stats(self, state_manager):
        xvb = state_manager.get_xvb_stats()
        assert xvb["current_mode"] == "P2POOL"
        assert xvb["fail_count"] == 0
        # returns a copy, not the live dict
        xvb["fail_count"] = 99
        assert state_manager.get_xvb_stats()["fail_count"] == 0


class TestXvbStats:
    def test_partial_updates(self, state_manager):
        state_manager.update_xvb_stats(mode="XVB", avg_24h=1234.0, fail_count=2)
        xvb = state_manager.get_xvb_stats()
        assert xvb["current_mode"] == "XVB"
        assert xvb["avg_24h"] == 1234.0
        assert xvb["fail_count"] == 2

    def test_kwargs_update_and_type_coercion(self, state_manager):
        state_manager.update_xvb_stats(total_donated_time="50")  # str -> float
        assert state_manager.get_xvb_stats()["total_donated_time"] == 50.0

    def test_none_kwargs_skipped(self, state_manager):
        before = state_manager.get_xvb_stats()["total_donated_time"]
        state_manager.update_xvb_stats(total_donated_time=None)
        assert state_manager.get_xvb_stats()["total_donated_time"] == before

    def test_unknown_kwarg_ignored(self, state_manager):
        state_manager.update_xvb_stats(not_a_real_field=1)
        assert "not_a_real_field" not in state_manager.get_xvb_stats()

    def test_real_fetch_sets_last_update(self, state_manager):
        # avg_1h / avg_24h only come from a successful xvb_client.get_stats — a real fetch (#136).
        assert state_manager.get_xvb_stats()["last_update"] == 0.0
        state_manager.update_xvb_stats(avg_1h=100.0, avg_24h=200.0)
        assert state_manager.get_xvb_stats()["last_update"] > 0.0

    def test_local_only_writes_do_not_set_last_update(self, state_manager):
        # The algo controller writes mode / donation_fraction / fail_count every cycle; none is an
        # xmrvsbeast.com fetch, so the "Updated" freshness timestamp must NOT bump on them (#136) —
        # otherwise it ticks fresh even while the site is unreachable.
        state_manager.update_xvb_stats(mode="XVB", donation_fraction=0.5, fail_count=3)
        assert state_manager.get_xvb_stats()["last_update"] == 0.0
        # Once a real fetch sets it, a later local-only write must leave it untouched.
        state_manager.update_xvb_stats(avg_1h=100.0)
        fetched_at = state_manager.get_xvb_stats()["last_update"]
        assert fetched_at > 0.0
        state_manager.update_xvb_stats(donation_fraction=0.9)
        assert state_manager.get_xvb_stats()["last_update"] == fetched_at


class TestSharesAndHistory:
    def test_add_share_and_dedup(self, state_manager):
        ts = time.time()
        state_manager.add_share(ts, 500)
        state_manager.add_share(ts, 500)  # duplicate ts
        shares = state_manager.get_shares()
        assert len(shares) == 1
        assert shares[0]["difficulty"] == 500

    def test_add_shares_records_count_distinct(self, state_manager):
        # A burst of shares between polls (cumulative counter jumped by 3) must record 3 DISTINCT
        # shares, not collapse onto one timestamp (the shares table is keyed by ts) (#129).
        ts = time.time()
        state_manager.add_shares(3, ts, 500)
        shares = state_manager.get_shares()
        assert len(shares) == 3
        assert len({s["ts"] for s in shares}) == 3  # all distinct timestamps
        assert max(s["ts"] for s in shares) == pytest.approx(ts)  # most recent stamped at latest_ts

    def test_add_shares_count_zero_or_one(self, state_manager):
        ts = time.time()
        state_manager.add_shares(0, ts, 500)
        assert state_manager.get_shares() == []
        state_manager.add_shares(1, ts, 500)
        assert len(state_manager.get_shares()) == 1

    def test_old_shares_pruned_from_memory(self, state_manager):
        state_manager.add_share(1.0, 1)  # ancient ts -> pruned
        assert all(s["ts"] >= time.time() - 31 * 24 * 3600 for s in state_manager.get_shares())

    def test_update_history_roundtrip(self, state_manager):
        state_manager.update_history(1_000_000, p2pool_hr=600_000, xvb_hr=400_000)
        hist = state_manager.get_history()
        assert hist[-1]["v"] == 1_000_000
        assert hist[-1]["v_p2pool"] == 600_000
        assert hist[-1]["v_xvb"] == 400_000

    def test_history_bad_values_default_zero(self, state_manager):
        state_manager.update_history("bad", "bad", "bad")
        assert state_manager.get_history()[-1]["v"] == 0.0

    def test_per_window_splits_persisted(self, state_manager):
        # The chart's window toggle (#168): each window's (p2pool, xvb) split is stored in its own
        # column and read back; an omitted window defaults to 0.
        state_manager.update_history(
            1000,
            p2pool_hr=1000,
            xvb_hr=0,
            windows={"1m": (900, 0), "1h": (1100, 0), "12h": (50, 0)},  # 24h intentionally omitted
        )
        row = state_manager.get_history()[-1]
        assert (row["v_p2pool_1m"], row["v_xvb_1m"]) == (900, 0)
        assert (row["v_p2pool_1h"], row["v_xvb_1h"]) == (1100, 0)
        assert (row["v_p2pool_12h"], row["v_xvb_12h"]) == (50, 0)
        assert (row["v_p2pool_24h"], row["v_xvb_24h"]) == (0, 0)  # omitted -> default 0

    def test_per_window_splits_survive_reload(self, tmp_path):
        # Persisted to disk and re-read on a fresh StateManager (load() path), not just in-memory.
        db = str(tmp_path / "windows.db")
        sm = StateManager(db_path=db)
        sm.update_history(1000, p2pool_hr=0, xvb_hr=1000, windows={"24h": (0, 777)})
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            assert sm2.get_history()[-1]["v_xvb_24h"] == 777
        finally:
            sm2.close()


class TestDbHealth:
    def test_healthy_by_default(self, state_manager):
        assert state_manager.is_db_healthy() is True

    def test_unhealthy_after_write_error(self):
        # A fresh in-memory DB so the deliberate break stays isolated. Dropping the shares table
        # makes the next add_share INSERT raise a sqlite3.Error: the dashboard catches it (it keeps
        # serving live data), but must now also flag persistence unhealthy so /api/state can warn
        # instead of silently losing history on the next restart (#131).
        sm = StateManager(":memory:")
        assert sm.is_db_healthy() is True
        sm._conn.execute("DROP TABLE shares")
        sm.add_share(time.time(), 500)  # INSERT fails -> caught -> flag flips
        assert sm.is_db_healthy() is False
        sm.close()


class TestSnapshot:
    def test_roundtrip(self, state_manager):
        state_manager.save_snapshot({"a": 1, "b": [1, 2, 3]})
        assert state_manager.load_snapshot() == {"a": 1, "b": [1, 2, 3]}

    def test_empty_snapshot_not_saved(self, state_manager):
        state_manager.save_snapshot({})
        assert state_manager.load_snapshot() is None

    def test_load_missing_snapshot_returns_none(self, state_manager):
        assert state_manager.load_snapshot() is None

    def test_share_stats_persist_across_instances(self, tmp_path):
        # Issue #82: the per-worker share counts and the proxy /summary totals ride along in the
        # latest_data snapshot, so they survive a dashboard restart (the snapshot is what
        # DataService restores on init). Save with one instance, read back with a fresh one.
        db = str(tmp_path / "state.db")
        sm1 = StateManager(db_path=db)
        sm1.save_snapshot(
            {
                "workers": [
                    {
                        "name": "rig1",
                        "ip": "10.0.0.1",
                        "status": "online",
                        "accepted": 1234,
                        "rejected": 5,
                        "invalid": 0,
                    }
                ],
                "proxy_summary": {
                    "accepted": 12345,
                    "rejected": 67,
                    "invalid": 2,
                    "expired": 1,
                    "best": 9876543,
                },
            }
        )
        sm1.close()

        snap = StateManager(db_path=db).load_snapshot()  # fresh instance -> reads from disk
        assert snap["workers"][0]["accepted"] == 1234
        assert snap["workers"][0]["rejected"] == 5
        assert snap["proxy_summary"] == {
            "accepted": 12345,
            "rejected": 67,
            "invalid": 2,
            "expired": 1,
            "best": 9876543,
        }


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
