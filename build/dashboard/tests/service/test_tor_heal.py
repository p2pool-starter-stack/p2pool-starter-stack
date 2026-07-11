"""Tests for the Tor guard self-heal (#424).

The decision core is what must be right: the healer restarts tor ONLY when egress is broken
past the sustained threshold AND the cooldown has elapsed AND the per-outage restart budget
isn't spent. Each guard is pinned separately, so inverting or deleting any of them fails a
test. The actual container restart against a real stuck guard is tier 4 (gouda).
"""

from unittest.mock import patch

import requests

from mining_dashboard.service.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    MAX_RESTARTS,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)


class _Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


class _FakeDocker:
    """Records stop/start calls; always succeeds."""

    def __init__(self):
        self.calls = []

    async def stop(self, container, **kwargs):
        self.calls.append(("stop", container))
        return True

    async def start(self, container, **kwargs):
        self.calls.append(("start", container))
        return True


def _healer(clock=None, enabled=True, probe=None, notify=None, docker=None):
    return TorEgressHealer(
        docker or _FakeDocker(),
        enabled=enabled,
        probe=probe or (lambda: False),
        notify=notify,
        clock=clock or _Clock(),
    )


def _break_egress(healer, clock):
    """Feed failing probes until the sustained threshold is crossed; the next decide may heal."""
    healer.decide(False, clock.t)
    clock.t += BROKEN_AFTER_SEC


class TestDecide:
    def test_heals_when_broken_sustained_and_no_cooldown(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"

    def test_transient_blip_never_heals(self):
        clock = _Clock()
        h = _healer(clock)
        h.decide(False, clock.t)
        clock.t += BROKEN_AFTER_SEC - 1
        assert h.decide(False, clock.t) is None

    def test_blip_that_recovers_resets_the_streak(self):
        clock = _Clock()
        h = _healer(clock)
        h.decide(False, clock.t)
        clock.t += BROKEN_AFTER_SEC - 1
        assert h.decide(True, clock.t) is None  # recovered on its own: no heal, no alert
        # A new failure starts a fresh streak — the old one must not carry over.
        assert h.decide(False, clock.t) is None
        clock.t += BROKEN_AFTER_SEC - 1
        assert h.decide(False, clock.t) is None

    def test_no_second_heal_during_cooldown(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"
        clock.t += COOLDOWN_SEC - 1
        assert h.decide(False, clock.t) is None  # still broken, but inside the cooldown

    def test_second_heal_after_cooldown(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"
        clock.t += COOLDOWN_SEC
        assert h.decide(False, clock.t) == "heal"

    def test_budget_exhausted_stops_healing_and_keeps_warning(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        for _ in range(MAX_RESTARTS):
            assert h.decide(False, clock.t) == "heal"
            clock.t += COOLDOWN_SEC
        # Budget spent: from here on it's warn-only, forever, no matter how much time passes.
        assert h.decide(False, clock.t) == "exhausted"
        clock.t += 100 * COOLDOWN_SEC
        assert h.decide(False, clock.t) == "exhausted"

    def test_recovery_after_heal_reports_and_resets_the_budget(self):
        clock = _Clock()
        h = _healer(clock)
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"
        clock.t += PROBE_INTERVAL_SEC
        assert h.decide(True, clock.t) == "recovered"
        # The next outage gets a fresh budget and must re-earn the sustained threshold.
        _break_egress(h, clock)
        assert h.decide(False, clock.t) == "heal"

    def test_recovery_without_a_heal_is_silent(self):
        clock = _Clock()
        h = _healer(clock)
        assert h.decide(True, clock.t) is None


class TestCheck:
    async def test_disabled_is_a_total_noop(self):
        def probe():
            raise AssertionError("disabled healer must never probe")

        docker = _FakeDocker()
        h = _healer(enabled=False, probe=probe, docker=docker)
        await h.check()
        assert docker.calls == []

    async def test_probe_is_throttled_to_the_interval(self):
        calls = []
        clock = _Clock()
        h = _healer(clock, probe=lambda: calls.append(1) or True)
        await h.check()
        clock.t += PROBE_INTERVAL_SEC - 1
        await h.check()  # inside the cadence: no probe
        assert len(calls) == 1
        clock.t += 1
        await h.check()
        assert len(calls) == 2

    async def test_heal_restarts_the_tor_container(self, caplog):
        clock = _Clock()
        docker = _FakeDocker()
        h = _healer(clock, probe=lambda: False, docker=docker)
        with caplog.at_level("WARNING", logger="TorHeal"):
            await h.check()  # starts the failure streak
            clock.t += BROKEN_AFTER_SEC
            await h.check()  # sustained -> heal
        assert docker.calls == [("stop", "tor"), ("start", "tor")]
        assert any("Restarting the tor container" in r.message for r in caplog.records)

    async def test_exhausted_warns_but_never_restarts(self, caplog):
        clock = _Clock()
        docker = _FakeDocker()
        h = _healer(clock, probe=lambda: False, docker=docker)
        await h.check()
        for _ in range(MAX_RESTARTS):
            clock.t += max(BROKEN_AFTER_SEC, COOLDOWN_SEC)
            await h.check()
        assert len(docker.calls) == 2 * MAX_RESTARTS  # budget fully spent
        with caplog.at_level("WARNING", logger="TorHeal"):
            clock.t += COOLDOWN_SEC
            await h.check()
        assert len(docker.calls) == 2 * MAX_RESTARTS  # no further restarts, ever
        assert any("STILL broken" in r.message for r in caplog.records)

    async def test_recovery_sends_the_one_time_notify(self):
        notes = []

        async def notify(text):
            notes.append(text)

        clock = _Clock()
        results = {"ok": False}
        h = _healer(clock, probe=lambda: results["ok"], notify=notify)
        await h.check()
        clock.t += BROKEN_AFTER_SEC
        await h.check()  # heal
        results["ok"] = True
        clock.t += PROBE_INTERVAL_SEC
        await h.check()  # recovered -> notify once
        clock.t += PROBE_INTERVAL_SEC
        await h.check()  # still fine -> silent
        assert len(notes) == 1
        assert "restarted the tor container" in notes[0]

    async def test_probe_or_restart_errors_never_escape(self):
        class _BoomDocker:
            async def stop(self, *a, **k):
                raise RuntimeError("proxy down")

            async def start(self, *a, **k):
                raise RuntimeError("proxy down")

        clock = _Clock()
        h = _healer(clock, probe=lambda: False, docker=_BoomDocker())
        await h.check()
        clock.t += BROKEN_AFTER_SEC
        await h.check()  # the failed restart must not raise into the data loop


class TestProbe:
    def test_any_http_response_counts_as_egress(self):
        with patch("mining_dashboard.service.tor_heal.requests.get") as get:
            assert TorEgressHealer._probe_egress() is True
            assert get.call_args.kwargs["proxies"]["https"].startswith("socks5h://")

    def test_network_failure_is_broken_egress(self):
        with patch(
            "mining_dashboard.service.tor_heal.requests.get",
            side_effect=requests.ConnectionError("circuit timeout"),
        ):
            assert TorEgressHealer._probe_egress() is False
