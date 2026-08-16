import bisect
import json
import logging
import os
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

# Substrings SQLite uses when the DB file itself is unusable — a corrupted page, a truncated/rewritten
# file, or a non-DB where the DB should be (#489). Matched case-insensitively against the error text
# so an operations-eating corruption auto-heals (quarantine + fresh DB) instead of erroring on every
# write cycle forever. A transient error (locked, disk full, permissions) is NOT here: those are the
# db_unhealthy path — retryable, not a reason to throw away history.
_CORRUPTION_MARKERS = ("malformed", "not a database", "image is malformed", "file is encrypted")
# How many quarantined copies of a corrupt DB to keep for post-mortem before pruning the oldest.
_CORRUPT_KEEP = 3

# v1.7 telemetry backbone retention (#196 Wave-0 proposal). blocks/disk_growth are permanent (no
# pruning — small tables, like payouts); the rest extend the existing 30-day HISTORY_RETENTION_SEC
# convention. Each table gets its OWN retention (independent of `history`'s), by design.
XVB_HISTORY_RETENTION_SEC = HISTORY_RETENTION_SEC  # 30 days
WORKER_HISTORY_RETENTION_SEC = HISTORY_RETENTION_SEC  # 30 days
NETWORK_HISTORY_RETENTION_SEC = 90 * 24 * 3600  # 90 days

# raffle_wins is permanent-in-practice like payouts, but its rows are mirrored from an UNTRUSTED
# public file (see client/xvb_client.parse_winners), so it is bounded by row count instead of
# unbounded: keep the newest N. Decades of legit wins fit; a hostile feed cannot grow it past this.
RAFFLE_WINS_MAX_ROWS = 5000

# Table names carrying a per-table write-health signal (see __init__ / _table_write_ok below).
_TELEMETRY_TABLES = ("blocks", "xvb_history", "network_history", "disk_growth", "worker_history")

# The full terminal vocabulary the rig's control mirror can report (#1009) — applied/rejected/
# rolled_back/failed from a control-apply, plus noop (already on target)/throttled (retry-later)
# from a control-upgrade (rigforge#320). Mirrors xmrig_client._CONTROL_TERMINAL and pithead's own
# control_worker_apply/control_worker_upgrade poll cases (#1001) — one vocabulary, three places.
_RECONCILE_TERMINAL = ("applied", "rejected", "rolled_back", "failed", "noop", "throttled")


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
            "events": [],  # degradation / recovery markers for the chart (#99)
            "share_stats": [],  # per-poll accepted/rejected/invalid/expired deltas (#116)
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
                # Registration status for the dashboard badge (#263): "" (pending), "registered",
                # "invalid" (endpoint rejected the wallet), or "failing" (endpoint erroring).
                "registration_state": "",
                # Fraction of the current cycle routed to XvB, written by the
                # controller each cycle. Lets the dashboard show what we *send*
                # (routed) next to what XvB *credits* (avg_1h/24h) — the live
                # credit-factor signal (Issue #70).
                "donation_fraction": 0.0,
                # The controller's own last-COMMANDED donation fraction — the closed-loop
                # integrator state (AlgoService.donation_fraction), distinct from the routed
                # fraction above. Persisted so a restart resumes the warmed-up split instead of
                # re-seeding cold from the feedforward estimate, and so a backup stack can hand it
                # off on failover (#249). 0.0 until the controller first steers.
                "commanded_fraction": 0.0,
            },
            # Initialize state with default values from configuration
            "tiers": TIER_DEFAULTS.copy(),
        }

        # XvB's published per-tier expected rewards (#118), fetched over Tor each cycle. Kept in
        # memory only (NOT the DB): it's re-fetched constantly and derived from an external file, so
        # losing it on restart just costs one refetch. ``last_update`` bumps only on a genuine fetch,
        # so the same staleness check as the stats (``xvb_stats_are_stale``) applies to it (#311).
        self._xvb_rewards = {"estimates": {}, "last_update": 0.0}
        # All-rounds aggregate from the same winners file (#866/#872): round-type frequencies +
        # qualifier counts. Same memory-only, refetch-on-restart, staleness-by-last_update rules.
        self._xvb_round_stats = {"stats": {}, "last_update": 0.0}

        # Initialize persistent DB connection
        # check_same_thread=False allows the connection to be used by multiple threads
        # (serialized via self._db_lock)
        # Persistence-health flag (#131): flipped False on any init/write failure so /api/state can
        # surface "history isn't being saved" instead of silently losing everything on the next restart.
        self.db_healthy = True

        # DB self-heal (#489): a corrupt DB used to error on every write forever, silently losing all
        # telemetry (and the DB now holds XvB-credited + payout state). On integrity loss we quarantine
        # the bad file and start fresh. ``db_reset_count`` is a monotonic one-shot the alerter edges on
        # so the operator is told history was reset (a plain db_healthy flip can be missed — a startup
        # reset has no prior state, a runtime reset flips back to healthy within one cycle).
        self.db_reset_count = 0
        self.last_db_reset = (
            None  # {"ts", "reason", "quarantine"} of the most recent reset, for the alert
        )

        # True only when the auto-heal RECOVERY ITSELF just failed (disk full, permissions) —
        # distinct from ``db_healthy``, which also flips false on an ordinary transient write
        # error (a locked DB, a momentary I/O hiccup) that must never be treated as unrecoverable.
        # This is the narrow signal `dashboard.fail_closed` (#490) gates on: a DB that a corruption
        # was DETECTED for and whose rebuild then failed, not merely "a write failed once". Cleared
        # on the next recovery attempt that succeeds.
        self.db_unrecoverable = False

        # Per-table "last successful write" health signal for the v1.7 telemetry backbone (#196
        # Wave-0), mirroring db_healthy above but per table: DataService's whole poll loop is one
        # big try/except, so a capture hook that starts silently raising would otherwise stop
        # writing forever with no visible symptom. `healthy` flips False on a write failure
        # (routed through _db_error, so it also trips the global #131 badge); `last_write` is the
        # wall-clock of the last successful write, None until the first one lands.
        self.table_health = {
            name: {"healthy": True, "last_write": None} for name in _TELEMETRY_TABLES
        }

        self._conn = sqlite3.connect(self.db_path, timeout=30.0, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row

        self._init_db()
        self.load()

    def _apply_schema(self):
        """Set pragmas + create/migrate the schema on the open connection. Caller holds ``_db_lock``.

        Split out of ``_init_db`` so the recovery path (#489) can rebuild the schema on a freshly
        reconnected DB without re-entering the (non-reentrant) lock via ``_init_db``."""
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

    def _init_db(self):
        """Initializes the SQLite database schema and handles migrations.

        Runs an integrity check first (#489): a DB corrupted while the dashboard was down would
        otherwise fail on the first write and error every cycle thereafter. A malformed DB — caught by
        the check or by a corruption error while applying the schema — is quarantined and rebuilt fresh
        rather than left broken."""
        try:
            with self._db_lock:
                self._check_integrity()
                self._apply_schema()
        except sqlite3.Error as e:
            if self._is_corruption_error(e):
                self._recover_corrupt_db(f"startup: {e}")
            else:
                self._db_error("DB Init Error", e)

    @staticmethod
    def _is_corruption_error(e: Exception) -> bool:
        """True when the error means the DB file itself is unusable (vs. a retryable write failure)."""
        text = str(e).lower()
        return any(marker in text for marker in _CORRUPTION_MARKERS)

    def _check_integrity(self):
        """Raise ``sqlite3.DatabaseError`` if ``PRAGMA integrity_check`` doesn't return ``ok``.

        A DB can be malformed yet still open and answer simple queries, so this surfaces corruption
        proactively at startup. ``:memory:`` and a brand-new empty file both report ``ok``. Caller
        holds ``_db_lock``."""
        row = self._conn.execute("PRAGMA integrity_check").fetchone()
        result = (row[0] if row else "") or ""
        if result != "ok":
            # Phrase it with a corruption marker so _is_corruption_error routes it to recovery.
            raise sqlite3.DatabaseError(
                f"integrity_check reported the database is malformed: {result}"
            )

    def _recover_corrupt_db(self, reason: str):
        """Quarantine a corrupt DB file and rebuild an empty schema so persistence resumes (#489).

        The bad file is renamed to ``<db>.corrupt-<UTC>`` (kept for post-mortem, oldest pruned) rather
        than deleted, and a fresh DB takes its place. Bumps ``db_reset_count`` so the alerter tells the
        operator history was reset. A ``:memory:`` DB has no file to quarantine — it just rebuilds. On
        any failure here the DB stays flagged unhealthy (the #131 badge) rather than crashing."""
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        quarantine = None
        try:
            with self._db_lock:
                try:
                    if self._conn:
                        self._conn.close()
                except sqlite3.Error:
                    pass
                self._conn = None
                if self.db_path != ":memory:" and os.path.exists(self.db_path):
                    quarantine = f"{self.db_path}.corrupt-{stamp}"
                    os.replace(self.db_path, quarantine)
                    # WAL/SHM siblings of a corrupt DB are meaningless without it — drop them so the
                    # fresh DB doesn't inherit a stale write-ahead log.
                    for sfx in ("-wal", "-shm"):
                        try:
                            os.remove(self.db_path + sfx)
                        except OSError:
                            pass
                    self._prune_quarantined()
                self._conn = sqlite3.connect(self.db_path, timeout=30.0, check_same_thread=False)
                self._conn.row_factory = sqlite3.Row
                self._apply_schema()
            self.db_healthy = True
            self.db_unrecoverable = False  # a later successful attempt clears an earlier failure
            self.db_reset_count += 1
            self.last_db_reset = {"ts": time.time(), "reason": reason, "quarantine": quarantine}
            self.logger.error(
                "DB corruption recovered (%s): quarantined to %s, started a fresh database — "
                "hashrate history and stats before now were lost.",
                reason,
                quarantine or "(in-memory, nothing to quarantine)",
            )
        except (sqlite3.Error, OSError) as e:
            # Recovery itself failed (disk full, permissions) — this is the unrecoverable case
            # #490's fail-closed gate watches for, distinct from an ordinary transient write error.
            self.db_unrecoverable = True
            self._db_error("DB Recovery Error", e)

    def _prune_quarantined(self):
        """Keep only the newest ``_CORRUPT_KEEP`` ``<db>.corrupt-*`` files; delete older ones."""
        directory = os.path.dirname(self.db_path) or "."
        base = os.path.basename(self.db_path) + ".corrupt-"
        try:
            stale = sorted(f for f in os.listdir(directory) if f.startswith(base))
        except OSError:
            return
        for name in stale[: max(0, len(stale) - _CORRUPT_KEEP)]:
            try:
                os.remove(os.path.join(directory, name))
            except OSError:
                pass

    def _db_error(self, where: str, e: Exception):
        """Record a DB failure and flag persistence as unhealthy so /api/state can surface it (#131).

        A corruption error (malformed file) triggers auto-recovery (#489) — quarantine + fresh DB —
        so a corrupt DB self-heals instead of erroring on every write cycle indefinitely. ``where ==
        "DB Recovery Error"`` is excluded so a failed recovery can't recurse."""
        self.db_healthy = False
        self.logger.error(f"{where}: {e}")
        if where != "DB Recovery Error" and self._is_corruption_error(e):
            self._recover_corrupt_db(f"{where}: {e}")

    def is_db_healthy(self) -> bool:
        """True unless a DB init or write has failed — drives the dashboard persistence badge (#131)."""
        return self.db_healthy

    def is_db_unrecoverable(self) -> bool:
        """True only when the auto-heal rebuild itself just failed (#489/#490) — narrower than
        ``is_db_healthy() is False``, which also covers an ordinary transient write error. Feeds
        `dashboard.fail_closed`'s miner hold; a transient blip must never trip it."""
        return self.db_unrecoverable

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
        # Degradation / recovery event markers for the chart (#99). No PK — two events can share a
        # timestamp; type is "hashrate_loss"|"hashrate_recovered"|... and detail is the tooltip text.
        self._conn.execute("CREATE TABLE IF NOT EXISTS events (ts REAL, type TEXT, detail TEXT)")
        # Pool-wide share-health deltas per poll (#116): what the proxy's cumulative counters
        # gained since the previous poll, never the counters themselves — so a proxy restart
        # re-baselines instead of poisoning the series. No PK — it's a rate series, duplicate
        # timestamps are harmless. Additive table, mirroring events: no _migrate_db change needed.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS share_stats "
            "(ts REAL, accepted INTEGER, rejected INTEGER, invalid INTEGER, expired INTEGER)"
        )
        # Confirmed on-chain payouts from the view-only wallet (#381). Keyed (chain, txid) — NOT
        # txid alone — so the Tari sibling (#462) reuses this exact table with chain="tari"; the
        # payout_confirmed alert carries the chain too. Additive, forward-only: mirrors events /
        # share_stats, so no _migrate_db change is needed. amount_atomic keeps the wallet's native
        # atomic units; the view layer converts to XMR at the edge.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS payouts "
            "(chain TEXT, txid TEXT, height INTEGER, ts REAL, amount_atomic INTEGER, "
            "PRIMARY KEY (chain, txid))"
        )
        # Per-worker config-change history for the Worker Inspect page (#185). RigForge keeps no
        # config history on the rig, so Pithead owns it: one row per change the dashboard applied,
        # with the writable-key `changes` we sent (each row IS a diff from the prior state, by
        # construction — we only ever record deltas we authored) and the rig's terminal outcome.
        # `changes` holds only the writable allowlist keys; NO secret ever lands here (the rig token
        # stays host-side, #440). change_id is the rig's 16-hex id, or NULL for a request that never
        # reached a rig (rejected host-side). `type` distinguishes a config apply from a one-click
        # rig upgrade (#1014) — an upgrade's `changes` carries `{"version": ...}` instead of a
        # writable-key diff, and get_last_applied_worker_config must never merge that into the
        # config-editor prefill. New column, existing installs migrated in _migrate_db (below).
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_config "
            "(id INTEGER PRIMARY KEY AUTOINCREMENT, worker TEXT, change_id TEXT, ts REAL, "
            "status TEXT, changes TEXT, reason TEXT, type TEXT DEFAULT 'apply')"
        )
        # v1.7 telemetry backbone (#196 Wave-0 proposal): five independent, additive time-series
        # tables. Each has its own retention (see the RETENTION_SEC constants above) and is
        # DB-only — nothing reads any of them per-cycle, so there's no in-memory mirror to keep in
        # sync (keeps RAM flat). No new columns on `history` — that's the whole point of dedicated
        # tables: independent retention, no row multiplication. Additive, forward-only, same as
        # payouts/worker_config above: no _migrate_db entry needed.
        #
        # blocks: pool block-found events. Permanent (no pruning — a handful of rows/week, like
        # payouts). `difficulty` is the Monero network difficulty AT DETECTION time (p2pool
        # exposes no per-block effort figure), so effort-per-block is derivable later.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS blocks (ts REAL, height INTEGER, difficulty REAL)"
        )
        # raffle_wins: rounds THIS wallet won in the XvB raffle, mirrored from XvB's public
        # winners file (client/xvb_client.parse_winners). Permanent in practice (wins are rare,
        # like payouts) but bounded to the newest RAFFLE_WINS_MAX_ROWS because the source file
        # is untrusted (security review). Idempotent on block_id (the won round's block
        # identifier), so re-reading the ~4-day window the file covers never duplicates a win.
        # Additive, forward-only, same as payouts: no _migrate_db entry needed.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS raffle_wins "
            "(block_id TEXT PRIMARY KEY, ts REAL, hashrate REAL, height INTEGER, tier TEXT)"
        )
        # xvb_history: XvB scalars sampled ~5 min wall-clock. 30-day retention.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS xvb_history "
            "(ts REAL, avg_1h REAL, avg_24h REAL, fail_count INTEGER, "
            "donation_fraction REAL, mode TEXT)"
        )
        # network_history: Monero network difficulty/height/reward + the pool's own hashrate,
        # sampled hourly wall-clock. 90-day retention.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS network_history "
            "(ts REAL, difficulty REAL, height INTEGER, reward REAL, pool_hashrate REAL)"
        )
        # disk_growth: monerod's on-disk DB size + host disk usage, sampled hourly wall-clock.
        # Permanent (no pruning — tiny, ~24 rows/day; it's a capacity trend line).
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS disk_growth "
            "(ts REAL, monero_db_bytes INTEGER, disk_used_gb REAL, disk_total_gb REAL)"
        )
        # worker_history: per-rig hashrate window + cumulative accepted/rejected, sampled ~5 min
        # wall-clock and written in one batched executemany call per cycle. 30-day retention.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_history "
            "(ts REAL, name TEXT, h15 REAL, accepted INTEGER, rejected INTEGER)"
        )
        # audit_events (#530): the durable backing store for the Security panel's audit trail. The
        # #33 control.log is host-owned, read-only from this container, and the writers already trim
        # it — so it can't back a month-level drill-down on its own. This table mirrors each
        # control.log row (source="control", `id` reused as the primary key — INSERT OR IGNORE makes
        # the mirror idempotent) AND records the two kinds this dashboard detects itself:
        # source="host-edit" (config.json changed without a matching control-channel commit) and
        # source="rig-edit" (a rig's control-apply outcome carries a change_id this dashboard never
        # issued). `keys` is names only — never a value — the same contract as control.log itself.
        # Permanent, no pruning, like blocks/payouts/disk_growth: these are human-paced admin events,
        # not a hot metrics series.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS audit_events "
            "(id TEXT PRIMARY KEY, ts TEXT, source TEXT, actor TEXT, action TEXT, status TEXT, "
            "keys TEXT)"
        )

    def _create_indexes(self):
        """Creates indexes. Called after migrations so the indexed columns are guaranteed to
        exist even on a database created by an older schema version."""
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON history(timestamp)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_share_ts ON shares(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_share_stats_ts ON share_stats(ts)")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_worker_config ON worker_config(worker, ts)"
        )
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_blocks_ts ON blocks(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_xvb_history_ts ON xvb_history(ts)")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_network_history_ts ON network_history(ts)"
        )
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_disk_growth_ts ON disk_growth(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_worker_history_ts ON worker_history(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_audit_events_ts ON audit_events(ts)")

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

        # worker_config.type (#1014): every pre-existing row was written before rig upgrades were
        # recorded at all, so it was necessarily a config apply — backfill 'apply', matching the
        # column's own DEFAULT for any row a future ALTER-less write path might still hit.
        cursor.execute("PRAGMA table_info(worker_config)")
        if "type" not in {info[1] for info in cursor.fetchall()}:
            self.logger.info("Migrating DB: Adding type column to worker_config")
            self._conn.execute("ALTER TABLE worker_config ADD COLUMN type TEXT DEFAULT 'apply'")

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
                        # The query filters to 'xvb_%', so every key carries the prefix; strip it.
                        key = row["key"][4:]

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

                    # 4. Load chart events (#99) — the events table is additive, so guard against a
                    # pre-migration DB that predates it.
                    try:
                        cursor.execute(
                            "SELECT ts, type, detail FROM events WHERE ts > ? ORDER BY ts ASC",
                            (history_cutoff,),
                        )
                        self.state["events"] = [dict(row) for row in cursor.fetchall()]
                    except sqlite3.Error:
                        self.state["events"] = []

                    # 5. Load share-stat deltas (#116) — additive table, same pre-migration guard.
                    try:
                        cursor.execute(
                            "SELECT ts, accepted, rejected, invalid, expired FROM share_stats "
                            "WHERE ts > ? ORDER BY ts ASC",
                            (history_cutoff,),
                        )
                        self.state["share_stats"] = [dict(row) for row in cursor.fetchall()]
                    except sqlite3.Error:
                        self.state["share_stats"] = []

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
        # UTC on purpose, and the trailing Z says so. The epoch `ts` is what everything renders
        # from (the chart plots epoch ms and the browser localizes); this string is a human label
        # and the input to the legacy-row migration, whose sqlite strftime('%s', t) parses it AS
        # UTC — a local-time string there skews every migrated row by the container's offset.
        # Store UTC everywhere; localize only at display.
        t_str = time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime())
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

    def add_event(self, ts: float, event_type: str, detail: str = ""):
        """Record a chart event marker (#99) — a degradation/recovery point the chart draws and the
        history window prunes, mirroring shares. Persisted so it survives a dashboard restart."""
        with self._lock:
            self.state.setdefault("events", []).append(
                {"ts": ts, "type": event_type, "detail": detail}
            )
            cutoff = time.time() - HISTORY_RETENTION_SEC
            self.state["events"] = [e for e in self.state["events"] if e["ts"] >= cutoff]
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO events (ts, type, detail) VALUES (?, ?, ?)",
                        (ts, event_type, detail),
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM events WHERE ts < ?",
                            (time.time() - HISTORY_RETENTION_SEC,),
                        )
        except sqlite3.Error as e:
            self._db_error("Event Insert Error", e)

    def get_events(self) -> list[dict[str, Any]]:
        """Returns a copy of the chart events (#99)."""
        with self._lock:
            return list(self.state.get("events", []))

    def add_share_stats(
        self, ts: float, accepted: int = 0, rejected: int = 0, invalid: int = 0, expired: int = 0
    ):
        """Record one poll's pool-wide share-health DELTAS (#116) — how much each cumulative
        proxy counter advanced since the previous poll — in memory and in the DB. Mirrors
        add_event: retention-pruned in memory, probabilistically pruned on disk."""
        row = {
            "ts": ts,
            "accepted": accepted,
            "rejected": rejected,
            "invalid": invalid,
            "expired": expired,
        }
        with self._lock:
            self.state.setdefault("share_stats", []).append(row)
            cutoff = time.time() - HISTORY_RETENTION_SEC
            self.state["share_stats"] = [s for s in self.state["share_stats"] if s["ts"] >= cutoff]
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO share_stats (ts, accepted, rejected, invalid, expired) "
                        "VALUES (?, ?, ?, ?, ?)",
                        (ts, accepted, rejected, invalid, expired),
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM share_stats WHERE ts < ?",
                            (time.time() - HISTORY_RETENTION_SEC,),
                        )
        except sqlite3.Error as e:
            self._db_error("Share Stats Insert Error", e)

    def get_share_stats(self) -> list[dict[str, Any]]:
        """Returns a copy of the per-poll share-health deltas (#116)."""
        with self._lock:
            return list(self.state.get("share_stats", []))

    def add_payouts(self, chain: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Persist confirmed on-chain payouts (#381), idempotent on ``(chain, txid)``, and return
        only the rows that were NEWLY inserted this call.

        The returned "new" list is what drives the ``payout_confirmed`` alert: an already-stored
        payout is silently ignored (INSERT OR IGNORE), so a dashboard restart re-fetching the tip
        never re-alerts. Not held in memory (payouts are read straight from the DB by the view /
        alert paths) — unlike the retention-pruned series, payout history is small and permanent."""
        if not rows:
            return []
        new_rows = []
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                with self._conn:
                    for r in rows:
                        cur = self._conn.execute(
                            "INSERT OR IGNORE INTO payouts "
                            "(chain, txid, height, ts, amount_atomic) VALUES (?, ?, ?, ?, ?)",
                            (
                                chain,
                                r["txid"],
                                int(r.get("height", 0) or 0),
                                float(r.get("ts", 0) or 0),
                                int(r.get("amount_atomic", 0) or 0),
                            ),
                        )
                        # rowcount == 1 means the row was actually inserted (not an ignored dup),
                        # so it's a genuinely new payout worth alerting on exactly once.
                        if cur.rowcount == 1:
                            new_rows.append(r)
        except (sqlite3.Error, KeyError, ValueError, TypeError) as e:
            self._db_error("Payout Insert Error", e)
            return []
        return new_rows

    def get_payouts(self, chain: str | None = None) -> list[dict[str, Any]]:
        """Return stored confirmed payouts, newest first. Filters to ``chain`` when given (the
        dashboard's Monero card reads chain="monero"); omit it for the cross-chain total."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                if chain is None:
                    cursor.execute(
                        "SELECT chain, txid, height, ts, amount_atomic FROM payouts "
                        "ORDER BY ts DESC"
                    )
                else:
                    cursor.execute(
                        "SELECT chain, txid, height, ts, amount_atomic FROM payouts "
                        "WHERE chain = ? ORDER BY ts DESC",
                        (chain,),
                    )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Payout Read Error: {e}")
            return []

    def get_payout_max_height(self, chain: str) -> int:
        """Highest stored block height for ``chain`` (0 if none) — the wallet-poll seed. Fetching
        transfers from this height forward re-scans only the tip; idempotent add_payouts drops the
        overlap, so a restart replays nothing (#381)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return 0
                cursor = self._conn.cursor()
                cursor.execute("SELECT MAX(height) FROM payouts WHERE chain = ?", (chain,))
                row = cursor.fetchone()
                return int(row[0]) if row and row[0] is not None else 0
        except sqlite3.Error as e:
            self.logger.error(f"Payout Height Read Error: {e}")
            return 0

    def add_worker_config_version(
        self,
        worker: str,
        change_id: str | None,
        status: str,
        changes: dict[str, Any],
        reason: str | None,
        ts: float | None = None,
        change_type: str = "apply",
    ) -> None:
        """Record one applied/attempted worker change (#185): a config apply, or (``change_type=
        "upgrade"``, #1014) a one-click RigForge upgrade attempt — ``changes`` then carries
        ``{"version": ...}`` instead of a writable-key diff. Stored as JSON — no secret ever lands
        here. Forward-only."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                self._conn.execute(
                    "INSERT INTO worker_config (worker, change_id, ts, status, changes, reason, type) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (
                        worker,
                        change_id,
                        ts if ts is not None else time.time(),
                        status,
                        json.dumps(changes),
                        reason,
                        change_type,
                    ),
                )
                self._conn.commit()
        except (sqlite3.Error, TypeError, ValueError) as e:
            self._db_error("Worker Config Write Error", e)

    def get_worker_config_history(self, worker: str, limit: int = 50) -> list[dict[str, Any]]:
        """The change history for ``worker``, newest first, with ``changes`` parsed back to a dict.
        ``type`` is ``"apply"`` or ``"upgrade"`` (#1014); a row from before that column existed
        reads back ``"apply"`` too (the migration backfills it, same as a fresh insert's default)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT change_id, ts, status, changes, reason, type FROM worker_config "
                    "WHERE worker = ? ORDER BY ts DESC, id DESC LIMIT ?",
                    (worker, limit),
                )
                out = []
                for row in cursor.fetchall():
                    d = dict(row)
                    try:
                        d["changes"] = json.loads(d["changes"]) if d["changes"] else {}
                    except (TypeError, ValueError):
                        d["changes"] = {}
                    d["type"] = d.get("type") or "apply"
                    out.append(d)
                return out
        except sqlite3.Error as e:
            self.logger.error(f"Worker Config Read Error: {e}")
            return []

    def reconcile_worker_config_status(
        self, change_id: str, status: str, reason: str | None = None
    ) -> None:
        """Catch up a still-``accepted`` #185 history row to its now-known terminal outcome (#579).

        A rig rollback slower than the host runner's status-poll deadline (#517/#543) leaves its
        row ``accepted`` forever otherwise — nothing re-polls it. This is the reconciler: called
        from the dashboard's regular per-rig read poll (data_service.py), never a new dial. The
        ``WHERE status = 'accepted'`` is the whole safety property — a row already terminal
        (applied/rejected/rolled_back/failed/noop/throttled) is never touched, even by a stale or
        duplicate report for the same ``change_id``. ``status`` is recorded as-is: it becomes the
        row's outcome verbatim, and the frontend's ``STATUS_META`` already renders every member of
        this vocabulary (``workerview.mjs``).
        """
        if status not in _RECONCILE_TERMINAL or not change_id:
            return
        try:
            with self._db_lock:
                if not self._conn:
                    return
                self._conn.execute(
                    "UPDATE worker_config SET status = ?, reason = ? "
                    "WHERE change_id = ? AND status = 'accepted'",
                    (status, reason, change_id),
                )
                self._conn.commit()
        except sqlite3.Error as e:
            self._db_error("Worker Config Reconcile Error", e)

    def worker_config_change_known(self, change_id: str) -> bool:
        """Whether ``change_id`` was ever spooled by THIS dashboard (#530): a row exists in
        ``worker_config`` — the table only ``add_worker_config_version`` writes to, one row per
        change the dashboard itself sent. A rig reporting a terminal outcome for a change_id NOT
        found here is reporting something it applied on its own — an out-of-band rig edit."""
        if not change_id:
            return False
        try:
            with self._db_lock:
                if not self._conn:
                    return False
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT 1 FROM worker_config WHERE change_id = ? LIMIT 1", (change_id,)
                )
                return cursor.fetchone() is not None
        except sqlite3.Error as e:
            self.logger.error(f"Worker Config Lookup Error: {e}")
            return True  # fail toward NOT flagging a false rig-edit on a DB read hiccup

    def add_audit_event(
        self, id: str, ts: str, source: str, actor: str, action: str, status: str, keys: str
    ) -> None:
        """Record one audit-trail row (#530) — mirrored from the #33 control.log (``source`` =
        "control", the log's own ``id`` reused as the primary key) or detected out-of-band
        ("host-edit" / "rig-edit"). ``INSERT OR IGNORE`` makes both idempotent: a re-mirrored
        control.log row and a re-detected out-of-band event are no-ops. ``keys`` is names only —
        the caller is responsible for the same no-values contract the log itself holds to."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                self._conn.execute(
                    "INSERT OR IGNORE INTO audit_events "
                    "(id, ts, source, actor, action, status, keys) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (id, ts, source, actor, action, status, keys),
                )
                self._conn.commit()
        except sqlite3.Error as e:
            self._db_error("Audit Event Write Error", e)

    def get_audit_events(self, limit: int = 1000) -> list[dict[str, Any]]:
        """Every persisted audit row (#530), newest first by ``ts`` — the merged, durable
        backing store for the Security panel's time-grouped view."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT id, ts, source, actor, action, status, keys FROM audit_events "
                    "ORDER BY ts DESC LIMIT ?",
                    (limit,),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Audit Event Read Error: {e}")
            return []

    def get_last_applied_worker_config(self, worker: str) -> dict[str, Any]:
        """The merged writable config the dashboard last successfully applied to ``worker`` — the
        best prefill for the editor, since the rig's enriched feed does not expose the writable config
        values (#185). Later applied changes lay over earlier ones (last write wins per key).
        Upgrade rows (#1014) are excluded — their ``changes`` is a ``{"version": ...}`` marker, not
        writable-key config, and must never leak into the editor prefill."""
        merged: dict[str, Any] = {}
        for row in reversed(self.get_worker_config_history(worker, limit=200)):
            if (
                row.get("status") == "applied"
                and row.get("type", "apply") == "apply"
                and isinstance(row.get("changes"), dict)
            ):
                merged.update(row["changes"])
        return merged

    def _table_write_ok(self, table: str, ts: float):
        """Stamp a successful write for the v1.7 telemetry backbone's per-table health signal."""
        self.table_health[table] = {"healthy": True, "last_write": ts}

    def _table_write_failed(self, table: str, where: str, e: Exception):
        """Flip a table's health signal False and route through the shared #131/#489 error path
        (flags the global db_healthy badge too, and triggers corruption auto-recovery if that's
        what this was)."""
        self.table_health[table]["healthy"] = False
        self._db_error(where, e)

    def get_table_health(self) -> dict[str, dict[str, Any]]:
        """Per-table write health for the v1.7 telemetry backbone (#196): ``{table: {"healthy",
        "last_write"}}``. Lets a caller notice a capture hook that has silently stopped writing —
        the data-service poll loop is one big try/except, so nothing else would surface that."""
        return {k: dict(v) for k, v in self.table_health.items()}

    def add_block(self, ts: float, height: int, difficulty: float):
        """Record one pool block-found event (#196): permanent (no retention prune — a handful of
        rows/week, like payouts). The caller (DataService) reuses `_shares_to_record` on p2pool's
        cumulative blocks_found counter so this fires exactly once per genuinely NEW block; a
        p2pool restart (counter goes backwards) re-baselines instead of replaying history."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO blocks (ts, height, difficulty) VALUES (?, ?, ?)",
                        (ts, height, difficulty),
                    )
            self._table_write_ok("blocks", ts)
        except sqlite3.Error as e:
            self._table_write_failed("blocks", "Block Insert Error", e)

    def get_blocks(self, since: float = 0.0) -> list[dict[str, Any]]:
        """Pool block-found events at or after `since` (default: all), oldest first."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT ts, height, difficulty FROM blocks WHERE ts >= ? ORDER BY ts ASC",
                    (since,),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Block Read Error: {e}")
            return []

    def add_raffle_wins(self, wins: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Persist XvB raffle wins mirrored from the public winners file, idempotent on
        ``block_id``, and return only the rows NEWLY inserted this call.

        Same contract as ``add_payouts``: the caller announces each returned win exactly once,
        and a dashboard restart re-reading the file's window is silently ignored (INSERT OR
        IGNORE), so a win is never re-announced. Not held in memory — the view reads straight
        from the DB, and win history is small and permanent."""
        if not wins:
            return []
        new_rows = []
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                with self._conn:
                    for w in wins:
                        cur = self._conn.execute(
                            "INSERT OR IGNORE INTO raffle_wins "
                            "(block_id, ts, hashrate, height, tier) VALUES (?, ?, ?, ?, ?)",
                            (
                                w["block_id"],
                                float(w.get("ts", 0) or 0),
                                float(w.get("hashrate", 0) or 0),
                                int(w.get("height", 0) or 0),
                                w.get("tier", ""),
                            ),
                        )
                        # rowcount == 1 means the row was actually inserted (not an ignored
                        # dup), so it's a genuinely new win worth announcing exactly once.
                        if cur.rowcount == 1:
                            new_rows.append(w)
                    # Bound the table (security review): rows are mirrored from an UNTRUSTED
                    # public file and the masked wallet form is publicly derivable, so a
                    # hostile feed could otherwise grow this permanent table without limit.
                    # Legit wins can't approach the cap (hourly rounds — 5000 wins is decades
                    # of winning every other round), so the prune never touches real history.
                    self._conn.execute(
                        "DELETE FROM raffle_wins WHERE block_id NOT IN "
                        "(SELECT block_id FROM raffle_wins ORDER BY ts DESC LIMIT ?)",
                        (RAFFLE_WINS_MAX_ROWS,),
                    )
        except (sqlite3.Error, KeyError, ValueError, TypeError) as e:
            self._db_error("Raffle Win Insert Error", e)
            return []
        return new_rows

    def get_raffle_wins(self, since: float = 0.0) -> list[dict[str, Any]]:
        """This wallet's recorded XvB raffle wins at or after ``since`` (default: all),
        oldest first — bounded to the newest ``RAFFLE_WINS_MAX_ROWS`` so the per-poll
        ``/api/state`` read can never become an unbounded scan (security review)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT ts, hashrate, height, block_id, tier FROM "
                    "(SELECT ts, hashrate, height, block_id, tier FROM raffle_wins "
                    "WHERE ts >= ? ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC",
                    (since, RAFFLE_WINS_MAX_ROWS),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Raffle Win Read Error: {e}")
            return []

    def add_xvb_history(
        self,
        ts: float,
        avg_1h: float = 0.0,
        avg_24h: float = 0.0,
        fail_count: int = 0,
        donation_fraction: float = 0.0,
        mode: str = "",
    ):
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
    ):
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
    ):
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

    def add_worker_history(self, rows: list[dict[str, Any]]):
        """Record one poll's per-worker hashrate/share-count samples (#196) in a SINGLE
        executemany call — the caller batches every online worker for one wall-clock tick rather
        than issuing N inserts per cycle. 30-day retention. Each row needs ts/name/h15/accepted/
        rejected; a missing key defaults to 0/''. A no-op on an empty batch."""
        if not rows:
            return
        prune_ts = rows[0].get("ts", time.time())
        try:
            values = [
                (
                    r.get("ts", prune_ts),
                    r.get("name", ""),
                    r.get("h15", 0) or 0,
                    r.get("accepted", 0) or 0,
                    r.get("rejected", 0) or 0,
                )
                for r in rows
            ]
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.executemany(
                        "INSERT INTO worker_history (ts, name, h15, accepted, rejected) "
                        "VALUES (?, ?, ?, ?, ?)",
                        values,
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM worker_history WHERE ts < ?",
                            (prune_ts - WORKER_HISTORY_RETENTION_SEC,),
                        )
            self._table_write_ok("worker_history", prune_ts)
        except sqlite3.Error as e:
            self._table_write_failed("worker_history", "Worker History Insert Error", e)

    def get_worker_history(
        self, since: float = 0.0, name: str | None = None
    ) -> list[dict[str, Any]]:
        """Per-worker hashrate/share samples at or after `since` (default: all), oldest first.
        `name` restricts to one rig's series (#492); omit it for every rig's samples."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                if name is not None:
                    cursor.execute(
                        "SELECT ts, name, h15, accepted, rejected FROM worker_history "
                        "WHERE ts >= ? AND name = ? ORDER BY ts ASC",
                        (since, name),
                    )
                else:
                    cursor.execute(
                        "SELECT ts, name, h15, accepted, rejected FROM worker_history "
                        "WHERE ts >= ? ORDER BY ts ASC",
                        (since,),
                    )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Worker History Read Error: {e}")
            return []

    def get_worker_hashrate_by_config(
        self, worker: str, since: float = 0.0
    ) -> list[dict[str, Any]]:
        """Correlate `worker`'s measured hashrate (worker_history) to the config version active at
        each sample's timestamp (#492 — rides #185's worker_config + #196's worker_history). Each
        *applied* worker_config row is a version boundary; a sample belongs to the most recent
        applied change at or before its ts, so an operator can compare "config #3 did X, config #4
        did Y" empirically. Bucketing is in Python (bisect) — the version count is small (`limit`
        below) and this reads far more clearly than a correlated-subquery/window-function SQL
        version. Returns one row per version, newest first, matching get_worker_config_history:
        `{change_id, ts, reason, sample_count, avg_h15, min_h15, max_h15}` (the h15 fields are
        `None` for a version with zero samples). Samples that predate the first applied change have
        no known version and are dropped — out of scope: correlate to a KNOWN version, don't guess
        at pre-history config."""
        versions = [
            row
            for row in reversed(self.get_worker_config_history(worker, limit=200))
            if row.get("status") == "applied"
        ]
        if not versions:
            return []
        boundaries = [v["ts"] for v in versions]  # oldest first, aligned with `versions`
        buckets: list[list[float]] = [[] for _ in versions]
        for s in self.get_worker_history(since=since, name=worker):
            idx = bisect.bisect_right(boundaries, s["ts"]) - 1
            if idx >= 0:
                buckets[idx].append(s["h15"])

        out = [
            {
                "change_id": v["change_id"],
                "ts": v["ts"],
                "reason": v.get("reason"),
                "sample_count": len(vals),
                "avg_h15": sum(vals) / len(vals) if vals else None,
                "min_h15": min(vals) if vals else None,
                "max_h15": max(vals) if vals else None,
            }
            for v, vals in zip(versions, buckets, strict=True)
        ]
        out.reverse()  # newest first
        return out

    def get_xvb_stats(self) -> dict[str, Any]:
        """Returns the current XvB mining statistics dictionary."""
        with self._lock:
            return self.state["xvb"].copy()

    def set_xvb_standby(self, standby: dict[str, Any]):
        """Store the XvB controller state last pulled from the PRIMARY stack (#249). Held as
        standby only — never folded into the live controller until this host takes over on
        failover, and never acted on while the primary is authoritative (this host has no workers
        then, so the controller stays on P2Pool regardless). Persisted (kv_store) so the standby
        survives a backup restart. A JSON blob, mirroring ``save_snapshot``."""
        try:
            self.set_kv("xvb_standby", json.dumps(standby))
        except (TypeError, ValueError) as e:
            self._db_error("XvB Standby Serialization Error", e)

    def get_xvb_standby(self) -> dict[str, Any] | None:
        """The last-pulled primary XvB controller state (#249), or None if a backup source was
        never configured / has not fetched yet. Inspectable via ``/api/state`` so an operator can
        confirm the backup is warm before a failover."""
        raw = self.get_kv("xvb_standby")
        if not raw:
            return None
        try:
            val = json.loads(raw)
            return val if isinstance(val, dict) else None
        except (json.JSONDecodeError, TypeError):
            return None

    def get_xvb_reward_estimates(self) -> dict[str, Any]:
        """The cached XvB per-tier reward estimates (#118): ``{"estimates": {...}, "last_update": ts}``."""
        with self._lock:
            return {
                "estimates": dict(self._xvb_rewards["estimates"]),
                "last_update": self._xvb_rewards["last_update"],
            }

    def set_xvb_reward_estimates(self, estimates: dict[str, float]):
        """Replace the cached reward estimates and stamp ``last_update`` (only on a genuine fetch, #118)."""
        with self._lock:
            self._xvb_rewards = {"estimates": dict(estimates or {}), "last_update": time.time()}

    def get_xvb_round_stats(self) -> dict[str, Any]:
        """The cached all-rounds raffle aggregate (#866/#872):
        ``{"stats": {"types": {...}, "span_days": d}, "last_update": ts}``."""
        with self._lock:
            return {
                "stats": dict(self._xvb_round_stats["stats"]),
                "last_update": self._xvb_round_stats["last_update"],
            }

    def set_xvb_round_stats(self, stats: dict[str, Any]):
        """Replace the cached round aggregate and stamp ``last_update`` (only on a genuine fetch)."""
        with self._lock:
            self._xvb_round_stats = {"stats": dict(stats or {}), "last_update": time.time()}

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

    def get_kv(self, key: str) -> str | None:
        """Read one value from the kv_store, or None if absent / unreadable (#375)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return None
                cursor = self._conn.cursor()
                cursor.execute("SELECT value FROM kv_store WHERE key = ?", (key,))
                row = cursor.fetchone()
                return row[0] if row else None
        except sqlite3.Error as e:
            self.logger.error(f"KV Read Error: {e}")
            return None

    def set_kv(self, key: str, value):
        """Insert-or-replace one kv_store value (#375). Values are stored as strings, mirroring
        the XvB stats writes above."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)",
                        (key, str(value)),
                    )
        except sqlite3.Error as e:
            self._db_error("KV Write Error", e)

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
            # A non-serializable snapshot is a persistent write failure (data lost on restart),
            # so flag persistence unhealthy like every other write path — otherwise the #131
            # badge stays green while snapshots silently never persist.
            self._db_error("Snapshot Serialization Error", e)

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
