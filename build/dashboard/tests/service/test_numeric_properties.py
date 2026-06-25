"""Property-based tests (#284, hypothesis) for the money/numeric service layer.

These assert *invariants* — non-negativity, conservation, monotonicity, clamp bounds — across a
wide input range rather than fixed examples, the class of bug example tests miss (cf. the #70
anti-windup overshoot). Pure functions only; no I/O.
"""

import math
from unittest.mock import MagicMock

from hypothesis import given
from hypothesis import strategies as st

from mining_dashboard.config.config import TIER_DEFAULTS, XVB_TIME_ALGO_MS
from mining_dashboard.service.algo_service import AlgoService
from mining_dashboard.service.earnings import xmr_per_hs_day
from mining_dashboard.service.metrics import _avg_p2pool_over_window, _avg_xvb_over_window

_nonneg = st.floats(min_value=0, max_value=1e18, allow_nan=False, allow_infinity=False)
_pos = st.floats(min_value=1e-6, max_value=1e15, allow_nan=False, allow_infinity=False)


# --------------------------------------------------------------------------- earnings
@given(reward=_nonneg, diff=_nonneg)
def test_xmr_per_hs_day_non_negative(reward, diff):
    assert xmr_per_hs_day(reward, diff) >= 0.0


@given(reward=st.floats(max_value=0, allow_nan=False, allow_infinity=False), diff=_nonneg)
def test_xmr_per_hs_day_zero_on_nonpositive_reward(reward, diff):
    assert xmr_per_hs_day(reward, diff) == 0.0


@given(reward=_pos, diff=_pos, k=st.floats(min_value=0, max_value=1e6, allow_nan=False))
def test_xmr_per_hs_day_linear_in_reward(reward, diff, k):
    # Expected earnings are linear in the block reward (the model's defining property).
    base = xmr_per_hs_day(reward, diff)
    assert math.isclose(xmr_per_hs_day(k * reward, diff), k * base, rel_tol=1e-9, abs_tol=1e-30)


@given(reward=_pos, diff=_pos, bump=_pos)
def test_xmr_per_hs_day_decreases_with_difficulty(reward, diff, bump):
    # Higher network difficulty -> a lower per-H/s rate.
    assert xmr_per_hs_day(reward, diff + bump) <= xmr_per_hs_day(reward, diff)


# --------------------------------------------------------------- metrics windowed averages
@st.composite
def _in_window_rows(draw):
    """History rows inside the window, with v == v_p2pool + v_xvb (no legacy fallback)."""
    hr = st.floats(min_value=0, max_value=1e9, allow_nan=False, allow_infinity=False)
    rows = []
    for _ in range(draw(st.integers(min_value=1, max_value=30))):
        vp, vx = draw(hr), draw(hr)
        rows.append({"timestamp": 10**12, "v_p2pool": vp, "v_xvb": vx, "v": vp + vx})
    return rows


@given(rows=_in_window_rows())
def test_window_avgs_non_negative_and_conserve(rows):
    window = 10**9  # all rows fall inside
    ap = _avg_p2pool_over_window(rows, window)
    ax = _avg_xvb_over_window(rows, window)
    assert ap >= 0.0 and ax >= 0.0
    # Conservation: with v == vp + vx (no legacy fallback), the routed parts sum to the total avg.
    avg_v = sum(r["v"] for r in rows) / len(rows)
    assert math.isclose(ap + ax, avg_v, rel_tol=1e-9, abs_tol=1e-6)


@given(window=st.floats(min_value=1, max_value=1e9, allow_nan=False))
def test_window_avgs_empty_history_is_zero(window):
    assert _avg_p2pool_over_window([], window) == 0.0
    assert _avg_xvb_over_window([], window) == 0.0


# --------------------------------------------------------------- algo_service clamp / fraction
def _algo():
    sm = MagicMock()
    sm.get_tiers.return_value = dict(TIER_DEFAULTS)
    return AlgoService(sm, MagicMock(), MagicMock())


@given(frac=st.floats(min_value=0, max_value=1, allow_nan=False))
def test_fraction_to_ms_monotone_and_non_negative(frac):
    a = _algo()
    assert a._fraction_to_ms(frac) >= 0
    # A larger fraction never yields a shorter slice.
    assert a._fraction_to_ms(frac) <= a._fraction_to_ms(min(frac + 0.1, 1.0))


@given(frac=st.floats(max_value=0, allow_nan=False, allow_infinity=False))
def test_fraction_to_ms_zero_on_nonpositive(frac):
    assert _algo()._fraction_to_ms(frac) == 0


@given(dur=st.floats(min_value=0, max_value=XVB_TIME_ALGO_MS, allow_nan=False))
def test_routed_fraction_in_unit_interval(dur):
    assert AlgoService._routed_fraction("XVB", dur) == 1.0
    assert AlgoService._routed_fraction("P2POOL", dur) == 0.0
    assert 0.0 <= AlgoService._routed_fraction("SPLIT", dur) <= 1.0


@given(
    current_hr=st.floats(min_value=1, max_value=1e9, allow_nan=False),
    window=st.floats(min_value=1, max_value=1e6, allow_nan=False),
    diff=st.floats(min_value=0, max_value=1e15, allow_nan=False),
)
def test_max_donation_fraction_within_reserve_bounds(current_hr, window, diff):
    # The VIP/PPLNS reserve clamp must keep the donatable fraction in [0, the hard cap].
    a = _algo()
    f = a._max_donation_fraction(current_hr, window, {"difficulty": diff})
    assert 0.0 <= f <= a.max_donation_fraction
