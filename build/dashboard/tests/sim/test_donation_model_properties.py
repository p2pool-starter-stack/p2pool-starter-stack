"""Property-based tests (#284, hypothesis) for the XvB donation-controller simulator.

The closed-loop controller (Issue #70) must never *wind up*: whatever the rig hashrate, tier
target, measurement semantics, crediting, or report lag, the donated fraction stays clamped to
[0, 1] every cycle — so p2pool efficiency stays in [0, 1] and the credited rate stays non-negative.
Asserting this over randomized scenarios catches the overshoot class of bug that the fixed-example
tests in test_donation_model.py can't.
"""

from hypothesis import given, settings
from hypothesis import strategies as st

from mining_dashboard.sim.donation_model import CYCLES_PER_DAY, Scenario, run_algo

_hr = st.floats(min_value=1e3, max_value=1e7, allow_nan=False, allow_infinity=False)


@settings(max_examples=50, deadline=None)
@given(
    target_hr=_hr,
    current_hr=_hr,
    warm_avg=st.floats(min_value=0, max_value=1e7, allow_nan=False),
    measurement=st.sampled_from(["fixed", "connected"]),
    credit_factor=st.floats(min_value=0.5, max_value=2.0, allow_nan=False),
    report_lag=st.integers(min_value=0, max_value=6),
)
def test_controller_never_winds_up(
    target_hr, current_hr, warm_avg, measurement, credit_factor, report_lag
):
    result = run_algo(
        Scenario(
            name="prop",
            target_hr=target_hr,
            current_hr=current_hr,
            cycles=2 * CYCLES_PER_DAY,  # 2 days — reaches steady state, stays fast
            warm_avg=warm_avg,
            measurement=measurement,
            credit_factor=credit_factor,
            report_lag_cycles=report_lag,
        )
    )
    # Anti-windup (#70): the donated fraction is clamped to [0, 1] every cycle ...
    assert all(0.0 <= f <= 1.0 for f in result.fraction)
    # ... so the derived steady-state efficiency and the credited rate stay sane.
    assert 0.0 <= result.p2pool_efficiency <= 1.0
    assert all(c >= 0.0 for c in result.credited)
