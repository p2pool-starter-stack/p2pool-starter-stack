from mining_dashboard.service.worker_presence import WorkerPresenceMonitor


class _Clock:
    """Manually advanced clock for deterministic debounce tests."""

    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, secs):
        self.t += secs


def _monitor(offline_after=300, recovery_after=120, retention=7 * 24 * 3600):
    clock = _Clock()
    m = WorkerPresenceMonitor(
        offline_after=offline_after, recovery_after=recovery_after, retention=retention, clock=clock
    )
    return m, clock


class TestBaseline:
    def test_first_sighting_is_silent(self):
        # A brand-new worker is registered ONLINE with no edge — it's not a "recovery".
        m, _ = _monitor()
        assert m.update({"rig-1"}) == []

    def test_steady_online_emits_nothing(self):
        m, clock = _monitor()
        m.update({"rig-1"})
        for _ in range(5):
            clock.advance(30)
            assert m.update({"rig-1"}) == []


class TestOfflineDebounce:
    def test_not_offline_before_threshold(self):
        m, clock = _monitor()
        m.update({"rig-1"})  # baseline online
        clock.advance(30)
        assert m.update(set()) == []  # absence streak starts here (within debounce)
        clock.advance(269)
        assert m.update(set()) == []  # 269s absent — still under the 300s threshold

    def test_offline_after_threshold(self):
        m, clock = _monitor()
        m.update({"rig-1"})
        m.update(set())  # absence streak starts here
        clock.advance(300)
        assert m.update(set()) == [("rig-1", "offline")]

    def test_offline_emitted_once(self):
        m, clock = _monitor()
        m.update({"rig-1"})
        m.update(set())
        clock.advance(300)
        assert m.update(set()) == [("rig-1", "offline")]
        clock.advance(300)
        assert m.update(set()) == []  # already offline — no repeat

    def test_brief_drop_does_not_trip(self):
        m, clock = _monitor()
        m.update({"rig-1"})
        clock.advance(60)
        assert m.update(set()) == []  # gone 60s
        clock.advance(30)
        assert m.update({"rig-1"}) == []  # back well before 300s


class TestRecoveryHysteresis:
    def _take_offline(self, m, clock):
        m.update({"rig-1"})
        m.update(set())
        clock.advance(300)
        assert m.update(set()) == [("rig-1", "offline")]

    def test_recovered_only_after_stable_window(self):
        m, clock = _monitor()
        self._take_offline(m, clock)
        # Reappears, but "back online" holds until it's been present for recovery_after.
        assert m.update({"rig-1"}) == []
        clock.advance(119)
        assert m.update({"rig-1"}) == []
        clock.advance(1)
        assert m.update({"rig-1"}) == [("rig-1", "recovered")]

    def test_flap_during_recovery_does_not_emit(self):
        # A one-cycle reconnect during an outage must not produce a recovered→offline spam.
        m, clock = _monitor()
        self._take_offline(m, clock)
        clock.advance(30)
        assert m.update({"rig-1"}) == []  # blink on (still offline)
        clock.advance(30)
        assert m.update(set()) == []  # blink off — no recovered, no re-offline
        clock.advance(30)
        assert m.update(set()) == []


class TestMultipleWorkers:
    def test_independent_per_worker_state(self):
        m, clock = _monitor()
        m.update({"rig-1", "rig-2"})
        # rig-2 stays online; rig-1 drops.
        m.update({"rig-2"})
        clock.advance(300)
        assert m.update({"rig-2"}) == [("rig-1", "offline")]


class TestReset:
    def test_reset_clears_state_and_rebaselines_silently(self):
        m, clock = _monitor()
        m.update({"rig-1"})
        m.update(set())
        clock.advance(300)
        assert m.update(set()) == [("rig-1", "offline")]
        m.reset()
        # After a reset (e.g. proxy intentionally stopped), the worker re-appears as a fresh
        # baseline — no "recovered" edge.
        assert m.update({"rig-1"}) == []


class TestRetention:
    def test_long_absent_worker_is_forgotten(self):
        m, clock = _monitor(retention=1000)
        m.update({"rig-1"})
        m.update(set())
        clock.advance(300)
        m.update(set())  # offline emitted
        clock.advance(1000)
        m.update(set())  # past retention -> pruned
        assert "rig-1" not in m._workers
        # Returning after retention counts as new: silent baseline, not a recovery.
        assert m.update({"rig-1"}) == []
