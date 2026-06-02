import asyncio
from unittest.mock import MagicMock, patch

import pytest

from mining_dashboard.service.algo_service import AlgoService
from mining_dashboard.config.config import TIER_DEFAULTS, XVB_TIME_ALGO_MS


@pytest.fixture
def algo():
    state_manager = MagicMock()
    state_manager.get_tiers.return_value = dict(TIER_DEFAULTS)
    proxy_client = MagicMock()       # called via asyncio.to_thread -> sync methods
    data_service = MagicMock()
    return AlgoService(state_manager, proxy_client, data_service)


# A share inside the PPLNS window (recent) so the "zero shares" guard doesn't trip.
RECENT_SHARES = [{"ts": 10**12}]  # far-future ts -> always within window
P2P_MAIN = {"type": "Main"}
POOL_STATS = {"pplns_window": 2160}


class TestGetDecision:
    def test_xvb_disabled_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", False):
            assert algo.get_decision(100, 100, {}, {}, {}, RECENT_SHARES) == ("P2POOL", 0)

    def test_zero_shares_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            mode, dur = algo.get_decision(10_000, 10_000, POOL_STATS, P2P_MAIN,
                                          {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}, [])
            assert mode == "P2POOL"

    def test_excessive_failures_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            mode, _ = algo.get_decision(10_000, 10_000, POOL_STATS, P2P_MAIN,
                                        {"avg_24h": 9_999_999, "avg_1h": 9_999_999, "fail_count": 3},
                                        RECENT_SHARES)
            assert mode == "P2POOL"

    def test_low_hashrate_no_tier_is_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # 100 H/s * 0.85 < lowest tier (1000) -> no tier -> P2POOL
            mode, _ = algo.get_decision(100, 100, POOL_STATS, P2P_MAIN,
                                        {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}, RECENT_SHARES)
            assert mode == "P2POOL"

    def test_target_not_met_forces_xvb(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # stable 15k -> qualifies VIP (10k); 24h/1h avg below target -> XVB full cycle
            mode, dur = algo.get_decision(15_000, 15_000, POOL_STATS, P2P_MAIN,
                                          {"avg_24h": 100, "avg_1h": 100, "fail_count": 0}, RECENT_SHARES)
            assert mode == "XVB"
            assert dur == XVB_TIME_ALGO_MS

    def test_target_met_enters_split_or_full(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # target met (24h & 1h >= 10k) and high current_hr -> SPLIT (partial) or XVB (full cycle)
            mode, dur = algo.get_decision(1_000_000, 15_000, POOL_STATS, P2P_MAIN,
                                          {"avg_24h": 10_000, "avg_1h": 10_000, "fail_count": 0}, RECENT_SHARES)
            assert mode in ("SPLIT", "XVB")
            assert dur > 0

    def test_nano_pool_uses_longer_window(self, algo):
        # Nano pool block_time=30; verify the branch is exercised without error.
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            mode, _ = algo.get_decision(10_000, 10_000, POOL_STATS, {"type": "Nano"},
                                        {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}, RECENT_SHARES)
            assert mode in ("P2POOL", "XVB", "SPLIT")


class TestHelpers:
    def test_get_needed_time_zero_when_no_hashrate(self, algo):
        assert algo._get_needed_time(0, 10_000) == 0

    def test_get_needed_time_scales_with_target(self, algo):
        # higher target -> more time needed
        t_low = algo._get_needed_time(10_000, 5_000)
        t_high = algo._get_needed_time(10_000, 9_000)
        assert t_high > t_low > 0

    def test_get_target_uses_state_manager_tiers(self, algo):
        algo.state_manager.get_tiers.return_value = {"donor": 1_000}
        # 2000 * 0.85 = 1700 >= 1000 -> threshold 1000
        assert algo._get_target_donation_hr(2_000) == 1_000


class TestSwitchMiners:
    async def test_switch_updates_proxy_and_state(self, algo):
        algo.proxy_client.get_config.return_value = {"pools": [], "other": "keep"}
        await algo.switch_miners("XVB")
        algo.proxy_client.update_config.assert_called_once()
        sent = algo.proxy_client.update_config.call_args[0][0]
        assert sent["other"] == "keep"           # preserves existing config
        assert sent["pools"][0]["enabled"] is True
        algo.state_manager.update_xvb_stats.assert_called_once()

    async def test_switch_aborts_on_bad_config(self, algo):
        algo.proxy_client.get_config.return_value = None
        await algo.switch_miners("P2POOL")
        algo.proxy_client.update_config.assert_not_called()


class TestRunLoop:
    async def test_run_invokes_switch_then_stops(self, algo):
        algo.data_service.latest_data = {"total_live_h10": 10_000, "total_live_h15": 10_000,
                                         "pool": {}, "shares": []}
        algo.state_manager.get_xvb_stats.return_value = {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        algo.switch_miners = MagicMock(side_effect=lambda *a, **k: asyncio.sleep(0))
        # Break the infinite loop on the second sleep call.
        with patch("asyncio.sleep", side_effect=[None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        assert algo.switch_miners.called
