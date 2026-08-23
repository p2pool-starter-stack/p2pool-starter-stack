from unittest.mock import MagicMock, patch

import pytest

from mining_dashboard.service.algo_service import AlgoService


class TestProjectedSteering:
    """The protective trend projection (#892's steering half): the loop steers off
    min(measured 1h, projected 1h) so a credited decay is answered before it
    reaches the round minimum — and a rising trend changes nothing."""

    T0 = 1_000_000.0

    def _with_trend(self, algo, points):
        algo._avg1h_trend = [(self.T0 + dt, v) for dt, v in points]

    def test_no_projection_without_history(self, algo):
        assert algo._projected_avg_1h(100_000.0) == 100_000.0
        self._with_trend(algo, [(0, 110_000.0)])
        assert algo._projected_avg_1h(100_000.0) == 100_000.0

    def test_no_projection_below_min_span(self, algo):
        self._with_trend(algo, [(0, 110_000.0), (300, 101_000.0)])
        assert algo._projected_avg_1h(100_000.0) == 100_000.0

    def test_falling_trend_lowers_effective(self, algo):
        # -10 H/s per second over 900s; horizon 1200s -> 12k below measured.
        self._with_trend(algo, [(0, 110_000.0), (900, 101_000.0)])
        assert algo._projected_avg_1h(100_000.0) == pytest.approx(88_000.0)

    def test_rising_trend_never_raises(self, algo):
        self._with_trend(algo, [(0, 90_000.0), (900, 99_000.0)])
        assert algo._projected_avg_1h(100_000.0) == 100_000.0

    def test_drop_is_capped(self, algo):
        # Absurd decay projects far below the floor; the cap holds at 25% down.
        self._with_trend(algo, [(0, 200_000.0), (900, 100_000.0)])
        assert algo._projected_avg_1h(100_000.0) == pytest.approx(75_000.0)

    def test_horizon_zero_disables(self, algo):
        self._with_trend(algo, [(0, 110_000.0), (900, 101_000.0)])
        with patch("mining_dashboard.service.algo_service.XVB_PROJECTION_HORIZON_S", 0):
            assert algo._projected_avg_1h(100_000.0) == 100_000.0

    def test_recording_appends_only_fresh_fetches(self, algo):
        ts = self.T0
        algo._record_avg1h_sample({"avg_1h": 100_000.0, "last_update": ts})
        algo._record_avg1h_sample({"avg_1h": 90_000.0, "last_update": ts})  # frozen read
        assert algo._avg1h_trend == [(ts, 100_000.0)]
        algo._record_avg1h_sample({"avg_1h": 95_000.0, "last_update": ts + 300})
        assert len(algo._avg1h_trend) == 2
        algo._record_avg1h_sample({"avg_1h": 95_000.0, "last_update": 0})  # never-fetched
        assert len(algo._avg1h_trend) == 2

    def test_recording_prunes_old_samples(self, algo):
        algo._record_avg1h_sample({"avg_1h": 100_000.0, "last_update": self.T0})
        algo._record_avg1h_sample({"avg_1h": 99_000.0, "last_update": self.T0 + 3000})
        assert [v for _, v in algo._avg1h_trend] == [99_000.0]

    def test_falling_trend_steps_up_where_reactive_stepped_down(self, algo):
        # Measured 1h sits just ABOVE the reference (reactive would ease off);
        # the recorded decay projects it below (protective ramps instead).
        algo.donation_fraction = 0.5
        target_hr = 100_000.0
        avg_1h = algo._reference_hr(target_hr) + 1_000.0
        reactive = AlgoService(algo.state_manager, MagicMock(), MagicMock())
        reactive.donation_fraction = 0.5
        reactive._advance_controller(200_000.0, target_hr, avg_1h, 0.85)
        assert reactive.donation_fraction < 0.5
        self._with_trend(algo, [(0, avg_1h + 9_000.0), (900, avg_1h)])
        algo._advance_controller(200_000.0, target_hr, avg_1h, 0.85)
        assert algo.donation_fraction > 0.5
