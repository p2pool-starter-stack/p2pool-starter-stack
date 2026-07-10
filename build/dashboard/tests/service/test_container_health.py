from mining_dashboard.service.container_health import ContainerHealthMonitor


class _Clock:
    """Manually advanced clock for deterministic debounce tests."""

    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, secs):
        self.t += secs


def _monitor(crash_restarts=3, crash_window=600, unhealthy_after=120, recovery_after=120):
    clock = _Clock()
    m = ContainerHealthMonitor(
        crash_restarts=crash_restarts,
        crash_window=crash_window,
        unhealthy_after=unhealthy_after,
        recovery_after=recovery_after,
        clock=clock,
    )
    return m, clock


def _s(restart_count=0, restarting=False, health=None, running=True):
    """One container's inspect snapshot, as the collector shapes it."""
    return {
        "restart_count": restart_count,
        "restarting": restarting,
        "health": health,
        "running": running,
    }


class TestBaseline:
    def test_first_sighting_healthy_is_silent(self):
        m, _ = _monitor()
        assert m.update({"monerod": _s()}) == []

    def test_first_sighting_with_history_of_restarts_is_silent(self):
        # A non-zero RestartCount at dashboard start is history, not a live crash loop — the
        # count baselines silently and only *deltas* from here count.
        m, clock = _monitor()
        assert m.update({"monerod": _s(restart_count=42)}) == []
        clock.advance(30)
        assert m.update({"monerod": _s(restart_count=42)}) == []

    def test_first_sighting_unhealthy_seeds_bad_silently(self):
        # A container already unhealthy at dashboard start must not replay a stale edge —
        # and its later recovery is silent too (this process never alerted the problem).
        m, clock = _monitor()
        assert m.update({"monerod": _s(health="unhealthy")}) == []
        clock.advance(600)
        assert m.update({"monerod": _s(health="unhealthy")}) == []
        assert m.update({"monerod": _s(health="healthy")}) == []
        clock.advance(120)
        assert m.update({"monerod": _s(health="healthy")}) == []

    def test_steady_healthy_emits_nothing(self):
        m, clock = _monitor()
        m.update({"monerod": _s(health="healthy")})
        for _ in range(5):
            clock.advance(60)
            assert m.update({"monerod": _s(health="healthy")}) == []


class TestCrashLoop:
    def test_three_restarts_in_window_fire_once(self):
        m, clock = _monitor()
        m.update({"p2pool": _s(restart_count=0)})  # baseline
        clock.advance(60)
        assert m.update({"p2pool": _s(restart_count=1)}) == []
        clock.advance(60)
        assert m.update({"p2pool": _s(restart_count=2)}) == []
        clock.advance(60)
        assert m.update({"p2pool": _s(restart_count=3)}) == [("p2pool", "crash_loop")]
        # Still looping — one alert per incident, not one per restart.
        clock.advance(60)
        assert m.update({"p2pool": _s(restart_count=4)}) == []

    def test_burst_of_restarts_between_polls_fires_once(self):
        m, clock = _monitor()
        m.update({"p2pool": _s(restart_count=0)})
        clock.advance(60)
        assert m.update({"p2pool": _s(restart_count=7)}) == [("p2pool", "crash_loop")]

    def test_slow_restarts_stay_silent(self):
        # 3 restarts spread over more than the window is churn, not a crash loop.
        m, clock = _monitor()
        m.update({"p2pool": _s(restart_count=0)})
        for count in (1, 2, 3):
            clock.advance(601)
            assert m.update({"p2pool": _s(restart_count=count)}) == []

    def test_restart_count_reset_rebaselines_silently(self):
        # Docker resetting RestartCount (e.g. the container was recreated) is a *decrease* —
        # rebaseline, never treat the next count as a fresh burst of restarts.
        m, clock = _monitor()
        m.update({"p2pool": _s(restart_count=5)})
        clock.advance(60)
        assert m.update({"p2pool": _s(restart_count=0)}) == []
        clock.advance(60)
        assert m.update({"p2pool": _s(restart_count=2)}) == []  # only +2 since the reset

    def test_restarting_two_consecutive_updates_fires(self):
        m, clock = _monitor()
        m.update({"tari": _s()})  # baseline healthy
        clock.advance(30)
        assert m.update({"tari": _s(restarting=True)}) == []
        clock.advance(30)
        assert m.update({"tari": _s(restarting=True)}) == [("tari", "crash_loop")]

    def test_restarting_single_blip_is_silent(self):
        # One poll catching a normal restart-policy restart mid-flight must not page.
        m, clock = _monitor()
        m.update({"tari": _s()})
        clock.advance(30)
        assert m.update({"tari": _s(restarting=True)}) == []
        clock.advance(30)
        assert m.update({"tari": _s()}) == []


class TestUnhealthy:
    def test_unhealthy_below_debounce_is_silent(self):
        m, clock = _monitor()
        m.update({"monerod": _s(health="healthy")})
        clock.advance(30)
        assert m.update({"monerod": _s(health="unhealthy")}) == []  # streak starts
        clock.advance(89)
        assert m.update({"monerod": _s(health="unhealthy")}) == []  # 89s < 120s

    def test_unhealthy_past_debounce_fires_once(self):
        m, clock = _monitor()
        m.update({"monerod": _s(health="healthy")})
        assert m.update({"monerod": _s(health="unhealthy")}) == []
        clock.advance(120)
        assert m.update({"monerod": _s(health="unhealthy")}) == [("monerod", "unhealthy")]
        clock.advance(120)
        assert m.update({"monerod": _s(health="unhealthy")}) == []  # no repeat

    def test_flapping_healthcheck_does_not_page(self):
        # One failing probe between healthy polls resets the streak — never an edge.
        m, clock = _monitor()
        m.update({"monerod": _s(health="healthy")})
        for _ in range(5):
            clock.advance(60)
            assert m.update({"monerod": _s(health="unhealthy")}) == []
            clock.advance(60)
            assert m.update({"monerod": _s(health="healthy")}) == []

    def test_no_healthcheck_is_never_unhealthy(self):
        # health=None means "no healthcheck" — no signal, not a problem.
        m, clock = _monitor()
        m.update({"tor": _s(health=None)})
        clock.advance(600)
        assert m.update({"tor": _s(health=None)}) == []


class TestRecovery:
    def _take_unhealthy(self, m, clock, name="monerod"):
        m.update({name: _s(health="healthy")})
        m.update({name: _s(health="unhealthy")})
        clock.advance(120)
        assert m.update({name: _s(health="unhealthy")}) == [(name, "unhealthy")]

    def test_recovered_only_after_stable_window(self):
        m, clock = _monitor()
        self._take_unhealthy(m, clock)
        assert m.update({"monerod": _s(health="healthy")}) == []  # clean streak starts
        clock.advance(119)
        assert m.update({"monerod": _s(health="healthy")}) == []
        clock.advance(1)
        assert m.update({"monerod": _s(health="healthy")}) == [("monerod", "recovered")]

    def test_recovery_then_relapse_alerts_again(self):
        m, clock = _monitor()
        self._take_unhealthy(m, clock)
        m.update({"monerod": _s(health="healthy")})
        clock.advance(120)
        assert m.update({"monerod": _s(health="healthy")}) == [("monerod", "recovered")]
        # A fresh incident after recovery is a fresh alert.
        m.update({"monerod": _s(health="unhealthy")})
        clock.advance(120)
        assert m.update({"monerod": _s(health="unhealthy")}) == [("monerod", "unhealthy")]

    def test_crash_loop_recovery_waits_out_recent_restarts(self):
        # A slow crash loop runs "clean" between OOMs; recovery must not ping-pong with the
        # next restart — it needs a restart-free clean window too.
        m, clock = _monitor()
        m.update({"p2pool": _s(restart_count=0)})
        clock.advance(10)
        assert m.update({"p2pool": _s(restart_count=3)}) == [("p2pool", "crash_loop")]
        clock.advance(119)  # clean, but the last restart is only 119s old
        assert m.update({"p2pool": _s(restart_count=3)}) == []
        clock.advance(120)
        assert m.update({"p2pool": _s(restart_count=3)}) == [("p2pool", "recovered")]


class TestNeverAnEdge:
    def test_exited_is_never_an_edge(self):
        # The stack stops p2pool/xmrig-proxy on purpose (sync gate #35, failover #31) —
        # "exited" (not running, not restarting) must never page, no matter how long.
        m, clock = _monitor()
        m.update({"xmrig-proxy": _s()})
        for _ in range(10):
            clock.advance(600)
            assert m.update({"xmrig-proxy": _s(running=False)}) == []

    def test_disappearing_container_is_forgotten_silently(self):
        # A container gone from the snapshot (profile off, remote mode, proxy down) is no
        # verdict — forget it; a later return re-baselines with no edge.
        m, clock = _monitor()
        m.update({"monerod": _s(health="unhealthy")})
        clock.advance(600)
        assert m.update({}) == []
        assert m.update({"monerod": _s(health="unhealthy")}) == []  # fresh silent baseline

    def test_stop_while_unhealthy_pending_resets_the_streak(self):
        # An intentional stop mid-streak clears the unhealthy debounce — restarting the clock,
        # not carrying a stale verdict across the outage.
        m, clock = _monitor()
        m.update({"monerod": _s(health="healthy")})
        m.update({"monerod": _s(health="unhealthy")})
        clock.advance(60)
        assert m.update({"monerod": _s(health="unhealthy", running=False)}) == []
        clock.advance(120)
        # Back up and unhealthy again: the streak starts fresh, so no immediate edge.
        assert m.update({"monerod": _s(health="unhealthy")}) == []
