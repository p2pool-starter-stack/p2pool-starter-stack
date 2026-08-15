import sqlite3
import time
from unittest.mock import MagicMock

import pytest

from mining_dashboard.config.config import HISTORY_RETENTION_SEC, TIER_DEFAULTS
from mining_dashboard.service import storage_service
from mining_dashboard.service.storage_service import NETWORK_HISTORY_RETENTION_SEC, StateManager


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


class TestXvbWarmStandby:
    """Warm-resume persistence for the failover pair (#249)."""

    def test_commanded_fraction_defaults_zero(self, state_manager):
        assert state_manager.get_xvb_stats()["commanded_fraction"] == 0.0

    def test_commanded_fraction_persists_across_restart(self, tmp_path):
        # The controller's commanded fraction must outlive a dashboard recreate so a restart
        # resumes the warmed split instead of re-seeding cold from feedforward.
        db = str(tmp_path / "xvb.db")
        sm = StateManager(db_path=db)
        sm.update_xvb_stats(commanded_fraction=0.42)
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            assert sm2.get_xvb_stats()["commanded_fraction"] == 0.42
        finally:
            sm2.close()

    def test_standby_roundtrip(self, state_manager):
        blob = {"commanded_fraction": 0.3, "avg_1h": 1200.0, "mode": "SPLIT"}
        state_manager.set_xvb_standby(blob)
        assert state_manager.get_xvb_standby() == blob

    def test_standby_persists_across_restart(self, tmp_path):
        db = str(tmp_path / "standby.db")
        sm = StateManager(db_path=db)
        sm.set_xvb_standby({"commanded_fraction": 0.25, "avg_1h": 900.0})
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            assert sm2.get_xvb_standby()["commanded_fraction"] == 0.25
        finally:
            sm2.close()

    def test_standby_none_when_unset(self, state_manager):
        assert state_manager.get_xvb_standby() is None

    def test_standby_unserializable_flags_unhealthy(self, state_manager):
        # A blob json.dumps can't serialize is a persistent write failure — flag it like every
        # other write path (#131) rather than raising into the puller.
        assert state_manager.is_db_healthy() is True
        state_manager.set_xvb_standby({"bad": {1, 2, 3}})  # set -> TypeError in json.dumps
        assert state_manager.is_db_healthy() is False

    def test_standby_bad_payload_reads_none(self, state_manager):
        # A corrupt/non-dict blob degrades to "no standby" rather than raising into the seed path.
        state_manager.set_kv("xvb_standby", "not-json{")
        assert state_manager.get_xvb_standby() is None
        state_manager.set_kv("xvb_standby", "[1, 2, 3]")  # valid JSON, wrong shape
        assert state_manager.get_xvb_standby() is None


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

    def test_reward_estimates_default_empty_and_not_fresh(self, state_manager):
        # #118: cold cache is empty with last_update 0.0 (never fetched) so build_xvb_calc reads
        # estimates_available False without treating it as "stale".
        got = state_manager.get_xvb_reward_estimates()
        assert got == {"estimates": {}, "last_update": 0.0}

    def test_set_reward_estimates_stamps_last_update_and_copies(self, state_manager):
        state_manager.set_xvb_reward_estimates({"donor": 0.06, "donor_mega": 56.9})
        got = state_manager.get_xvb_reward_estimates()
        assert got["estimates"] == {"donor": 0.06, "donor_mega": 56.9}
        assert got["last_update"] > 0.0
        # returns a copy, not the live cache
        got["estimates"]["donor"] = 99
        assert state_manager.get_xvb_reward_estimates()["estimates"]["donor"] == 0.06

    def test_round_stats_default_empty_then_set_stamps_and_copies(self, state_manager):
        # #866: same memory-only, stamp-on-genuine-fetch, copy-out contract as the estimates.
        assert state_manager.get_xvb_round_stats() == {"stats": {}, "last_update": 0.0}
        stats = {"types": {"donor_whale": {"rounds": 62, "players_avg": 9.8}}, "span_days": 7.0}
        state_manager.set_xvb_round_stats(stats)
        got = state_manager.get_xvb_round_stats()
        assert got["stats"] == stats
        assert got["last_update"] > 0.0
        got["stats"]["span_days"] = 99
        assert state_manager.get_xvb_round_stats()["stats"]["span_days"] == 7.0

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


class TestKvStore:
    def test_get_missing_key_is_none(self, state_manager):
        assert state_manager.get_kv("payout_wallet") is None

    def test_set_then_get_roundtrip(self, state_manager):
        state_manager.set_kv("payout_wallet", "4Aaaa")
        assert state_manager.get_kv("payout_wallet") == "4Aaaa"
        state_manager.set_kv("payout_wallet", "4Bbbb")  # insert-or-replace
        assert state_manager.get_kv("payout_wallet") == "4Bbbb"

    def test_non_string_values_stored_as_strings(self, state_manager):
        state_manager.set_kv("payout_wallet_changed_ts", 1234.5)
        assert state_manager.get_kv("payout_wallet_changed_ts") == "1234.5"

    def test_kv_survives_restart(self, tmp_path):
        # The wallet-tripwire baseline (#375) must outlive a dashboard container recreate —
        # that recreate (a `pithead apply`) is exactly the attack window.
        db = str(tmp_path / "kv.db")
        sm = StateManager(db_path=db)
        sm.set_kv("payout_wallet", "4Aaaa")
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            assert sm2.get_kv("payout_wallet") == "4Aaaa"
        finally:
            sm2.close()

    def test_write_error_flags_db_unhealthy(self):
        sm = StateManager(":memory:")
        sm._conn.execute("DROP TABLE kv_store")
        sm.set_kv("payout_wallet", "x")  # INSERT fails -> caught -> #131 flag flips
        assert sm.is_db_healthy() is False
        assert sm.get_kv("payout_wallet") is None  # read error -> None, never raises
        sm.close()


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

    def test_unserializable_snapshot_flags_persistence_unhealthy(self, state_manager):
        # A snapshot json.dumps can't serialize (here a set) is a persistent write failure: the
        # data is lost and will be lost on restart. Like every other write path it must flip
        # db_healthy so /api/state raises the #131 badge — not log-and-look-green (regression guard
        # for save_snapshot's TypeError branch that used to call logger.error directly).
        assert state_manager.is_db_healthy() is True
        state_manager.save_snapshot({"workers": {1, 2, 3}})  # set -> TypeError in json.dumps
        assert state_manager.is_db_healthy() is False
        assert state_manager.load_snapshot() is None  # nothing was persisted

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


class TestRaffleWins:
    """XvB raffle wins mirrored from the public winners file, keyed block_id (idempotent)."""

    def _wins(self):
        return [
            {"ts": 1000.0, "hashrate": 4.2e6, "height": 100, "block_id": "aa11", "tier": "donor"},
            {
                "ts": 2000.0,
                "hashrate": 5.0e6,
                "height": 200,
                "block_id": "bb22",
                "tier": "donor_whale",
            },
        ]

    def test_add_returns_only_new_rows(self, state_manager):
        new = state_manager.add_raffle_wins(self._wins())
        assert {w["block_id"] for w in new} == {"aa11", "bb22"}

    def test_add_is_idempotent_on_block_id(self, state_manager):
        state_manager.add_raffle_wins(self._wins())
        # Re-adding the same rows (re-reading the file's ~4-day window) inserts nothing new,
        # so a win is never re-announced.
        assert state_manager.add_raffle_wins(self._wins()) == []
        assert len(state_manager.get_raffle_wins()) == 2

    def test_get_raffle_wins_oldest_first_with_since(self, state_manager):
        state_manager.add_raffle_wins(self._wins())
        got = state_manager.get_raffle_wins()
        assert [w["block_id"] for w in got] == ["aa11", "bb22"]  # ts ASC
        assert got[1]["tier"] == "donor_whale"
        assert got[1]["hashrate"] == 5.0e6
        assert [w["block_id"] for w in state_manager.get_raffle_wins(since=1500.0)] == ["bb22"]

    def test_empty_input_is_a_noop(self, state_manager):
        assert state_manager.add_raffle_wins([]) == []

    def test_write_error_flags_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE raffle_wins")
        assert state_manager.add_raffle_wins(self._wins()) == []
        assert state_manager.is_db_healthy() is False

    def test_table_bounded_to_newest_max_rows(self, state_manager, monkeypatch):
        # Security bound: the source file is untrusted, so the table keeps only the newest
        # RAFFLE_WINS_MAX_ROWS — a hostile feed cannot grow it without limit, and the read
        # side never returns more than the bound either.
        monkeypatch.setattr(storage_service, "RAFFLE_WINS_MAX_ROWS", 3)
        wins = [
            {"ts": float(i), "hashrate": 1.0, "height": i, "block_id": f"id{i}", "tier": "t"}
            for i in range(6)
        ]
        state_manager.add_raffle_wins(wins)
        got = state_manager.get_raffle_wins()
        assert [w["block_id"] for w in got] == ["id3", "id4", "id5"]  # newest 3, oldest first


class TestPayouts:
    """Confirmed on-chain payouts (#381), keyed (chain, txid) so the Tari sibling (#462) reuses it."""

    def _rows(self):
        return [
            {"txid": "aa", "height": 100, "ts": 1000.0, "amount_atomic": 250_000_000_000},
            {"txid": "bb", "height": 101, "ts": 2000.0, "amount_atomic": 500_000_000_000},
        ]

    def test_add_returns_only_new_rows(self, state_manager):
        new = state_manager.add_payouts("monero", self._rows())
        assert {r["txid"] for r in new} == {"aa", "bb"}

    def test_add_is_idempotent_on_chain_txid(self, state_manager):
        state_manager.add_payouts("monero", self._rows())
        # Re-adding the same rows (a restart re-scanning the tip) inserts nothing new → no re-alert.
        again = state_manager.add_payouts("monero", self._rows())
        assert again == []
        assert len(state_manager.get_payouts("monero")) == 2

    def test_same_txid_different_chain_is_a_distinct_payout(self, state_manager):
        # The PK is (chain, txid): the same txid string on another chain must NOT collide (#462).
        state_manager.add_payouts("monero", [self._rows()[0]])
        new = state_manager.add_payouts("tari", [self._rows()[0]])
        assert len(new) == 1
        assert len(state_manager.get_payouts()) == 2  # both chains, cross-chain query
        assert len(state_manager.get_payouts("monero")) == 1

    def test_get_payouts_newest_first(self, state_manager):
        state_manager.add_payouts("monero", self._rows())
        got = state_manager.get_payouts("monero")
        assert [p["txid"] for p in got] == ["bb", "aa"]  # ts DESC
        assert got[0]["amount_atomic"] == 500_000_000_000

    def test_max_height_seeds_the_wallet_poll(self, state_manager):
        assert state_manager.get_payout_max_height("monero") == 0
        state_manager.add_payouts("monero", self._rows())
        assert state_manager.get_payout_max_height("monero") == 101
        # Another chain's rows don't move Monero's seed.
        state_manager.add_payouts(
            "tari", [{"txid": "zz", "height": 9, "ts": 5.0, "amount_atomic": 1}]
        )
        assert state_manager.get_payout_max_height("monero") == 101

    def test_empty_input_is_a_noop(self, state_manager):
        assert state_manager.add_payouts("monero", []) == []

    def test_write_error_flags_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE payouts")
        assert state_manager.add_payouts("monero", self._rows()) == []
        assert state_manager.is_db_healthy() is False

    def test_reads_tolerate_a_missing_table(self, state_manager):
        # A DB whose payouts table is gone (alien/older schema) reads as empty / height 0, not crash.
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE payouts")
        assert state_manager.get_payouts("monero") == []
        assert state_manager.get_payout_max_height("monero") == 0

    def test_reads_and_writes_after_close_are_safe(self, state_manager):
        # After close() the connection is None — every payout accessor must no-op, never raise.
        state_manager.close()
        assert state_manager.add_payouts("monero", [{"txid": "x", "amount_atomic": 1}]) == []
        assert state_manager.get_payouts("monero") == []
        assert state_manager.get_payout_max_height("monero") == 0


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


class TestXvbHistory:
    """XvB scalars over time (#196 Wave-0): 30-day retention, same recipe as share_stats/events."""

    def test_add_and_get_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_xvb_history(
            t0, avg_1h=1000.0, avg_24h=900.0, fail_count=1, donation_fraction=0.5, mode="XVB"
        )
        rows = state_manager.get_xvb_history()
        assert rows == [
            {
                "ts": t0,
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 1,
                "donation_fraction": 0.5,
                "mode": "XVB",
            }
        ]

    def test_get_since_filters_the_window(self, state_manager):
        t0 = time.time()
        state_manager.add_xvb_history(t0 - 1000, avg_1h=1.0)
        state_manager.add_xvb_history(t0, avg_1h=2.0)
        rows = state_manager.get_xvb_history(since=t0 - 10)
        assert [r["avg_1h"] for r in rows] == [2.0]

    def test_old_rows_pruned_from_db_when_cleanup_fires(self, state_manager, monkeypatch):
        old_ts = time.time() - HISTORY_RETENTION_SEC - 10 * 24 * 3600  # 40 days ago
        with state_manager._db_lock:
            state_manager._conn.execute(
                "INSERT INTO xvb_history (ts, avg_1h, avg_24h, fail_count, donation_fraction, mode) "
                "VALUES (?,?,?,?,?,?)",
                (old_ts, 1.0, 1.0, 0, 0.0, "P2POOL"),
            )
            state_manager._conn.commit()
        monkeypatch.setattr("mining_dashboard.service.storage_service.random.random", lambda: 0.0)
        state_manager.add_xvb_history(time.time(), avg_1h=5.0)
        with state_manager._db_lock:
            remaining = state_manager._conn.execute(
                "SELECT COUNT(*) FROM xvb_history WHERE ts < ?",
                (time.time() - HISTORY_RETENTION_SEC,),
            ).fetchone()[0]
        assert remaining == 0

    def test_write_error_flags_table_and_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE xvb_history")
        state_manager.add_xvb_history(time.time())
        assert state_manager.is_db_healthy() is False
        assert state_manager.get_table_health()["xvb_history"]["healthy"] is False

    def test_reads_tolerate_a_missing_table(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE xvb_history")
        assert state_manager.get_xvb_history() == []


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


class TestAuditEvents:
    """#530: the durable audit_events table backing the Security panel — mirrored control.log
    rows plus the out-of-band host-edit/rig-edit detections."""

    def test_add_and_get_round_trips(self, state_manager):
        state_manager.add_audit_event(
            id="ev-1",
            ts="2026-07-20T12:00:00Z",
            source="host-edit",
            actor="",
            action="host-edit",
            status="detected",
            keys="xvb.enabled",
        )
        events = state_manager.get_audit_events()
        assert len(events) == 1
        assert events[0]["id"] == "ev-1"
        assert events[0]["source"] == "host-edit"
        assert events[0]["keys"] == "xvb.enabled"

    def test_insert_or_ignore_is_idempotent_on_id(self, state_manager):
        # Re-mirroring the same control.log row (or re-detecting the same out-of-band event)
        # must not duplicate it.
        for _ in range(3):
            state_manager.add_audit_event(
                id="dup-1",
                ts="2026-07-20T12:00:00Z",
                source="control",
                actor="admin",
                action="commit",
                status="applied",
                keys="XVB_ENABLED",
            )
        assert len(state_manager.get_audit_events()) == 1

    def test_newest_first_by_ts(self, state_manager):
        state_manager.add_audit_event(
            id="a",
            ts="2026-07-01T00:00:00Z",
            source="control",
            actor="",
            action="commit",
            status="applied",
            keys="",
        )
        state_manager.add_audit_event(
            id="b",
            ts="2026-07-20T00:00:00Z",
            source="host-edit",
            actor="",
            action="host-edit",
            status="detected",
            keys="",
        )
        events = state_manager.get_audit_events()
        assert [e["id"] for e in events] == ["b", "a"]

    def test_limit_applies(self, state_manager):
        for i in range(5):
            state_manager.add_audit_event(
                id=f"ev-{i}",
                ts=f"2026-07-{i + 1:02d}T00:00:00Z",
                source="control",
                actor="",
                action="commit",
                status="applied",
                keys="",
            )
        assert len(state_manager.get_audit_events(limit=2)) == 2

    def test_write_error_flags_db_unhealthy(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE audit_events")
        state_manager.add_audit_event(
            id="x",
            ts="2026-07-20T00:00:00Z",
            source="control",
            actor="",
            action="commit",
            status="applied",
            keys="",
        )
        assert state_manager.is_db_healthy() is False

    def test_reads_and_writes_after_close_are_safe(self, state_manager):
        state_manager.close()
        state_manager.add_audit_event(
            id="x",
            ts="2026-07-20T00:00:00Z",
            source="control",
            actor="",
            action="commit",
            status="applied",
            keys="",
        )  # must not raise
        assert state_manager.get_audit_events() == []

    def test_read_error_returns_empty_list(self, state_manager):
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE audit_events")
        assert state_manager.get_audit_events() == []


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
