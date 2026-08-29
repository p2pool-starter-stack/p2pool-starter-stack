"""The dashboard's own record of the worker config changes it sent (#185), split out of
`storage_service.py`.

This is a MIXIN, not a facade: `StateManager` inherits it, so these methods keep the same `self`,
the same `_conn`, the same `_db_lock` and the same transaction scope they had when they were
defined inline. That distinction is what the #1105 "do not split `storage_service.py`" ruling
turns on — it refused a new seam between callers and the single DB handle, and a mixin introduces
none. The same narrowing the telemetry split was taken under (#1369), and the same proof class,
except that the proof now ships as `tests/service/test_mixin_atomicity.py` rather than as a
one-off pass: no method here holds a transaction or cursor across a call into a method that
stayed behind, and CI re-checks that on every later PR instead of once.

The boundary is the `worker_config` TABLE — every accessor of it moves and nothing else does, so
the seam is one the code already drew rather than one invented for the cut. `worker_history` and
its `get_worker_hashrate_by_config` reader stay behind: that pair is hashrate telemetry keyed by
config version, not the change record itself.

Why this cut was taken: `storage_service.py` sat at its recorded file-budget ceiling with zero
headroom, and #1369's fix — an exact-id provenance lookup the 50-row history window cannot answer
— has to land somewhere. It lands here, in the module that owns the table it reads.
"""

import json
import sqlite3
import time
from typing import Any

# The full terminal vocabulary the rig's control mirror can report (#1009) — applied/rejected/
# rolled_back/failed from a control-apply, plus noop (already on target)/throttled (retry-later)
# from a control-upgrade (rigforge#320). Mirrors xmrig_client._CONTROL_TERMINAL and pithead's own
# control_worker_apply/control_worker_upgrade poll cases (#1001) — one vocabulary, three places.
# It lives with `reconcile_worker_config_status`, its only reader, and is re-exported from
# `storage_service` so that import surface is unchanged by the split (#1369).
_RECONCILE_TERMINAL = ("applied", "rejected", "rolled_back", "failed", "noop", "throttled")


class WorkerConfigStoreMixin:
    """The `worker_config` accessors of `StateManager`. Never instantiated on its own."""

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

    def get_worker_config_history(self, worker: str, limit: int = 50) -> list[dict] | None:
        """The change history for ``worker``, newest first, ``changes`` parsed back to a dict.
        ``type`` is ``"apply"``/``"upgrade"`` (#1014); a pre-column row reads back ``"apply"``.
        None means the read FAILED (no connection, or ``sqlite3.Error``); ``[]`` = no history."""
        try:
            with self._db_lock:
                if not self._conn:
                    return None
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
            return None

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

    def get_last_applied_worker_config(self, worker: str) -> dict[str, Any]:
        """The merged writable config the dashboard last successfully applied to ``worker`` — the
        best prefill for the editor, since the rig's enriched feed does not expose the writable config
        values (#185). Later applied changes lay over earlier ones (last write wins per key).
        Upgrade rows (#1014) are excluded — their ``changes`` is a ``{"version": ...}`` marker, not
        writable-key config, and must never leak into the editor prefill."""
        merged: dict[str, Any] = {}
        for row in reversed(self.get_worker_config_history(worker, limit=200) or []):
            if (
                row.get("status") == "applied"
                and row.get("type", "apply") == "apply"
                and isinstance(row.get("changes"), dict)
            ):
                merged.update(row["changes"])
        return merged
