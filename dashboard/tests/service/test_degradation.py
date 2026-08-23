"""Unit tests for the hashrate-degradation detector (Issue #99).

Pure logic, driven by an injectable clock — no timers, no sleeps. Each test walks the monitor
through a scripted (value, time) sequence and asserts which edges fire.
"""

from mining_dashboard.service.degradation import DegradationMonitor


def _mon(**kw):
    # Small thresholds so tests read clearly: baseline established above 500, 50% drop for 600s.
    kw.setdefault("min_baseline", 500)
    return DegradationMonitor(**kw)


def test_steady_state_never_fires():
    m = _mon()
    for t in range(0, 6000, 60):
        assert m.update(1000, now=t) is None


def test_cold_start_below_min_baseline_is_silent():
    m = _mon(min_baseline=500)
    # A tiny fleet that never crosses min_baseline can't be "degraded", even at zero hashrate.
    for t in range(0, 3000, 60):
        assert m.update(100, now=t) is None
        assert m.update(0, now=t + 30) is None


def test_sustained_drop_fires_loss_once():
    m = _mon(sustained_sec=600, threshold_frac=0.5)
    m.update(1000, now=0)  # seed baseline
    # Drop to zero and hold; nothing until the debounce window elapses.
    assert m.update(0, now=60) is None
    assert m.update(0, now=600) is None
    edge = m.update(0, now=660)  # 600s below threshold since t=60
    assert edge is not None
    kind, drop_frac, baseline, current = edge
    assert kind == "loss"
    assert drop_frac > 0.9
    assert current == 0
    # Still down — no repeat.
    assert m.update(0, now=1300) is None


def test_brief_blip_does_not_fire():
    m = _mon(sustained_sec=600, threshold_frac=0.5)
    m.update(1000, now=0)
    assert m.update(0, now=60) is None  # blip starts
    assert m.update(1000, now=120) is None  # recovers well before 600s
    # Baseline intact, clock reset — a later full window from scratch is needed to fire.
    assert m.update(0, now=180) is None
    assert m.update(0, now=700) is None
    assert m.update(0, now=781) is not None  # 600s since t=180


def test_recovery_fires_after_hold():
    m = _mon(sustained_sec=600, recovery_frac=0.8, recovery_sec=120)
    m.update(1000, now=0)
    m.update(0, now=60)
    assert m.update(0, now=660)[0] == "loss"
    # Climb back above 80% of baseline and hold recovery_sec.
    assert m.update(1000, now=720) is None
    edge = m.update(1000, now=840)  # 120s above recovery threshold
    assert edge is not None and edge[0] == "recovered"


def test_baseline_frozen_while_degraded():
    # A sustained drop must not erode the baseline (which would mask the outage and prevent recovery
    # detection). Once degraded, the baseline is pinned — a long outage doesn't drag it down.
    m = _mon(sustained_sec=600, recovery_frac=0.8, recovery_sec=120)
    m.update(1000, now=0)
    m.update(0, now=60)
    assert m.update(0, now=660)[0] == "loss"
    frozen = m._baseline
    # Long stretch near zero — an unfrozen EMA would drift the baseline down over dozens of samples.
    for t in range(700, 6000, 60):
        m.update(10, now=t)
    assert m._baseline == frozen  # pinned to the pre-drop level
    m.update(1000, now=6060)
    assert m.update(1000, now=6200)[0] == "recovered"
