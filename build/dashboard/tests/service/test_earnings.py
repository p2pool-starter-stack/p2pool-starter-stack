"""Unit tests for the expected-earnings model (mining_dashboard/service/earnings.py).

The model is one linear rate — XMR per H/s per day — derived from the live block reward and
network difficulty. These tests pin the math (including the worked field example), the units, and
the graceful-degradation behaviour when inputs are missing. The client scales this rate to the
what-if hashrate; that scaling/formatting is tested in tests/frontend/logic.test.mjs.
"""

import pytest

from mining_dashboard.service.earnings import (
    ATOMIC_PER_XMR,
    SECONDS_PER_DAY,
    xmr_per_hs_day,
    xtm_per_hs_day,
)


class TestXmrPerHsDay:
    def test_matches_closed_form(self):
        # reward_xmr / difficulty * seconds_per_day, with reward given in atomic units.
        reward_atomic = 0.6 * ATOMIC_PER_XMR  # 0.6 XMR block reward
        difficulty = 400_000_000_000  # 400 G
        expected = 0.6 / difficulty * SECONDS_PER_DAY
        assert xmr_per_hs_day(reward_atomic, difficulty) == pytest.approx(expected)

    def test_worked_field_example(self):
        # A 50 kH/s rig at 0.6 XMR / 400 G difficulty earns ~0.00648 XMR/day. This cross-checks
        # the rate against the independent "share of daily emission" derivation:
        #   network_hr = diff/120 = 3.33 GH/s; share = 50k/3.33e9; emission = 0.6 * 86400/120.
        rate = xmr_per_hs_day(0.6 * ATOMIC_PER_XMR, 400_000_000_000)
        assert rate * 50_000 == pytest.approx(0.00648, rel=1e-3)

    def test_linear_in_inputs(self):
        # Double the reward -> double the rate; double the difficulty -> half the rate.
        base = xmr_per_hs_day(ATOMIC_PER_XMR, 1_000_000)
        assert xmr_per_hs_day(2 * ATOMIC_PER_XMR, 1_000_000) == pytest.approx(2 * base)
        assert xmr_per_hs_day(ATOMIC_PER_XMR, 2_000_000) == pytest.approx(base / 2)

    @pytest.mark.parametrize(
        "reward,diff",
        [
            (0, 400_000_000_000),  # no reward collected yet
            (0.6 * ATOMIC_PER_XMR, 0),  # no difficulty yet
            (0, 0),  # nothing collected
            (-1, 400_000_000_000),  # defensive: negative reward
            (0.6 * ATOMIC_PER_XMR, -5),  # defensive: negative difficulty
        ],
    )
    def test_missing_or_bad_inputs_are_zero(self, reward, diff):
        # A zero rate is the dashboard's "unavailable" signal (shows "—"); never raise or divide
        # by zero on incomplete live data.
        assert xmr_per_hs_day(reward, diff) == 0.0


class TestXtmPerHsDay:
    """Tari merge-mining rate (#117) — same linear expectation, reward already in XTM."""

    def test_matches_closed_form(self):
        # reward_xtm / difficulty * seconds_per_day — no atomic conversion (the collector already
        # converts p2pool's µT figure to XTM).
        assert xtm_per_hs_day(13_000, 400_000_000_000) == pytest.approx(
            13_000 / 400_000_000_000 * SECONDS_PER_DAY
        )

    def test_linear_in_inputs(self):
        # Double the reward -> double the rate; double the difficulty -> half the rate.
        base = xtm_per_hs_day(10_000, 1_000_000)
        assert xtm_per_hs_day(20_000, 1_000_000) == pytest.approx(2 * base)
        assert xtm_per_hs_day(10_000, 2_000_000) == pytest.approx(base / 2)

    @pytest.mark.parametrize(
        "reward,diff",
        [
            (0, 400_000_000_000),  # Tari inactive / still syncing: no reward collected
            (13_000, 0),  # no difficulty yet
            (0, 0),  # nothing collected
            (-1, 400_000_000_000),  # defensive: negative reward
            (13_000, -5),  # defensive: negative difficulty
        ],
    )
    def test_missing_or_bad_inputs_are_zero(self, reward, diff):
        # Zero is the "unavailable" signal — the card shows "—" and Telegram omits the line.
        assert xtm_per_hs_day(reward, diff) == 0.0
