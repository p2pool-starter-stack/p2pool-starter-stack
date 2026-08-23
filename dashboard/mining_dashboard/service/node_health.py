import time

from mining_dashboard.config.config import NODE_DOWN_AFTER_SEC, NODE_RECOVERY_AFTER_SEC


class NodeHealthMonitor:
    """
    Turns a noisy per-cycle `reachable` signal into a stable `down` flag (Issue #31).

    Two guards keep the reject-workers action from firing on noise:

    - **Debounce / hysteresis.** A node must be unreachable for `down_after` seconds before
      it's declared DOWN, and reachable for `recovery_after` seconds before DOWN clears —
      so a single timeout, or a brief `docker restart`, doesn't kick miners off (and back).

    - **Ever-up guard.** A node is only ever declared DOWN after it has been reachable at
      least once. A node that was *never* reachable (remote monerod whose RPC we can't
      reach, wrong credentials, a misconfig) stays "not down" forever — we never reject
      workers over something that never worked in the first place.

    Exposes two signals so the orchestrator can be asymmetric (stop eagerly on DOWN,
    readmit only on confirmed healthy):
    - `down`    — debounced unreachable; gates *stopping* the proxy.
    - `healthy` — reachable and stable for `recovery_after`; gates *readmitting* workers.
      Distinct from `not down`: a fresh monitor (e.g. after a dashboard restart) is neither
      `down` nor `healthy` until it actually observes the node, so we never readmit workers
      to a still-down stack on a restored "rejected" flag.

    Clock is injectable for tests; defaults to `time.monotonic`.
    """

    def __init__(
        self,
        down_after=NODE_DOWN_AFTER_SEC,
        recovery_after=NODE_RECOVERY_AFTER_SEC,
        clock=time.monotonic,
    ):
        self.down_after = down_after
        self.recovery_after = recovery_after
        self._clock = clock
        self.ever_up = False
        self.down = False
        self.healthy = False
        self._unreachable_since = None
        self._reachable_since = None

    def update(self, reachable):
        """Feed this cycle's live reachability; returns the current debounced `down` flag."""
        now = self._clock()

        if reachable:
            self.ever_up = True
            self._unreachable_since = None
            if self._reachable_since is None:
                self._reachable_since = now
            # Healthy only once we've been reachable continuously for the recovery window.
            self.healthy = (now - self._reachable_since) >= self.recovery_after
            # Clear DOWN on the same confirmed-healthy condition (hysteresis).
            if self.down and self.healthy:
                self.down = False
        else:
            self._reachable_since = None
            self.healthy = False
            if self._unreachable_since is None:
                self._unreachable_since = now
            # Only a node that has actually been up can fall DOWN.
            if (
                self.ever_up
                and not self.down
                and (now - self._unreachable_since) >= self.down_after
            ):
                self.down = True

        return self.down
