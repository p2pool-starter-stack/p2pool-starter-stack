"""Shared fixtures for dashboard/tests/service/. Currently just ``algo``, used by
AlgoService's tests, split across test_algo_service.py and test_projected_steering.py (#1285)."""

from unittest.mock import MagicMock

import pytest

from mining_dashboard.config.config import TIER_DEFAULTS
from mining_dashboard.service.algo_service import AlgoService


@pytest.fixture
def algo():
    state_manager = MagicMock()
    state_manager.get_tiers.return_value = dict(TIER_DEFAULTS)
    # Cold controller by default (#249): no persisted commanded fraction, no standby held — so
    # the warm-resume seed falls through to feedforward. Warm-resume tests override these.
    state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
    state_manager.get_xvb_standby.return_value = None
    # No recorded raffle wins by default, so the in-round hold (#769) is inactive
    # and the calibration loop steers freely. Hold tests override this.
    state_manager.get_raffle_wins.return_value = []
    proxy_client = MagicMock()  # called via asyncio.to_thread -> sync methods
    data_service = MagicMock()
    data_service.workers_rejected = False  # not rejecting workers (Issue #31 guard off)
    return AlgoService(state_manager, proxy_client, data_service)
