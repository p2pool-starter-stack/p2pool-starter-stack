import time

from mining_dashboard.config.config import (
    WORKER_OFFLINE_AFTER_SEC,
    WORKER_RECOVERY_AFTER_SEC,
)


class WorkerPresenceMonitor:
    """
    Per-worker, flap-protected offline/online tracker (Issue #121).

    The alerter needs a stable "rig-3 went offline / rig-3 is back" signal. It's driven off the
    **same worker rows the dashboard shows** — each rig's ``status`` (``"online"`` when xmrig-proxy
    reports live connections, else the ``DOWN`` state the UI renders). This is the per-worker
    analogue of ``NodeHealthMonitor`` (#31), multiplexed over many workers keyed by name, so a
    Telegram "offline" alert lines up with the rig showing **DOWN** on screen:

    - **DOWN drives offline.** A rig is offline-pending while it's shown DOWN (listed by the proxy
      but not connected). Once it's been DOWN continuously for ``offline_after`` it's declared
      OFFLINE; once it's been back online for ``recovery_after`` the OFFLINE clears — so a single
      dropped poll or a brief reconnect can't spam recovered→offline.
    - **Silent baseline.** A rig's first sighting registers its current state with no edge — a
      brand-new rig is not a "recovery", and a rig already DOWN at dashboard start is not a fresh
      "offline" (a restart must not replay a stale transition).
    - **Follows the table.** A rig the proxy stops listing entirely (aged off the worker table,
      #182) is forgotten — the dashboard no longer shows it, DOWN or otherwise, so neither does the
      alerter. Its state is bounded by exactly what's on screen; if it later returns it re-baselines
      silently.

    :meth:`update` takes this cycle's worker rows (dicts with ``name`` + ``status``) and returns a
    list of ``(name, event)`` edges, ``event`` in ``{"offline", "recovered"}``.

    Clock defaults to wall-clock ``time.time``; injectable for deterministic tests.
    """

    def __init__(
        self,
        offline_after=WORKER_OFFLINE_AFTER_SEC,
        recovery_after=WORKER_RECOVERY_AFTER_SEC,
        clock=time.time,
    ):
        self.offline_after = offline_after
        self.recovery_after = recovery_after
        self._clock = clock
        # name -> {state, online_since, down_since}
        #   state        : "online" | "offline" (the debounced, edge-emitting state)
        #   online_since : when the current continuous-online streak began (None while DOWN)
        #   down_since   : when the current continuous-DOWN streak began (None while online)
        self._workers = {}

    def update(self, workers, now=None):
        """Feed this cycle's worker rows; return the list of debounced transitions."""
        now = self._clock() if now is None else now
        online = {w.get("name") for w in workers if w.get("status") == "online"}
        present = {w.get("name") for w in workers}
        edges = []

        # Forget rigs the proxy no longer lists at all — they've fallen off the worker table and
        # the dashboard no longer shows them, so the alerter drops them too (a later return
        # re-baselines silently).
        for name in list(self._workers):
            if name not in present:
                del self._workers[name]

        for name in present:
            self._step(name, name in online, now, edges)

        return edges

    def _step(self, name, is_online, now, edges):
        w = self._workers.get(name)
        if w is None:
            # First sighting — baseline to the rig's current state, no edge.
            self._workers[name] = {
                "state": "online" if is_online else "offline",
                "online_since": now if is_online else None,
                "down_since": None if is_online else now,
            }
            return

        if is_online:
            w["down_since"] = None
            if w["online_since"] is None:
                w["online_since"] = now
            if w["state"] == "offline" and (now - w["online_since"]) >= self.recovery_after:
                w["state"] = "online"
                edges.append((name, "recovered"))
        else:
            w["online_since"] = None
            if w["down_since"] is None:
                w["down_since"] = now
            if w["state"] == "online" and (now - w["down_since"]) >= self.offline_after:
                w["state"] = "offline"
                edges.append((name, "offline"))

    def reset(self):
        """Drop all per-worker state.

        Called when the proxy is *intentionally* stopped — during the initial sync hold (#35)
        or node-down worker failover (#31) — so the expected absence of workers doesn't age
        into false "offline" alerts, and re-admission re-baselines every worker silently.
        """
        self._workers.clear()
