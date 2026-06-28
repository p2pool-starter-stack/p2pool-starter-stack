import json
import logging
import random
import sqlite3
import threading
import time
from collections import deque
from typing import Any

from mining_dashboard.config.config import (
    DB_FILE_PATH,
    HASHRATE_WINDOW_COLUMNS,
    HISTORY_RETENTION_SEC,
    TIER_DEFAULTS,
)

# The 10m window reuses the original v_p2pool/v_xvb pair; every other window in
# HASHRATE_WINDOW_COLUMNS gets its own additive history column (#168). This flat, insertion-ordered
# list drives the CREATE, the migration, the INSERT, and the SELECT so they can never drift apart.
_BASE_HISTORY_COLS = {"v_p2pool", "v_xvb"}
_WINDOW_EXTRA_COLUMNS = [
    col
    for pair in HASHRATE_WINDOW_COLUMNS.values()
    for col in pair
    if col not in _BASE_HISTORY_COLS
]


class StateManager:
    """
    Manages persistent application state including hashrate history and mining mode statistics.

    Handles atomic file I/O to prevent data corruption and ensures state consistency
    across application restarts.
    """

    def __init__(self, db_path: str = None):
        self.logger = logging.getLogger("StateManager")
        # Default to the configured path; tests inject a temp file or ":memory:".
        self.db_path = db_path if db_path is not None else DB_FILE_PATH
        self._lock = threading.Lock()
        self._db_lock = threading.Lock()  # Lock for serializing DB access
        self.state = {
            "hashrate_history": deque(),
            "shares": [],
            "xvb": {
                "total_donated_time": 0.0,
                "current_mode": "P2POOL",
                "avg_24h": 0.0,
                "avg_1h": 0.0,
                "fail_count": 0,
                "last_update": 0.0,
                # Unix ts of the last successful XvB raffle registration (#263); 0.0 until the
                # wallet is first auto-registered. Lets the UI show "Registered with XvB ✓".
                "registered_at": 0.0,
                # Registration status for the dashboard badge (#263): "" (not yet / pending),
                # "registered", "unconfigured" (no XVB_SUBMIT_URL), or "failing" (endpoint refusing).
                "registration_state": "",
                # Fraction of the current cycle routed to XvB, written by the
                # controller each cycle. Lets the dashboard show what we *send*
                # (routed) next to what XvB *credits* (avg_1h/24h) — the live
                # credit-factor signal (Issue #70).
                "donation_fraction": 0.0,
            },
            # Initialize state with default values from configuration
            "tiers": TIER_DEFAULTS.copy(),
        }

        # Initialize persistent DB connection
        # check_same_thread=False allows the connection to be used by multiple threads
        # (serialized via self._db_lock)
        # Persistence-health flag (#131): flipped False on any init/write failure so /api/state can
        # surface "history isn't being saved" instead of silently losing everything on the next restart.
        self.db_healthy = True

        self._conn = sqlite3.connect(self.db_path, timeout=30.0, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row

        self._init_db()
        self.load()

    def _init_db(self):
        """Initializes the SQLite database schema and handles migrations."""
        try:
            with self._db_lock:
                # Enable WAL mode for better concurrency
                self._conn.execute("PRAGMA journal_mode=WAL")
                self._conn.execute("PRAGMA synchronous=NORMAL")

                with self._conn:
                    self._create_tables()
                    self._migrate_db()
                    # Indexes come AFTER migration: idx_ts is on history(timestamp), a column
                    # _migrate_db adds when upgrading a pre-timestamp DB. Creating it in
                    # _create_tables would throw "no such column: timestamp" on that old schema
                    # and abort the whole migration, leaving the DB half-upgraded.
                    self._create_indexes()
        except sqlite3.Error as e:
            self._db_error("DB Init Error", e)

    def _db_error(self, where: str, e: Exception):
        """Record a DB failure and flag persistence as unhealthy so /api/state can surface it (#131)."""
        self.db_healthy = False
        self.logger.error(f"{where}: {e}")

    def is_db_healthy(self) -> bool:
        """True unless a DB init or write has failed — drives the dashboard persistence badge (#131)."""
        return self.db_healthy

    def _create_tables(self):
        """Creates necessary tables if they don't exist."""
        # Per-window hashrate columns (#168) are appended so a fresh DB starts with them; existing
        # DBs get them via _migrate_db. Same source list (_WINDOW_EXTRA_COLUMNS) for both paths.
        extra = "".join(f", {c} REAL DEFAULT 0" for c in _WINDOW_EXTRA_COLUMNS)
        self._conn.execute(
            f"CREATE TABLE IF NOT EXISTS history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL{extra})"
        )
        self._conn.execute("CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)")
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS shares (ts REAL PRIMARY KEY, difficulty REAL)"
        )

    def _create_indexes(self):
        """Creates indexes. Called after migrations so the indexed columns are guaranteed to
        exist even on a database created by an older schema version."""
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON history(timestamp)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_share_ts ON shares(ts)")

    def _migrate_db(self):
        """Handles schema migrations for existing databases."""
        cursor = self._conn.cursor()

        # History Table Migrations
        cursor.execute("PRAGMA table_info(history)")
        columns = {info[1] for info in cursor.fetchall()}

        if "v_p2pool" not in columns:
            self.logger.info("Migrating DB: Adding v_p2pool column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN v_p2pool REAL DEFAULT 0")

        if "v_xvb" not in columns:
            self.logger.info("Migrating DB: Adding v_xvb column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN v_xvb REAL DEFAULT 0")

        if "timestamp" not in columns:
            self.logger.info("Migrating DB: Adding timestamp column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN timestamp REAL")
            self._conn.execute(
                "UPDATE history SET timestamp = CAST(strftime('%s', t) AS REAL) WHERE timestamp IS NULL"
            )
            self._conn.execute("UPDATE history SET timestamp = 0 WHERE timestamp IS NULL")

        # Per-window hashrate columns (#168) — additive, forward-only. Pre-existing rows keep DEFAULT
        # 0 (no per-window data was captured before this version); the chart signposts that.
        for col in _WINDOW_EXTRA_COLUMNS:
            if col not in columns:
                self.logger.info(f"Migrating DB: Adding {col} column to history")
                self._conn.execute(f"ALTER TABLE history ADD COLUMN {col} REAL DEFAULT 0")

        # Drop the orphaned `workers` table (#144). It backed the known_workers persistence layer,
        # which was dead code — the worker list is sourced live from the xmrig-proxy. Tidies old
        # DBs; harmless no-op on fresh ones.
        self._conn.execute("DROP TABLE IF EXISTS workers")

    def load(self):
        """
        Loads state from SQLite into memory on startup.
        """
        try:
            with self._db_lock:
                if not self._conn:
                    return
                cursor = self._conn.cursor()

                with self._lock:
                    # 1. Load History
                    # Limit to retention period to prevent memory bloat
                    history_cutoff = time.time() - HISTORY_RETENTION_SEC
                    hist_cols = ", ".join(
                        ["t", "v", "v_p2pool", "v_xvb", "timestamp"] + _WINDOW_EXTRA_COLUMNS
                    )
                    cursor.execute(
                        # Column list is literals + a module constant, never user input; value is ?-bound.
                        f"SELECT {hist_cols} FROM history WHERE timestamp > ? ORDER BY timestamp ASC",  # noqa: S608
                        (history_cutoff,),
                    )
                    history = []
                    for row in cursor.fetchall():
                        item = dict(row)
                        # Sanitize NULLs to ensure chart stability (the per-window columns are NULL on
                        # pre-#168 rows and 0 thereafter — both read as 0 for the chart).
                        item["v_p2pool"] = item.get("v_p2pool") or 0.0
                        item["v_xvb"] = item.get("v_xvb") or 0.0
                        for col in _WINDOW_EXTRA_COLUMNS:
                            item[col] = item.get(col) or 0.0
                        history.append(item)
                    self.state["hashrate_history"] = deque(history)

                    # 2. Load XVB Stats (KV Store)
                    cursor.execute("SELECT key, value FROM kv_store WHERE key LIKE 'xvb_%'")
                    for row in cursor.fetchall():
                        key = row["key"]
                        if key.startswith("xvb_"):
                            key = key[4:]

                        val = row["value"]

                        # Migration: Handle legacy keys from previous versions
                        if key == "1h_avg":
                            key = "avg_1h"
                        if key == "24h_avg":
                            key = "avg_24h"

                        # Enforce schema: Ignore keys not present in the default state
                        if key not in self.state["xvb"]:
                            continue

                        try:
                            # Dynamic type restoration based on default value type
                            default_val = self.state["xvb"][key]
                            if isinstance(default_val, bool):
                                val = val.lower() == "true"
                            elif isinstance(default_val, float):
                                val = float(val)
                            elif isinstance(default_val, int):
                                val = int(val)
                            self.state["xvb"][key] = val
                        except (ValueError, TypeError):
                            self.logger.warning(f"Skipping corrupted KV pair: {key}={val}")

                    # 3. Load Shares
                    cursor.execute(
                        "SELECT ts, difficulty FROM shares WHERE ts > ? ORDER BY ts ASC",
                        (history_cutoff,),
                    )
                    self.state["shares"] = [dict(row) for row in cursor.fetchall()]

                self.logger.info(f"State successfully loaded from {self.db_path}")
        except sqlite3.Error as e:
            self.logger.error(f"DB Load Error: {e}")

    def update_history(
        self, hashrate: float, p2pool_hr: float = 0, xvb_hr: float = 0, windows=None
    ):
        """Appends a new hashrate data point to the history buffer.

        ``windows`` (Issue #168) is an optional ``{window: (p2pool_hr, xvb_hr)}`` mapping of the
        per-averaging-window splits (1m / 1h / 12h / 24h — the 10m window is the base
        ``p2pool_hr``/``xvb_hr`` pair above). Each is stored in its own column so the chart's window
        toggle can plot a true average per window; an omitted/unknown window defaults to 0.
        """
        t_str = time.strftime("%Y-%m-%d %H:%M:%S")
        ts = time.time()

        try:
            v_val = round(float(hashrate), 2)
            v_p2p = round(float(p2pool_hr), 2)
            v_xvb = round(float(xvb_hr), 2)
        except (ValueError, TypeError):
            v_val, v_p2p, v_xvb = 0.0, 0.0, 0.0

        # Per-window splits -> their columns (#168). Default every extra column to 0, then fill the
        # windows we were handed; a bad value falls back to 0 rather than aborting the whole write.
        extra = {col: 0.0 for col in _WINDOW_EXTRA_COLUMNS}
        for win, split in (windows or {}).items():
            cols = HASHRATE_WINDOW_COLUMNS.get(win)
            if not cols:
                continue
            p_col, x_col = cols
            try:
                if p_col in extra:
                    extra[p_col] = round(float(split[0]), 2)
                if x_col in extra:
                    extra[x_col] = round(float(split[1]), 2)
            except (ValueError, TypeError, IndexError):
                pass

        with self._lock:
            # 1. Update In-Memory State
            self.state["hashrate_history"].append(
                {
                    "t": t_str,
                    "v": v_val,
                    "v_p2pool": v_p2p,
                    "v_xvb": v_xvb,
                    "timestamp": ts,
                    **extra,
                }
            )

            # Prune in-memory history to enforce retention policy
            cutoff = ts - HISTORY_RETENTION_SEC
            while (
                self.state["hashrate_history"]
                and self.state["hashrate_history"][0]["timestamp"] < cutoff
            ):
                self.state["hashrate_history"].popleft()

        # 2. Persist to DB
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    cols = ["t", "v", "v_p2pool", "v_xvb", "timestamp"] + _WINDOW_EXTRA_COLUMNS
                    placeholders = ", ".join("?" * len(cols))
                    values = (t_str, v_val, v_p2p, v_xvb, ts) + tuple(
                        extra[c] for c in _WINDOW_EXTRA_COLUMNS
                    )
                    self._conn.execute(
                        # Column/placeholder lists are literals + a module constant, not user input.
                        f"INSERT INTO history ({', '.join(cols)}) VALUES ({placeholders})",  # noqa: S608
                        values,
                    )
                    # Prune old history from DB to prevent unbounded growth (Probabilistic pruning to save I/O)
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM history WHERE timestamp < ?", (ts - HISTORY_RETENTION_SEC,)
                        )
        except sqlite3.Error as e:
            self._db_error("History Update Error", e)

    def add_share(self, ts: float, difficulty: float):
        """Appends a new share to history and persists it to the DB."""
        with self._lock:
            # Check if share already exists to prevent duplicate in-memory appends
            if not any(s["ts"] == ts for s in self.state.get("shares", [])):
                self.state["shares"].append({"ts": ts, "difficulty": difficulty})

            # Prune in-memory state based on the 30-day config
            cutoff = time.time() - HISTORY_RETENTION_SEC
            self.state["shares"] = [s for s in self.state["shares"] if s["ts"] >= cutoff]

        # Persist to DB
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT OR IGNORE INTO shares (ts, difficulty) VALUES (?, ?)",
                        (ts, difficulty),
                    )

                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM shares WHERE ts < ?",
                            (time.time() - HISTORY_RETENTION_SEC,),
                        )
        except sqlite3.Error as e:
            self._db_error("Share Insert Error", e)

    def add_shares(self, count: int, latest_ts: float, difficulty: float):
        """Record `count` shares ending at `latest_ts`. P2Pool's stratum exposes a CUMULATIVE
        shares_found counter; the dashboard polls every UPDATE_INTERVAL (30s), so a burst of shares
        between polls advances last_share_found_time only once. Spread the count across distinct
        timestamps (the shares table is keyed by ts) so a higher-hashrate / nano-sidechain node's
        extra shares in one window aren't dropped (#129)."""
        if count <= 0:
            return
        for i in range(count):
            # Distinct timestamps ending at latest_ts (1 ms steps back) so the ts PRIMARY KEY keeps all.
            self.add_share(round(latest_ts - 0.001 * (count - 1 - i), 3), difficulty)

    def get_shares(self) -> list[dict[str, Any]]:
        """Returns a copy of the shares history."""
        with self._lock:
            return list(self.state.get("shares", []))

    def get_xvb_stats(self) -> dict[str, Any]:
        """Returns the current XvB mining statistics dictionary."""
        with self._lock:
            return self.state["xvb"].copy()

    def update_xvb_stats(
        self,
        mode: str | None = None,
        avg_24h: float | None = None,
        avg_1h: float | None = None,
        fail_count: int | None = None,
        **kwargs,
    ):
        """
        Updates specific fields within the XvB statistics state.

        Allows partial updates to decouple mode switching from statistical updates.

        Args:
            mode (str, optional): The current mining mode (e.g., "P2POOL", "XVB").
            avg_24h (float, optional): 24-hour average hashrate on XvB.
            avg_1h (float, optional): 1-hour average hashrate on XvB.
            fail_count (int, optional): Consecutive failure count for XvB endpoint.
            **kwargs: Updates for other keys in the xvb state (e.g., total_donated_time).
        """
        updates = {}
        with self._lock:
            if mode is not None:
                self.state["xvb"]["current_mode"] = mode
                updates["xvb_current_mode"] = mode

            # `last_update` is the "Stats fetched from xmrvsbeast.com (Updated: …)" timestamp, so it
            # must bump ONLY on a real fetch — never on the per-cycle local writes the algo controller
            # makes (mode, donation_fraction, fail_count). Otherwise the UI's "Updated" time ticks
            # fresh every cycle even while xmrvsbeast.com is unreachable, hiding stale data (#136). A
            # successful xvb_client.get_stats is the only source of avg_1h / avg_24h, so those — and
            # only those — mark a genuine fetch.
            fetched = False
            if avg_24h is not None:
                self.state["xvb"]["avg_24h"] = avg_24h
                updates["xvb_avg_24h"] = avg_24h
                fetched = True

            if avg_1h is not None:
                self.state["xvb"]["avg_1h"] = avg_1h
                updates["xvb_avg_1h"] = avg_1h
                fetched = True
            if fail_count is not None:
                self.state["xvb"]["fail_count"] = fail_count
                updates["xvb_fail_count"] = fail_count

            # Handle additional fields passed via kwargs (e.g., total_donated_time, donation_fraction).
            # These are local/derived writes, NOT a fetch, so they must not bump `last_update`.
            for k, v in kwargs.items():
                if k in self.state["xvb"] and k != "current_mode":
                    # Skip None values to prevent type corruption in DB (persisted as "None" string)
                    if v is None:
                        continue

                    # Enforce type consistency with initialized state to prevent runtime drift
                    default_val = self.state["xvb"][k]
                    try:
                        if isinstance(default_val, float):
                            v = float(v)
                        elif isinstance(default_val, int) and not isinstance(default_val, bool):
                            v = int(v)
                    except (ValueError, TypeError):
                        pass  # Keep original value if cast fails

                    self.state["xvb"][k] = v
                    updates[f"xvb_{k}"] = v

            # Bump the freshness timestamp only on a genuine xmrvsbeast.com fetch (#136).
            if fetched:
                ts = time.time()
                self.state["xvb"]["last_update"] = ts
                updates["xvb_last_update"] = ts

        # Persist to DB
        if updates:
            try:
                with self._db_lock:
                    if not self._conn:
                        return
                    with self._conn:
                        self._conn.executemany(
                            "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)",
                            [(k, str(v)) for k, v in updates.items()],
                        )
            except sqlite3.Error as e:
                self._db_error("XVB Update Error", e)

    def save_snapshot(self, data: dict[str, Any]):
        """Persists the full application state snapshot to the KV store."""
        if not data:
            return
        try:
            json_str = json.dumps(data)
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)",
                        ("snapshot_latest_data", json_str),
                    )
        except sqlite3.Error as e:
            self._db_error("Snapshot Save Error", e)
        except TypeError as e:
            self.logger.error(f"Snapshot serialization error: {e}")

    def load_snapshot(self) -> dict[str, Any] | None:
        """Loads the last persisted application state snapshot."""
        try:
            with self._db_lock:
                if not self._conn:
                    return None
                cursor = self._conn.cursor()
                cursor.execute("SELECT value FROM kv_store WHERE key = 'snapshot_latest_data'")
                row = cursor.fetchone()
                if row and row[0]:
                    return json.loads(row[0])
        except (json.JSONDecodeError, sqlite3.Error) as e:
            self.logger.error(f"Snapshot Load Error: {e}")
        return None

    def get_history(self) -> list[dict[str, Any]]:
        """Returns a copy of the hashrate history."""
        with self._lock:
            return list(self.state["hashrate_history"])

    def get_tiers(self) -> dict[str, Any]:
        """Returns a copy of the donation tiers configuration."""
        with self._lock:
            return self.state["tiers"].copy()

    def close(self):
        """Closes the database connection safely."""
        with self._db_lock:
            if self._conn:
                try:
                    self._conn.close()
                    self.logger.info("Database connection closed.")
                except sqlite3.Error as e:
                    self.logger.error(f"Error closing database: {e}")
                finally:
                    self._conn = None
