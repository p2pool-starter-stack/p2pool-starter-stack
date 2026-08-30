import time

import pytest

from mining_dashboard.config.config import TIER_DEFAULTS
from mining_dashboard.service.storage_service import StateManager


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

    def test_corrupt_snapshot_reads_as_none(self, state_manager):
        # A stored value that is not JSON reaches the caller as None rather than raising into the
        # restore path — the same answer an absent snapshot gives. #1551 rewrote load_snapshot to
        # read through ``get_kv``, which moved this decode onto its own branch; without this the
        # branch is unreached and the rewrite could have started raising here unnoticed.
        state_manager.set_kv("snapshot_latest_data", "{not json")
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
