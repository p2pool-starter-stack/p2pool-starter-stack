import asyncio
from unittest.mock import MagicMock, AsyncMock, patch

import pytest

from mining_dashboard.service.algo_service import AlgoService
from mining_dashboard.config.config import TIER_DEFAULTS, XVB_TIME_ALGO_MS


@pytest.fixture
def algo():
    state_manager = MagicMock()
    state_manager.get_tiers.return_value = dict(TIER_DEFAULTS)
    proxy_client = MagicMock()       # called via asyncio.to_thread -> sync methods
    data_service = MagicMock()
    data_service.workers_rejected = False  # not rejecting workers (Issue #31 guard off)
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

    def test_below_target_ramps_donation_above_maintenance(self, algo):
        algo.donation_level = "donor"  # fixed target (1000) so neither case clamps to F_MAX
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # Behind on both averages -> catch-up donates strictly more time than
            # when comfortably in tier (no binary "force full cycle" anymore).
            behind = algo.get_decision(15_000, 15_000, POOL_STATS, P2P_MAIN,
                                       {"avg_24h": 100, "avg_1h": 100, "fail_count": 0}, RECENT_SHARES)
            in_tier = algo.get_decision(15_000, 15_000, POOL_STATS, P2P_MAIN,
                                        {"avg_24h": 5_000, "avg_1h": 5_000, "fail_count": 0}, RECENT_SHARES)
            assert behind[0] in ("SPLIT", "XVB")
            behind_ms = XVB_TIME_ALGO_MS if behind[0] == "XVB" else behind[1]
            in_tier_ms = XVB_TIME_ALGO_MS if in_tier[0] == "XVB" else in_tier[1]
            assert behind_ms > in_tier_ms

    def test_target_met_enters_split_or_full(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # In tier with huge headroom -> minimal donation (SPLIT), not a full cycle.
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
        # In tier (no catch-up) with huge headroom so the fraction isn't clamped:
        # a higher target needs proportionally more donation time.
        t_low = algo._get_needed_time(1_000_000, 5_000, avg_1h=5_000, avg_24h=5_000)
        t_high = algo._get_needed_time(1_000_000, 50_000, avg_1h=50_000, avg_24h=50_000)
        assert t_high > t_low > 0

    def test_maintenance_cushion_is_absolute_capped(self, algo):
        # The steady-state cushion above target is capped in ABSOLUTE H/s, so a
        # huge tier doesn't waste a percentage of a huge number (the #9 fix).
        H = 10_000_000
        big = algo._get_needed_time(H, 1_000_000, avg_1h=1_000_000, avg_24h=1_000_000)
        donated_rate = ((big - 5000) / XVB_TIME_ALGO_MS) * H   # back out donated H/s
        cushion = donated_rate - 1_000_000
        # ~1000 (the cap), NOT ~50_000 that a flat 5% would waste.
        assert 900 < cushion < 1_100

    def test_donation_fraction_capped_by_max_fraction(self, algo):
        # Deeply behind with little headroom: never donate more than F_MAX.
        ms = algo._get_needed_time(10_000, 8_000, avg_1h=0, avg_24h=0)
        fraction = (ms - 5000) / XVB_TIME_ALGO_MS
        assert fraction <= algo.max_donation_fraction + 1e-9

    def test_get_target_uses_state_manager_tiers(self, algo):
        algo.state_manager.get_tiers.return_value = {"donor": 1_000}
        # 2000 * 0.85 = 1700 >= 1000 -> threshold 1000
        assert algo._get_target_donation_hr(2_000) == 1_000

    def test_default_auto_targets_highest_sustainable(self, algo):
        # Default donation level is "auto" -> highest sustainable tier.
        # 1_000_000 * 0.85 = 850_000 -> Whale (100_000).
        assert algo._get_target_donation_hr(1_000_000) == 100_000

    def test_auto_targets_highest_sustainable_tier(self, algo):
        algo.donation_level = "auto"
        # 15000 * 0.85 = 12750 -> highest sustainable is VIP (10000).
        assert algo._get_target_donation_hr(15_000) == 10_000

    def test_explicit_tier_not_downgraded(self, algo):
        # Explicitly choosing a tier above capacity is honored, not downgraded.
        algo.donation_level = "mega"
        assert algo._get_target_donation_hr(15_000) == 1_000_000


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


class TestSmartSleep:
    LATEST = {"total_live_h15": 15_000, "total_live_h10": 15_000, "pool": {}, "shares": []}

    async def test_aborts_early_when_decision_flips_to_donate(self, algo):
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}
        algo.get_decision = MagicMock(return_value=("SPLIT", 60_000))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30)
        assert slept.await_count == 1  # bailed after the first check

    async def test_sleeps_full_duration_when_staying_p2pool(self, algo):
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(90, check_interval_sec=30)
        assert slept.await_count == 3  # 90s / 30s ticks, no early abort


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

    async def test_run_skips_switching_while_workers_rejected(self, algo):
        # When a node is down and workers are rejected (Issue #31), the proxy is stopped —
        # the loop must not try to reconfigure it.
        algo.data_service.workers_rejected = True
        algo.switch_miners = MagicMock(side_effect=lambda *a, **k: asyncio.sleep(0))
        with patch("asyncio.sleep", side_effect=[None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        assert not algo.switch_miners.called
