from mining_dashboard.service.node_health import NodeHealthMonitor


class _Clock:
    """Manually advanced monotonic clock for deterministic debounce tests."""

    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, secs):
        self.t += secs


def _monitor(down_after=90, recovery_after=60):
    clock = _Clock()
    return NodeHealthMonitor(
        down_after=down_after, recovery_after=recovery_after, clock=clock
    ), clock


class TestDebounceToDown:
    def test_not_down_before_threshold(self):
        m, clock = _monitor()
        m.update(True)  # establish ever_up
        m.update(False)  # outage begins
        clock.advance(89)
        assert m.update(False) is False  # still within debounce window

    def test_down_after_threshold(self):
        m, clock = _monitor()
        m.update(True)
        m.update(False)
        clock.advance(90)
        assert m.update(False) is True

    def test_single_blip_does_not_trip(self):
        m, clock = _monitor()
        m.update(True)
        clock.advance(5)
        m.update(False)  # brief blip
        clock.advance(5)
        assert m.update(True) is False  # recovered well before 90s
        assert m.down is False


class TestEverUpGuard:
    def test_never_reachable_never_down(self):
        # A node that has never been reachable (remote RPC, wrong creds) must not flip DOWN,
        # so we never reject workers over something that never worked.
        m, clock = _monitor()
        for _ in range(10):
            clock.advance(100)
            assert m.update(False) is False
        assert m.ever_up is False and m.down is False


class TestRecoveryHysteresis:
    def test_down_clears_only_after_recovery_window(self):
        m, clock = _monitor()
        m.update(True)
        m.update(False)
        clock.advance(90)
        m.update(False)  # now DOWN
        assert m.down is True
        # Node returns, but DOWN holds until reachable for recovery_after.
        m.update(True)
        assert m.down is True and m.healthy is False
        clock.advance(59)
        m.update(True)
        assert m.down is True
        clock.advance(1)
        m.update(True)
        assert m.down is False and m.healthy is True

    def test_healthy_requires_stable_window_from_unknown(self):
        # A fresh monitor (e.g. dashboard restart) is neither down nor healthy until it has
        # observed the node reachable for the recovery window.
        m, clock = _monitor()
        assert m.update(True) is False
        assert m.healthy is False  # just came up — not yet confirmed
        clock.advance(60)
        m.update(True)
        assert m.healthy is True
