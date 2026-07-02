import asyncio
import logging

from mining_dashboard.config.config import (
    DISK_CRITICAL_PERCENT,
    DISK_WARN_PERCENT,
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
    - **worker offline / back online / joined / left** — a debounced :class:`WorkerPresenceMonitor`
      over the live worker rows (offline keys off the same DOWN status the dashboard shows; joined /
      left track fleet membership).
    - **disk filling / critical** — the data disk crossing the same ``DISK_WARN_PERCENT`` /
      ``DISK_CRITICAL_PERCENT`` thresholds the dashboard's low-disk badge uses (#138): a full disk
      corrupts monerod's DB mid-write.
    - **DB write failing** — ``StateManager.is_db_healthy`` flipping false (#131): the dashboard
      keeps serving but history/shares/stats stop persisting.

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
    EVT_WORKER_JOINED = "worker_joined"
    EVT_WORKER_LEFT = "worker_left"
    EVT_SYNC_FINISHED = "sync_finished"
    EVT_DISK_SPACE = "disk_space"
    EVT_DB_UNHEALTHY = "db_unhealthy"

    # WorkerPresenceMonitor edge -> (event key, message template).
    _WORKER_EDGES = {
        "offline": (EVT_WORKER_OFFLINE, "\U0001f534 Worker offline: {name}"),
        "recovered": (EVT_WORKER_RECOVERED, "\U0001f7e2 Worker back online: {name}"),
        "joined": (EVT_WORKER_JOINED, "\U0001f7e2 New worker joined: {name}"),
        "left": (EVT_WORKER_LEFT, "⚪ Worker left: {name}"),
    }

    def __init__(self, notifier=None, worker_monitor=None, host_label=HOST_IP):
        self.notifier = notifier if notifier is not None else build_default_notifier()
        self.workers = worker_monitor if worker_monitor is not None else WorkerPresenceMonitor()
        # "Unknown Host" is config.py's placeholder when HOST_IP isn't set — don't prefix with it.
        self.host_label = "" if host_label in (None, "", "Unknown Host") else host_label
        # None = "not yet observed": the first cycle seeds the baseline without emitting.
        self._prev_monero_down = None
        self._prev_tari_down = None
        self._prev_released = None
        self._prev_disk_level = None
        self._prev_db_healthy = None

    @property
    def enabled(self):
        return self.notifier.enabled

    def evaluate(
        self,
        *,
        monero_down,
        tari_down,
        tari_required,
        miner_released,
        workers,
        workers_expected,
        disk_percent=0,
        db_healthy=True,
        now=None,
    ):
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
            alerts.append(
                (
                    self.EVT_SYNC_FINISHED,
                    self._fmt("✅ Node ready — required chain(s) synced; mining has started."),
                )
            )
        self._prev_released = miner_released

        # --- Worker offline / recovered / joined / left (debounced off the DOWN status) ---
        # Driven by each rig's status in the same worker rows the dashboard shows (DOWN = offline).
        # Only meaningful while workers are actually expected: when the proxy is intentionally
        # stopped (initial sync hold, or node-down failover) their absence is by design, so we
        # reset the tracker instead of aging every rig into a false "offline".
        if workers_expected:
            for name, event in self.workers.update(workers, now=now):
                evt, template = self._WORKER_EDGES[event]
                alerts.append((evt, self._fmt(template.format(name=name))))
        else:
            self.workers.reset()

        # --- Host health: data disk filling up, dashboard DB write failing ---
        alerts += self._disk_edges(disk_percent)
        alerts += self._db_edges(db_healthy)

        return [(evt, text) for evt, text in alerts if self.notifier.event_enabled(evt)]

    def _node_edges(self, label, down, attr):
        prev = getattr(self, attr)
        setattr(self, attr, down)
        if prev is None or down == prev:
            return []
        if down:
            return [
                (
                    self.EVT_NODE_DOWN,
                    self._fmt(
                        f"\U0001f534 {label} node is DOWN — workers failing over to backup pools."
                    ),
                )
            ]
        return [
            (
                self.EVT_NODE_RECOVERED,
                self._fmt(f"\U0001f7e2 {label} node recovered — workers readmitted."),
            )
        ]

    def _disk_edges(self, disk_percent):
        """Alert on the data disk crossing the dashboard's own warn/critical thresholds (#138)."""
        level = (
            "critical"
            if disk_percent >= DISK_CRITICAL_PERCENT
            else "warn"
            if disk_percent >= DISK_WARN_PERCENT
            else "ok"
        )
        prev = self._prev_disk_level
        self._prev_disk_level = level
        if prev is None or level == prev:
            return []
        pct = f"{disk_percent:.0f}%"
        if level == "critical":
            return [
                (
                    self.EVT_DISK_SPACE,
                    self._fmt(
                        f"\U0001f534 Data disk almost full ({pct}) — free space now; a full disk "
                        "can corrupt the Monero database."
                    ),
                )
            ]
        if level == "warn":
            return [(self.EVT_DISK_SPACE, self._fmt(f"\U0001f7e0 Data disk filling up ({pct})."))]
        return [(self.EVT_DISK_SPACE, self._fmt(f"\U0001f7e2 Data disk back to healthy ({pct})."))]

    def _db_edges(self, db_healthy):
        """Alert when the dashboard can no longer persist to its SQLite DB (#131)."""
        prev = self._prev_db_healthy
        self._prev_db_healthy = db_healthy
        if prev is None or db_healthy == prev:
            return []
        if not db_healthy:
            return [
                (
                    self.EVT_DB_UNHEALTHY,
                    self._fmt(
                        "\U0001f534 Dashboard DB write failing — hashrate history, shares and stats "
                        "won't persist. Check disk space and permissions on the dashboard data dir."
                    ),
                )
            ]
        return [(self.EVT_DB_UNHEALTHY, self._fmt("\U0001f7e2 Dashboard DB writes recovered."))]

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
