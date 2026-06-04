import asyncio
import logging

from mining_dashboard.config.config import (
    HOST_IP,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
    TELEGRAM_ENABLED,
    TELEGRAM_EVENTS,
)
from mining_dashboard.service.telegram_notifier import TelegramNotifier
from mining_dashboard.service.worker_presence import WorkerPresenceMonitor

logger = logging.getLogger("AlertService")


def build_default_notifier():
    """Construct the Telegram notifier from the process config (Issue #121)."""
    return TelegramNotifier(
        enabled=TELEGRAM_ENABLED,
        bot_token=TELEGRAM_BOT_TOKEN,
        chat_id=TELEGRAM_CHAT_ID,
        events=TELEGRAM_EVENTS,
    )


class AlertService:
    """
    Turns the data loop's per-cycle signals into a small set of debounced operator alerts and
    pushes them over Telegram (Issue #121). Notifications-only — no interactive bot (#45).

    It *consumes* signals the loop already computes rather than re-collecting anything:

    - **node down / recovered** — transitions of ``NodeHealthMonitor``'s debounced ``down``
      flag per node (#31). Tari is only alerted when it's treated as required; a non-blocking
      Tari going down isn't operator-critical (we keep mining Monero), matching the
      worker-rejection rule.
    - **sync finished** — the sync gate's ``miner_released`` latch flipping open once (#35).
    - **worker offline / back online** — a debounced :class:`WorkerPresenceMonitor` over the
      live worker list (the one genuinely new building block this issue adds).

    Edge state is seeded silently on the first observation (``None`` baselines), so a dashboard
    restart can't replay a stale transition as a fresh alert.

    :meth:`evaluate` is pure (folds signals into the alert list, no I/O) so it's fully
    unit-testable; :meth:`process` calls it and dispatches each message off-thread so a slow or
    blocked Telegram send never stalls the data loop.
    """

    # Event keys — must match config.json's telegram.events toggles and TELEGRAM_EVENTS.
    EVT_NODE_DOWN = "node_down"
    EVT_NODE_RECOVERED = "node_recovered"
    EVT_WORKER_OFFLINE = "worker_offline"
    EVT_WORKER_RECOVERED = "worker_recovered"
    EVT_SYNC_FINISHED = "sync_finished"

    def __init__(self, notifier=None, worker_monitor=None, host_label=HOST_IP):
        self.notifier = notifier if notifier is not None else build_default_notifier()
        self.workers = worker_monitor if worker_monitor is not None else WorkerPresenceMonitor()
        # "Unknown Host" is config.py's placeholder when HOST_IP isn't set — don't prefix with it.
        self.host_label = "" if host_label in (None, "", "Unknown Host") else host_label
        # None = "not yet observed": the first cycle seeds the baseline without emitting.
        self._prev_monero_down = None
        self._prev_tari_down = None
        self._prev_released = None

    @property
    def enabled(self):
        return self.notifier.enabled

    def evaluate(self, *, monero_down, tari_down, tari_required, miner_released,
                 online_workers, workers_expected, now=None):
        """Pure: fold this cycle's signals into the list of ``(event_key, text)`` to send,
        filtered to the events the operator left enabled."""
        alerts = []

        # --- Node down / recovered (consume NodeHealthMonitor edges) ---
        alerts += self._node_edges("Monero", monero_down, "_prev_monero_down")
        if tari_required:
            alerts += self._node_edges("Tari", tari_down, "_prev_tari_down")
        else:
            # Keep the baseline current while Tari is non-blocking, so flipping it back to
            # required later doesn't fire a stale edge from a state we never alerted on.
            self._prev_tari_down = tari_down

        # --- Sync finished (one-shot when the gate first opens) ---
        if self._prev_released is None:
            self._prev_released = miner_released
        elif miner_released and not self._prev_released:
            alerts.append((self.EVT_SYNC_FINISHED, self._fmt(
                "✅ Node ready — required chain(s) synced; mining has started.")))
        self._prev_released = miner_released

        # --- Worker offline / back online (debounced) ---
        # Only meaningful while workers are actually expected: when the proxy is intentionally
        # stopped (initial sync hold, or node-down failover) their absence is by design, so we
        # reset the tracker instead of aging every rig into a false "offline".
        if workers_expected:
            for name, event in self.workers.update(online_workers, now=now):
                if event == "offline":
                    alerts.append((self.EVT_WORKER_OFFLINE,
                                   self._fmt(f"\U0001f534 Worker offline: {name}")))
                else:
                    alerts.append((self.EVT_WORKER_RECOVERED,
                                   self._fmt(f"\U0001f7e2 Worker back online: {name}")))
        else:
            self.workers.reset()

        return [(evt, text) for evt, text in alerts if self.notifier.event_enabled(evt)]

    def _node_edges(self, label, down, attr):
        prev = getattr(self, attr)
        setattr(self, attr, down)
        if prev is None or down == prev:
            return []
        if down:
            return [(self.EVT_NODE_DOWN, self._fmt(
                f"\U0001f534 {label} node is DOWN — workers failing over to backup pools."))]
        return [(self.EVT_NODE_RECOVERED, self._fmt(
            f"\U0001f7e2 {label} node recovered — workers readmitted."))]

    def _fmt(self, text):
        return f"[{self.host_label}] {text}" if self.host_label else text

    async def process(self, **signals):
        """Evaluate this cycle's signals and dispatch any alerts. No-op (and cheap) when the
        notifier is disabled. Each send runs off-thread so a slow Telegram call can't stall
        the data loop. Returns the alerts that were dispatched (handy for tests/logging)."""
        if not self.notifier.enabled:
            return []
        try:
            alerts = self.evaluate(**signals)
        except Exception as exc:  # never let an alerting bug break the data loop
            logger.debug("Alert evaluation failed (%s)", type(exc).__name__)
            return []
        for _evt, text in alerts:
            await asyncio.to_thread(self.notifier.send, text)
        return alerts
