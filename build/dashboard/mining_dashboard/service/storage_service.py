import sqlite3
import threading
import logging
import json
import os
import time
import random
from collections import deque
from typing import Dict, List, Optional, Any
from config.config import DB_FILE_PATH, TIER_DEFAULTS, HISTORY_RETENTION_SEC, WORKER_RETENTION_SEC

class StateManager:
    """
    Manages persistent application state including hashrate history and mining mode statistics.
    
    Handles atomic file I/O to prevent data corruption and ensures state consistency
    across application restarts.
    """
    def __init__(self):
        self.logger = logging.getLogger("StateManager")
        self.db_path = DB_FILE_PATH
        self._lock = threading.Lock()
        self._db_lock = threading.Lock()  # Lock for serializing DB access
        self.state = {
            "hashrate_history": deque(),
            "known_workers": {}, # Persist worker IPs by name to prevent loss during XvB switching
            "xvb": {
                "total_donated_time": 0.0,
                "current_mode": "P2POOL",
                "avg_24h": 0.0,
                "avg_1h": 0.0,
                "fail_count": 0,
                "last_update": 0.0
            },
            # Initialize state with default values from configuration
            "tiers": TIER_DEFAULTS.copy()
        }
        
        # Initialize persistent DB connection
        # check_same_thread=False allows the connection to be used by multiple threads
        # (serialized via self._db_lock)
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
        except sqlite3.Error as e:
            self.logger.error(f"DB Init Error: {e}")

    def _create_tables(self):
        """Creates necessary tables if they don't exist."""
        self._conn.execute("CREATE TABLE IF NOT EXISTS history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL)")
        self._conn.execute("CREATE TABLE IF NOT EXISTS workers (name TEXT PRIMARY KEY, ip TEXT, last_seen REAL)")
        self._conn.execute("CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON history(timestamp)")

    def _migrate_db(self):
        """Handles schema migrations for existing databases."""
        cursor = self._conn.cursor()
        
        # History Table Migrations
        cursor.execute("PRAGMA table_info(history)")
        columns = {info[1] for info in cursor.fetchall()}
        
        if 'v_p2pool' not in columns:
            self.logger.info("Migrating DB: Adding v_p2pool column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN v_p2pool REAL DEFAULT 0")

        if 'v_xvb' not in columns:
            self.logger.info("Migrating DB: Adding v_xvb column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN v_xvb REAL DEFAULT 0")

        if 'timestamp' not in columns:
            self.logger.info("Migrating DB: Adding timestamp column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN timestamp REAL")
            self._conn.execute("UPDATE history SET timestamp = CAST(strftime('%s', t) AS REAL) WHERE timestamp IS NULL")
            self._conn.execute("UPDATE history SET timestamp = 0 WHERE timestamp IS NULL")
        
        # Workers Table Migrations
        cursor.execute("PRAGMA table_info(workers)")
        w_columns = {info[1] for info in cursor.fetchall()}
        if 'last_seen' not in w_columns:
            self.logger.info("Migrating DB: Adding last_seen column to workers")
            self._conn.execute("ALTER TABLE workers ADD COLUMN last_seen REAL")
            self._conn.execute("UPDATE workers SET last_seen = ?", (time.time(),))

    def load(self):
        """
        Loads state from SQLite into memory on startup.
        """
        try:
            with self._db_lock:
                if not self._conn: return
                cursor = self._conn.cursor()
                
                with self._lock:
                    # 1. Load History
                    # Limit to retention period to prevent memory bloat
                    history_cutoff = time.time() - HISTORY_RETENTION_SEC
                    cursor.execute("SELECT t, v, v_p2pool, v_xvb, timestamp FROM history WHERE timestamp > ? ORDER BY timestamp ASC", (history_cutoff,))
                    history = []
                    for row in cursor.fetchall():
                        item = dict(row)
                        # Sanitize NULLs to ensure chart stability
                        item["v_p2pool"] = item.get("v_p2pool") or 0.0
                        item["v_xvb"] = item.get("v_xvb") or 0.0
                        history.append(item)
                    self.state["hashrate_history"] = deque(history)

                    # 2. Load Workers
                    # Only load workers seen recently
                    worker_cutoff = time.time() - WORKER_RETENTION_SEC
                    cursor.execute("SELECT name, ip, last_seen FROM workers WHERE last_seen > ? OR last_seen IS NULL", (worker_cutoff,))
                    self.state["known_workers"] = {}
                    for row in cursor.fetchall():
                        self.state["known_workers"][row["name"]] = {
                            "ip": row["ip"],
                            "last_seen": row["last_seen"] if row["last_seen"] is not None else time.time()
                        }

                    # 3. Load XVB Stats (KV Store)
                    cursor.execute("SELECT key, value FROM kv_store WHERE key LIKE 'xvb_%'")
                    for row in cursor.fetchall():
                        key = row["key"]
                        if key.startswith("xvb_"):
                            key = key[4:]
                        
                        val = row["value"]
                        
                        # Migration: Handle legacy keys from previous versions
                        if key == "1h_avg": key = "avg_1h"
                        if key == "24h_avg": key = "avg_24h"

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
                    
                self.logger.info(f"State successfully loaded from {self.db_path}")
        except sqlite3.Error as e:
            self.logger.error(f"DB Load Error: {e}")

    def update_history(self, hashrate: float, p2pool_hr: float = 0, xvb_hr: float = 0):
        """Appends a new hashrate data point to the history buffer."""
        t_str = time.strftime('%Y-%m-%d %H:%M:%S')
        ts = time.time()
        
        try:
            v_val = round(float(hashrate), 2)
            v_p2p = round(float(p2pool_hr), 2)
            v_xvb = round(float(xvb_hr), 2)
        except (ValueError, TypeError):
            v_val, v_p2p, v_xvb = 0.0, 0.0, 0.0

        with self._lock:
            # 1. Update In-Memory State
            self.state["hashrate_history"].append({
                "t": t_str,
                "v": v_val,
                "v_p2pool": v_p2p,
                "v_xvb": v_xvb,
                "timestamp": ts
            })

            # Prune in-memory history to enforce retention policy
            cutoff = ts - HISTORY_RETENTION_SEC
            while self.state["hashrate_history"] and self.state["hashrate_history"][0]["timestamp"] < cutoff:
                self.state["hashrate_history"].popleft()

        # 2. Persist to DB
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO history (t, v, v_p2pool, v_xvb, timestamp) VALUES (?, ?, ?, ?, ?)",
                        (t_str, v_val, v_p2p, v_xvb, ts)
                    )
                    # Prune old history from DB to prevent unbounded growth (Probabilistic pruning to save I/O)
                    if random.random() < 0.05:
                        self._conn.execute("DELETE FROM history WHERE timestamp < ?", (ts - HISTORY_RETENTION_SEC,))
        except sqlite3.Error as e:
            self.logger.error(f"History Update Error: {e}")

    def get_xvb_stats(self) -> Dict[str, Any]:
        """Returns the current XvB mining statistics dictionary."""
        with self._lock:
            return self.state["xvb"].copy()

    def update_xvb_stats(self, mode: Optional[str] = None, avg_24h: Optional[float] = None, avg_1h: Optional[float] = None, fail_count: Optional[int] = None, **kwargs):
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

            stats_updated = False
            if avg_24h is not None:
                self.state["xvb"]["avg_24h"] = avg_24h
                updates["xvb_avg_24h"] = avg_24h
                stats_updated = True
                
            if avg_1h is not None:
                self.state["xvb"]["avg_1h"] = avg_1h
                updates["xvb_avg_1h"] = avg_1h
                stats_updated = True
            if fail_count is not None:
                self.state["xvb"]["fail_count"] = fail_count
                updates["xvb_fail_count"] = fail_count
                stats_updated = True
            
            # Handle additional fields passed via kwargs (e.g., total_donated_time)
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
                    stats_updated = True
                
            # Update timestamp only if statistical data changed
            if stats_updated:
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
                        self._conn.executemany("INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)", 
                                         [(k, str(v)) for k, v in updates.items()])
            except sqlite3.Error as e:
                self.logger.error(f"XVB Update Error: {e}")

    def update_known_workers(self, workers_list: List[Dict[str, str]]):
        """
        Updates the list of known workers.
        
        Args:
            workers_list (list): List of dicts [{'name': '...', 'ip': '...'}, ...]
        """
        if workers_list is None:
            workers_list = []
        ts = time.time()
        to_upsert = []
        
        with self._lock:
            for w in workers_list:
                name = w.get('name')
                ip = w.get('ip')
                if name and ip:
                    # Update memory
                    self.state["known_workers"][name] = {"ip": ip, "last_seen": ts}
                    
                    # Always update DB timestamp for active workers
                    to_upsert.append((name, ip, ts))
            
            # Prune old workers from memory
            cutoff = ts - WORKER_RETENTION_SEC
            to_remove = [k for k, v in self.state["known_workers"].items() if v["last_seen"] < cutoff]
            for k in to_remove:
                del self.state["known_workers"][k]
        
        if to_upsert:
            try:
                with self._db_lock:
                    if not self._conn:
                        return
                    with self._conn:
                        self._conn.executemany("INSERT OR REPLACE INTO workers (name, ip, last_seen) VALUES (?, ?, ?)", to_upsert)
                        # Prune old workers from DB
                        self._conn.execute("DELETE FROM workers WHERE last_seen < ?", (ts - WORKER_RETENTION_SEC,))
            except sqlite3.Error as e:
                self.logger.error(f"Worker Update Error: {e}")

    def save_snapshot(self, data: Dict[str, Any]):
        """Persists the full application state snapshot to the KV store."""
        if not data:
            return
        try:
            json_str = json.dumps(data)
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute("INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)", 
                                     ("snapshot_latest_data", json_str))
        except (TypeError, sqlite3.Error) as e:
            self.logger.error(f"Snapshot Save Error: {e}")

    def load_snapshot(self) -> Optional[Dict[str, Any]]:
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

    def get_known_workers(self) -> List[Dict[str, str]]:
        """Returns a list of worker dicts for the collector."""
        with self._lock:
            return [{"name": k, "ip": v["ip"]} for k, v in self.state["known_workers"].items()]

    def get_history(self) -> List[Dict[str, Any]]:
        """Returns a copy of the hashrate history."""
        with self._lock:
            return list(self.state["hashrate_history"])

    def get_tiers(self) -> Dict[str, Any]:
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
