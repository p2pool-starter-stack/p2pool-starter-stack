"""Append-only telemetry series storage (#196 backbone), split out of `storage_service.py`.

This is a MIXIN, not a facade: `StateManager` inherits it, so these methods keep the same
`self`, the same `_conn`, the same `_db_lock` and the same transaction scope they had when they
were defined inline. That distinction is what the #1105 "do not split `storage_service.py`"
ruling turns on — it refused a new seam between callers and the single DB handle, and a mixin
introduces none. Proven rather than asserted before the move (#1369): no method here holds a
transaction or cursor across a call into a method that stayed behind.

The boundary is the one the code already drew at `_TELEMETRY_TABLES`. Three of those five tables
move: `blocks` and `worker_history` stay in `storage_service.py`, because `worker_history` is
read by `get_worker_hashrate_by_config`, which is worker-config domain rather than telemetry.

`_table_write_ok` / `_table_write_failed` deliberately stay behind — retained writers (`blocks`,
`worker_history`) call them too, so they belong to the handle, not to this series. The writers
here call them through `self` AFTER their `with` blocks close, which is exactly why the
atomicity check comes back clean.
"""

import random
import sqlite3
from typing import Any

from mining_dashboard.config.config import HISTORY_RETENTION_SEC

# v1.7 telemetry backbone retention (#196 Wave-0 proposal), living with the writers that are its
# only consumers. disk_growth is permanent (no pruning — a small table, like payouts); the other
# two extend the existing 30-day HISTORY_RETENTION_SEC convention. Each table gets its OWN
# retention (independent of `history`'s), by design. Both names are re-exported from
# `storage_service` so that import surface is unchanged by the split (#1369).
XVB_HISTORY_RETENTION_SEC = HISTORY_RETENTION_SEC  # 30 days
NETWORK_HISTORY_RETENTION_SEC = 90 * 24 * 3600  # 90 days


class TelemetryStoreMixin:
    """The append-only telemetry accessors of `StateManager`. Never instantiated on its own."""

    def add_xvb_history(
        self,
        ts: float,
        avg_1h: float = 0.0,
        avg_24h: float = 0.0,
        fail_count: int = 0,
        donation_fraction: float = 0.0,
        mode: str = "",
    ) -> None:
        """Record one XvB-scalars sample (#196), 30-day retention. The caller wall-clock-gates
        this to ~5 min (DataService._sync_xvb_stats) so the cadence survives an UPDATE_INTERVAL
        change, and only calls it on a genuine XvB fetch (never on a failed one)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO xvb_history "
                        "(ts, avg_1h, avg_24h, fail_count, donation_fraction, mode) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        (ts, avg_1h, avg_24h, fail_count, donation_fraction, mode),
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM xvb_history WHERE ts < ?",
                            (ts - XVB_HISTORY_RETENTION_SEC,),
                        )
            self._table_write_ok("xvb_history", ts)
        except sqlite3.Error as e:
            self._table_write_failed("xvb_history", "XvB History Insert Error", e)

    def get_xvb_history(self, since: float = 0.0) -> list[dict[str, Any]]:
        """XvB-scalar samples at or after `since` (default: all), oldest first."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT ts, avg_1h, avg_24h, fail_count, donation_fraction, mode "
                    "FROM xvb_history WHERE ts >= ? ORDER BY ts ASC",
                    (since,),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"XvB History Read Error: {e}")
            return []

    def add_network_history(
        self,
        ts: float,
        difficulty: float = 0.0,
        height: int = 0,
        reward: float = 0.0,
        pool_hashrate: float = 0.0,
    ) -> None:
        """Record one hourly network-stats sample (#196): Monero difficulty/height/reward plus the
        pool's own hashrate. 90-day retention. DB-only (nothing reads this per-cycle)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO network_history "
                        "(ts, difficulty, height, reward, pool_hashrate) VALUES (?, ?, ?, ?, ?)",
                        (ts, difficulty, height, reward, pool_hashrate),
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM network_history WHERE ts < ?",
                            (ts - NETWORK_HISTORY_RETENTION_SEC,),
                        )
            self._table_write_ok("network_history", ts)
        except sqlite3.Error as e:
            self._table_write_failed("network_history", "Network History Insert Error", e)

    def get_network_history(self, since: float = 0.0) -> list[dict[str, Any]]:
        """Hourly network-stats samples at or after `since` (default: all), oldest first."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT ts, difficulty, height, reward, pool_hashrate FROM network_history "
                    "WHERE ts >= ? ORDER BY ts ASC",
                    (since,),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Network History Read Error: {e}")
            return []

    def add_disk_growth(
        self,
        ts: float,
        monero_db_bytes: int = 0,
        disk_used_gb: float = 0.0,
        disk_total_gb: float = 0.0,
    ) -> None:
        """Record one hourly disk-growth sample (#196): monerod's DB size plus host disk usage.
        Permanent (no retention prune — tiny, ~24 rows/day; it's a capacity trend line)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO disk_growth "
                        "(ts, monero_db_bytes, disk_used_gb, disk_total_gb) VALUES (?, ?, ?, ?)",
                        (ts, monero_db_bytes, disk_used_gb, disk_total_gb),
                    )
            self._table_write_ok("disk_growth", ts)
        except sqlite3.Error as e:
            self._table_write_failed("disk_growth", "Disk Growth Insert Error", e)

    def get_disk_growth(self, since: float = 0.0) -> list[dict[str, Any]]:
        """Hourly disk-growth samples at or after `since` (default: all), oldest first."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT ts, monero_db_bytes, disk_used_gb, disk_total_gb FROM disk_growth "
                    "WHERE ts >= ? ORDER BY ts ASC",
                    (since,),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Disk Growth Read Error: {e}")
            return []
