import time

from mining_dashboard.config.config import (
    WORKER_OFFLINE_AFTER_SEC,
    WORKER_RECOVERY_AFTER_SEC,
    WORKER_RETENTION_SEC,
)


class WorkerPresenceMonitor:
    """
    Per-worker, flap-protected offline/online tracker (Issue #121).

    The alerter needs a stable "rig-3 went offline / rig-3 is back" signal, but the raw
    per-cycle worker list is noisy: xmrig-proxy keeps a disconnected worker around with a
    decaying hashrate, miners briefly reconnect, and a worker can drop out of the list
    entirely. This is the per-worker analogue of ``NodeHealthMonitor`` (#31), multiplexed
    over many workers keyed by name:

    - **Debounce / hysteresis.** A worker must be *unseen* for ``offline_after`` seconds
      before it's declared OFFLINE, and *seen continuously* for ``recovery_after`` seconds
      before OFFLINE clears — so a single dropped poll, or a brief reconnect during an
      outage, can't emit a recovered→offline spam.
    - **Silent baseline.** A worker's first sighting registers it as ONLINE with no edge — a
      brand-new rig is not a "recovery", and a dashboard restart must not replay every known
      worker as a fresh alert.
    - **Bounded memory.** A worker gone longer than ``retention`` is forgotten, so state stays
      bounded and a long-absent rig that returns counts as new (mirrors ``StateManager``'s
      7-day worker retention, the persisted analogue of this in-memory tracker).

    :meth:`update` takes the set of worker names seen *online* this cycle and returns a list
    of ``(name, event)`` edges, ``event`` in ``{"offline", "recovered"}``.

    Clock defaults to wall-clock ``time.time`` (so it lines up with ``last_seen`` semantics);
    injectable for deterministic tests.
    """

    def __init__(self, offline_after=WORKER_OFFLINE_AFTER_SEC,
                 recovery_after=WORKER_RECOVERY_AFTER_SEC,
                 retention=WORKER_RETENTION_SEC, clock=time.time):
        self.offline_after = offline_after
        self.recovery_after = recovery_after
        self.retention = retention
        self._clock = clock
        # name -> {state, seen_since, unseen_since, last_present}
        #   state        : "online" | "offline" (the debounced, edge-emitting state)
        #   seen_since   : when the current continuous-presence streak began (None while absent)
        #   unseen_since : when the current continuous-absence streak began (None while present)
        #   last_present : last cycle the worker was seen (drives retention pruning)
        self._workers = {}

    def update(self, present, now=None):
        """Feed this cycle's online worker names; return the list of debounced transitions."""
        now = self._clock() if now is None else now
        present = set(present)
        edges = []

        # Present workers: refresh the presence streak, clear OFFLINE once it's stable.
        for name in present:
            w = self._workers.get(name)
            if w is None:
                # First sighting — baseline as ONLINE, no edge.
                self._workers[name] = {
                    "state": "online", "seen_since": now,
                    "unseen_since": None, "last_present": now,
                }
                continue
            w["last_present"] = now
            w["unseen_since"] = None
            if w["seen_since"] is None:
                w["seen_since"] = now
            if w["state"] == "offline" and (now - w["seen_since"]) >= self.recovery_after:
                w["state"] = "online"
                edges.append((name, "recovered"))

        # Absent workers: age the absence streak, declare OFFLINE once past the threshold.
        for name, w in self._workers.items():
            if name in present:
                continue
            w["seen_since"] = None
            if w["unseen_since"] is None:
                w["unseen_since"] = now
            if w["state"] == "online" and (now - w["unseen_since"]) >= self.offline_after:
                w["state"] = "offline"
                edges.append((name, "offline"))

        self._prune(now)
        return edges

    def reset(self):
        """Drop all per-worker state.

        Called when the proxy is *intentionally* stopped — during the initial sync hold (#35)
        or node-down worker failover (#31) — so the expected absence of workers doesn't age
        into false "offline" alerts, and re-admission re-baselines every worker silently.
        """
        self._workers.clear()

    def _prune(self, now):
        stale = [
            name for name, w in self._workers.items()
            if w["unseen_since"] is not None and (now - w["last_present"]) >= self.retention
        ]
        for name in stale:
            del self._workers[name]
