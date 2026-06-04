import time

import pytest

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.config.config import TIER_DEFAULTS


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


class TestSharesAndHistory:
    def test_add_share_and_dedup(self, state_manager):
        ts = time.time()
        state_manager.add_share(ts, 500)
        state_manager.add_share(ts, 500)  # duplicate ts
        shares = state_manager.get_shares()
        assert len(shares) == 1
        assert shares[0]["difficulty"] == 500

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


class TestWorkers:
    def test_update_and_get_known_workers(self, state_manager):
        state_manager.update_known_workers([{"name": "rig1", "ip": "10.0.0.1"}])
        workers = state_manager.get_known_workers()
        assert workers == [{"name": "rig1", "ip": "10.0.0.1"}]

    def test_worker_without_ip_skipped(self, state_manager):
        state_manager.update_known_workers([{"name": "rig1"}, {"ip": "10.0.0.2"}])
        assert state_manager.get_known_workers() == []

    def test_none_list_is_noop(self, state_manager):
        state_manager.update_known_workers(None)
        assert state_manager.get_known_workers() == []


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
        sm1.save_snapshot({
            "workers": [{"name": "rig1", "ip": "10.0.0.1", "status": "online",
                         "accepted": 1234, "rejected": 5, "invalid": 0}],
            "proxy_summary": {"accepted": 12345, "rejected": 67, "invalid": 2,
                              "expired": 1, "best": 9876543},
        })
        sm1.close()

        snap = StateManager(db_path=db).load_snapshot()  # fresh instance -> reads from disk
        assert snap["workers"][0]["accepted"] == 1234
        assert snap["workers"][0]["rejected"] == 5
        assert snap["proxy_summary"] == {"accepted": 12345, "rejected": 67, "invalid": 2,
                                         "expired": 1, "best": 9876543}


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
