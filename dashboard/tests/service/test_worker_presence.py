from mining_dashboard.service.worker_presence import WorkerPresenceMonitor


class _Clock:
    """Manually advanced clock for deterministic debounce tests."""

    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, secs):
        self.t += secs


def _monitor(offline_after=300, recovery_after=120):
    clock = _Clock()
    m = WorkerPresenceMonitor(
        offline_after=offline_after, recovery_after=recovery_after, clock=clock
    )
    return m, clock


def _on(*names):
    """Worker rows the proxy reports online."""
    return [{"name": n, "status": "online"} for n in names]


def _down(*names):
    """Worker rows still listed by the proxy but disconnected — the DOWN state the UI shows."""
    return [{"name": n, "status": "offline"} for n in names]


class TestBaseline:
    def test_first_sighting_online_is_silent(self):
        # A brand-new worker is baselined ONLINE with no edge — it's not a "recovery".
        m, _ = _monitor()
        assert m.update(_on("rig-1")) == []

    def test_first_sighting_down_is_silent(self):
        # A rig already DOWN at startup baselines OFFLINE silently — a restart must not replay it.
        m, _ = _monitor()
        assert m.update(_down("rig-1")) == []
        assert m._workers["rig-1"]["state"] == "offline"

    def test_steady_online_emits_nothing(self):
        m, clock = _monitor()
        m.update(_on("rig-1"))
        for _ in range(5):
            clock.advance(30)
            assert m.update(_on("rig-1")) == []


class TestOfflineDebounce:
    def test_not_offline_before_threshold(self):
        m, clock = _monitor()
        m.update(_on("rig-1"))  # baseline online
        clock.advance(30)
        assert m.update(_down("rig-1")) == []  # DOWN streak starts here (within debounce)
        clock.advance(269)
        assert m.update(_down("rig-1")) == []  # 269s DOWN — still under the 300s threshold

    def test_offline_after_threshold(self):
        m, clock = _monitor()
        m.update(_on("rig-1"))
        m.update(_down("rig-1"))  # DOWN streak starts here
        clock.advance(300)
        assert m.update(_down("rig-1")) == [("rig-1", "offline")]

    def test_offline_emitted_once(self):
        m, clock = _monitor()
        m.update(_on("rig-1"))
        m.update(_down("rig-1"))
        clock.advance(300)
        assert m.update(_down("rig-1")) == [("rig-1", "offline")]
        clock.advance(300)
        assert m.update(_down("rig-1")) == []  # already offline — no repeat

    def test_brief_down_does_not_trip(self):
        m, clock = _monitor()
        m.update(_on("rig-1"))
        clock.advance(60)
        assert m.update(_down("rig-1")) == []  # DOWN 60s
        clock.advance(30)
        assert m.update(_on("rig-1")) == []  # back well before 300s

    def test_vanishing_from_table_is_left_not_offline(self):
        # A rig the proxy stops listing entirely (fell off the worker table) is reported as having
        # LEFT — never aged to "offline", which is reserved for the DOWN-but-still-listed state.
        m, clock = _monitor()
        m.update(_on("rig-1"))  # prime + baseline
        clock.advance(600)
        assert m.update([]) == [("rig-1", "left")]
        assert "rig-1" not in m._workers


class TestRecoveryHysteresis:
    def _take_offline(self, m, clock):
        m.update(_on("rig-1"))
        m.update(_down("rig-1"))
        clock.advance(300)
        assert m.update(_down("rig-1")) == [("rig-1", "offline")]

    def test_recovered_only_after_stable_window(self):
        m, clock = _monitor()
        self._take_offline(m, clock)
        # Reappears online, but "back online" holds until it's been present for recovery_after.
        assert m.update(_on("rig-1")) == []
        clock.advance(119)
        assert m.update(_on("rig-1")) == []
        clock.advance(1)
        assert m.update(_on("rig-1")) == [("rig-1", "recovered")]

    def test_flap_during_recovery_does_not_emit(self):
        # A one-cycle reconnect during an outage must not produce a recovered→offline spam.
        m, clock = _monitor()
        self._take_offline(m, clock)
        clock.advance(30)
        assert m.update(_on("rig-1")) == []  # blink online (still offline)
        clock.advance(30)
        assert m.update(_down("rig-1")) == []  # blink DOWN — no recovered, no re-offline
        clock.advance(30)
        assert m.update(_down("rig-1")) == []


class TestMultipleWorkers:
    def test_independent_per_worker_state(self):
        m, clock = _monitor()
        m.update(_on("rig-1", "rig-2"))
        # rig-2 stays online; rig-1 goes DOWN.
        m.update(_on("rig-2") + _down("rig-1"))
        clock.advance(300)
        assert m.update(_on("rig-2") + _down("rig-1")) == [("rig-1", "offline")]


class TestReset:
    def test_reset_clears_state_and_rebaselines_silently(self):
        m, clock = _monitor()
        m.update(_on("rig-1"))
        m.update(_down("rig-1"))
        clock.advance(300)
        assert m.update(_down("rig-1")) == [("rig-1", "offline")]
        m.reset()
        # After a reset (e.g. proxy intentionally stopped), the worker re-appears as a fresh
        # baseline — no "recovered" edge.
        assert m.update(_on("rig-1")) == []


class TestFalloff:
    def test_worker_forgotten_when_it_leaves_the_table(self):
        m, clock = _monitor()
        m.update(_on("rig-1"))
        m.update(_down("rig-1"))
        clock.advance(300)
        m.update(_down("rig-1"))  # offline emitted
        # The lifecycle eventually drops the ghost from the worker table (#182) → LEFT edge.
        assert m.update([]) == [("rig-1", "left")]
        assert "rig-1" not in m._workers
        # Returning after that counts as a fresh JOIN.
        assert m.update(_on("rig-1")) == [("rig-1", "joined")]


class TestJoinLeave:
    def test_first_cycle_baselines_silently(self):
        # The startup roster is baselined without joined edges — a restart isn't a fleet change.
        m, _ = _monitor()
        assert m.update(_on("rig-1", "rig-2")) == []

    def test_new_worker_after_prime_joins(self):
        m, _ = _monitor()
        m.update(_on("rig-1"))  # prime
        assert m.update(_on("rig-1", "rig-2")) == [("rig-2", "joined")]

    def test_worker_leaving_emits_left(self):
        m, _ = _monitor()
        m.update(_on("rig-1", "rig-2"))  # prime
        assert m.update(_on("rig-1")) == [("rig-2", "left")]

    def test_reset_reprimes_without_joins(self):
        m, _ = _monitor()
        m.update(_on("rig-1"))  # prime
        m.reset()  # e.g. proxy stopped for a failover — clears the prime flag
        # Readmission re-baselines the whole roster silently — no "joined" spam.
        assert m.update(_on("rig-1", "rig-2")) == []
