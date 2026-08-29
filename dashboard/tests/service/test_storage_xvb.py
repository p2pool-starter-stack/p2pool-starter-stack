"""XvB stats, warm standby, history, raffle wins and payouts in the StateManager store
(#1105 Phase 3, cut D6).

These five classes moved 1:1 and byte-identical out of ``tests/service/test_storage_service.py``,
which remains the master module for the core tables.  Nothing was edited in the move: the subject
module ``mining_dashboard/service/storage_service.py`` is NOT split, so no name is repointed.

Unlike the D2-D5 cuts there is no duplicated fixture block here.  ``state_manager`` and the autouse
``_isolate_db`` are defined in ``dashboard/tests/conftest.py`` -- the tests-ROOT conftest -- which
every module under ``dashboard/tests/`` inherits, so the standing duplicate-the-builders ruling
costs this cut nothing but its import block.
"""

import time

from mining_dashboard.config.config import HISTORY_RETENTION_SEC
from mining_dashboard.service import storage_service
from mining_dashboard.service.storage_service import StateManager


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
