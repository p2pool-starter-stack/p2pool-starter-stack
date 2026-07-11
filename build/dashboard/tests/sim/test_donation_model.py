"""
Closed-loop tests for the production XvB donation controller (Issues #9, #70).

The single-step tests in tests/service/test_algo_service.py can't see how the
controller behaves over time: the calibration loop only converges as the
controller's own donations feed back through XvB's windowed averages across many
cycles. These drive the `mining_dashboard.sim` harness — which wraps the real
`AlgoService` — across simulated days and assert on the loop: that it holds the
tier at minimum waste regardless of how XvB scales the donation, never winds up,
keeps p2pool "VIP", and recovers from disturbances.
"""

import pytest

from mining_dashboard.sim.donation_model import (
    CYCLES_PER_DAY,
    CYCLES_PER_HOUR,
    Scenario,
    build_controller,
    make_algo_controller,
    run_actuated,
    run_algo,
)

# A real-ish p2pool-main sidechain difficulty so the VIP reserve is exercised.
DIFFICULTY = 120_000_000
FIELD = dict(
    target_hr=10_000,
    current_hr=46_300,
    measurement="fixed",
    p2pool_difficulty=DIFFICULTY,
    cycles=3 * CYCLES_PER_DAY,
)


class TestHoldsTierMinimumWaste:
    """The objective: hold XvB's reported average just above the tier, no more."""

    def test_holds_tier_without_overshoot(self):
        r = run_algo(Scenario(name="field", **FIELD))
        assert r.tier_held()
        assert r.steady_overshoot_1h <= 1.10  # a hair above, not multiples

    def test_no_windup_from_cold_start(self):
        """The reported bug: cold start drove donation to ~3x. The closed loop
        seeds from feedforward and trims — peak stays bounded."""
        r = run_algo(Scenario(name="cold", **FIELD))
        assert r.peak_overshoot <= 1.20

    @pytest.mark.parametrize("current_hr,expected_p2pool", [(46_300, 0.70), (200_000, 0.90)])
    def test_more_headroom_means_more_p2pool(self, current_hr, expected_p2pool):
        sc = Scenario(
            name="hr",
            target_hr=10_000,
            current_hr=current_hr,
            measurement="fixed",
            p2pool_difficulty=DIFFICULTY,
            cycles=3 * CYCLES_PER_DAY,
        )
        r = run_algo(sc)
        assert r.tier_held()
        assert r.p2pool_efficiency >= expected_p2pool


class TestSelfCalibration:
    """The headline property: hold the tier whatever the real credit factor is."""

    @pytest.mark.parametrize("k", [0.8, 1.0, 2.0, 3.0])
    def test_holds_tier_across_credit_factor(self, k):
        sc = Scenario(
            name=f"k{k}",
            target_hr=10_000,
            current_hr=46_300,
            measurement="fixed",
            credit_factor=k,
            p2pool_difficulty=DIFFICULTY,
            cycles=4 * CYCLES_PER_DAY,
        )
        r = run_algo(sc)
        assert r.tier_held()
        assert r.steady_overshoot_24h <= 1.12  # no k-x waste — the loop backs off

    def test_overcredit_frees_p2pool(self):
        """When XvB over-credits, holding the tier needs *less* donation, so more
        hashrate stays on p2pool — the open-loop designs can't do this."""
        lo = run_algo(
            Scenario(
                name="k1",
                target_hr=10_000,
                current_hr=46_300,
                measurement="fixed",
                credit_factor=1.0,
                p2pool_difficulty=DIFFICULTY,
                cycles=4 * CYCLES_PER_DAY,
            )
        )
        hi = run_algo(
            Scenario(
                name="k3",
                target_hr=10_000,
                current_hr=46_300,
                measurement="fixed",
                credit_factor=3.0,
                p2pool_difficulty=DIFFICULTY,
                cycles=4 * CYCLES_PER_DAY,
            )
        )
        assert hi.p2pool_efficiency > lo.p2pool_efficiency + 0.05

    @pytest.mark.parametrize("semantics", ["fixed", "connected"])
    def test_stable_under_lag(self, semantics):
        """Low gain keeps the integrator stable even with API reporting lag (the
        harness found that higher gains hunt)."""
        sc = Scenario(
            name="lag",
            target_hr=10_000,
            current_hr=46_300,
            measurement=semantics,
            report_lag_cycles=6,
            credit_factor=2.0,
            p2pool_difficulty=DIFFICULTY,
            cycles=5 * CYCLES_PER_DAY,
        )
        r = run_algo(sc)
        assert r.tier_held()
        last_day = r.credited_1h[-CYCLES_PER_DAY:]
        spread = (max(last_day) - min(last_day)) / sc.target_hr
        assert spread < 0.10  # settled, not oscillating


class TestActuatedRunLoop:
    """The #423 regression, pinned at the tier the fixed-step sim is blind to.

    `run_algo` models the decision and *assumes* the SPLIT remainder dwell runs
    its course — it was green while prod overshot 26-44%, because the shipping
    `_smart_sleep` collapsed every remainder to one 30s tick (its early-exit
    fired on the held SPLIT decision itself). `run_actuated` replays the run()
    loop in wall-clock seconds through the real dwell predicate, so these tests
    fail against that pre-fix predicate (steady ~1.17-1.21x AND the tier
    intermittently lost as the loop sawtooths) and pass with the held-decision
    fix (steady 1.03x = target + cushion, tier held throughout)."""

    @pytest.mark.parametrize(
        "current_hr",
        [46_300, 57_000],  # the #70 field rig, and a prod-#423-sized fleet
    )
    def test_actuated_steady_state_converges_to_reference(self, current_hr):
        sc = Scenario(
            name=f"actuated-{current_hr}",
            target_hr=10_000,
            current_hr=current_hr,
            p2pool_difficulty=DIFFICULTY,
            cycles=3 * CYCLES_PER_DAY,
        )
        r = run_actuated(sc)
        # Held: both credited averages stay at/above threshold across steady state
        # (undershoot drops the tier — worse than the waste this issue is about).
        assert r.tier_held()
        # Converged: a hair above threshold (the noise cushion), no sustained
        # overshoot on either window. Pre-fix this sits at 1.17-1.21x.
        assert r.steady_overshoot_1h <= 1.06
        assert r.steady_overshoot_24h <= 1.06

    def test_actuated_duty_matches_command_not_dwell_collapse(self):
        """The actuated share of time on XvB must be what holding the reference
        needs (~ref/hr + ramp compensation), not the slice/(slice+tick) duty the
        collapsed dwell produced (pre-fix: ~32% for a 22% requirement)."""
        sc = Scenario(
            name="duty",
            target_hr=10_000,
            current_hr=46_300,
            p2pool_difficulty=DIFFICULTY,
            cycles=3 * CYCLES_PER_DAY,
        )
        r = run_actuated(sc)
        assert r.donated_duty <= 0.27  # ~10.3k/46.3k plus switch-ramp compensation


class TestVipReserve:
    """p2pool must keep finding shares (VIP), or a win is skipped and failed."""

    def test_reserve_keeps_p2pool_in_the_window(self):
        r = run_algo(Scenario(name="vip", **FIELD))
        assert r.vip_held()  # >= 1 expected share in the PPLNS window throughout

    def test_low_tier_high_difficulty_caps_donation_for_vip(self):
        """With a high sidechain difficulty relative to hashrate, the reserve must
        bite — donation is capped so p2pool still lands shares."""
        # Difficulty needing ~half the rig on p2pool to keep ~2 shares/window.
        sc = Scenario(
            name="tightvip",
            target_hr=10_000,
            current_hr=46_300,
            measurement="fixed",
            p2pool_difficulty=300_000_000,
            cycles=3 * CYCLES_PER_DAY,
        )
        r = run_algo(sc)
        assert r.vip_held()
        assert max(r.fraction) <= build_controller().max_donation_fraction + 1e-9


class TestRobustnessToLowReads:
    """The clamp's old job — bound donation when the read is low for any reason —
    is now done by the integrator's low gain + bounded fraction."""

    def test_zero_reads_do_not_run_away(self):
        """Stuck-at-zero reads (cold start / failed poll) can only drift the
        integrator slowly within [0, reserve]; never a one-shot 3x."""
        algo = build_controller()
        controller = make_algo_controller(algo, p2pool_difficulty=DIFFICULTY)
        # Feed zero reads forever; donation must stay bounded well under a full cycle.
        fracs = [controller(46_300, 46_300, 0.0, 0.0) for _ in range(CYCLES_PER_DAY)]
        assert max(fracs) <= algo.max_donation_fraction + 1e-9
        # After a full day of zero reads it has drifted up, but not exploded.
        assert fracs[CYCLES_PER_HOUR] <= 0.35  # within the first hour, still modest


class TestDisturbanceRecovery:
    def test_recovers_after_worker_drop(self):
        """A sustained drop below tier capacity knocks the averages down; once
        hashrate returns the loop ramps back and re-qualifies by the end."""
        sc = Scenario(
            name="drop",
            target_hr=10_000,
            current_hr=46_300,
            warm_avg=10_300,
            measurement="fixed",
            p2pool_difficulty=DIFFICULTY,
            cycles=4 * CYCLES_PER_DAY,
            drop_at=CYCLES_PER_DAY,
            drop_until=CYCLES_PER_DAY + 18,
            drop_factor=0.2,
        )
        r = run_algo(sc)
        # Re-qualified on the 1h average by the final cycles (24h lags a full day).
        assert min(r.credited_1h[-CYCLES_PER_HOUR:]) >= sc.target_hr * 0.98
