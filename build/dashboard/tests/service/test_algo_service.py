import asyncio
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from mining_dashboard.config.config import (
    TIER_DEFAULTS,
    XVB_STALE_DECAY_AFTER_S,
    XVB_STATS_STALE_AFTER_S,
    XVB_SWITCH_OVERHEAD_MS,
    XVB_TIME_ALGO_MS,
)
from mining_dashboard.service.algo_service import AlgoService


@pytest.fixture
def algo():
    state_manager = MagicMock()
    state_manager.get_tiers.return_value = dict(TIER_DEFAULTS)
    # Cold controller by default (#249): no persisted commanded fraction, no standby held — so
    # the warm-resume seed falls through to feedforward. Warm-resume tests override these.
    state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
    state_manager.get_xvb_standby.return_value = None
    proxy_client = MagicMock()  # called via asyncio.to_thread -> sync methods
    data_service = MagicMock()
    data_service.workers_rejected = False  # not rejecting workers (Issue #31 guard off)
    return AlgoService(state_manager, proxy_client, data_service)


# A share inside the PPLNS window (recent) so the "zero shares" guard doesn't trip.
RECENT_SHARES = [{"ts": 10**12}]  # far-future ts -> always within window
P2P_MAIN = {"type": "Main"}
POOL_STATS = {"pplns_window": 2160}  # no difficulty -> flat reserve
POOL_STATS_DIFF = {"pplns_window": 2160, "difficulty": 120_000_000}


def _fresh_ts():
    """A `last_update` that reads as a just-landed XvB fetch (not stale)."""
    return time.time()


def _stale_ts():
    """A `last_update` old enough that the fetch is considered stale (#311)."""
    return time.time() - (XVB_STATS_STALE_AFTER_S + 60)


def _decay_ts():
    """A `last_update` old enough to be past the prolonged-staleness decay grace, not just
    the short hold grace — the fail-safe should bleed the donation fraction toward 0."""
    return time.time() - (XVB_STALE_DECAY_AFTER_S + 60)


def _split_ms(decision):
    mode, dur = decision
    return XVB_TIME_ALGO_MS if mode == "XVB" else dur


class TestGetDecision:
    def test_xvb_disabled_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", False):
            assert algo.get_decision(100, 100, {}, {}, {}, RECENT_SHARES) == ("P2POOL", 0)

    def test_zero_shares_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            mode, dur = algo.get_decision(
                10_000,
                10_000,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                [],
            )
            assert mode == "P2POOL"

    def test_excessive_failures_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            mode, _ = algo.get_decision(
                10_000,
                10_000,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 9_999_999, "avg_1h": 9_999_999, "fail_count": 3},
                RECENT_SHARES,
            )
            assert mode == "P2POOL"

    def test_low_hashrate_no_tier_is_p2pool(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # 100 H/s * 0.85 < lowest tier (1000) -> no tier -> P2POOL
            mode, _ = algo.get_decision(
                100,
                100,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert mode == "P2POOL"

    def test_cold_start_seeds_feedforward(self, algo):
        """The first decision seeds the donated fraction from the feedforward
        estimate (reference / current_hr), so it starts donating a sane amount."""
        algo.donation_level = "vip"  # target 10_000
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            mode, dur = algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert mode in ("SPLIT", "XVB")
            # reference 10_300 / 46_300 ~ 0.222 of the cycle.
            assert algo.donation_fraction == pytest.approx(10_300 / 46_300, rel=0.05)

    def test_loop_ramps_up_when_below_reference(self, algo):
        """Calling repeatedly with the 1h average below reference integrates the
        donated fraction upward (closed-loop catch-up, not a one-shot spike)."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            d1 = algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            f_after_seed = algo.donation_fraction
            d2 = algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert algo.donation_fraction > f_after_seed  # ramped up
            assert _split_ms(d2) > _split_ms(d1)

    def test_loop_backs_off_when_above_reference(self, algo):
        """When XvB reports above the reference (over target), the loop trims the
        donated fraction — the property the old unbounded catch-up lacked."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            seeded = algo.donation_fraction
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 30_000, "avg_24h": 30_000, "fail_count": 0},
                RECENT_SHARES,
            )
            assert algo.donation_fraction < seeded  # backed off

    def test_advance_false_does_not_move_the_loop(self, algo):
        """_smart_sleep re-reads with advance=False; that must not step the loop."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            held = algo.donation_fraction
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
                advance=False,
            )
            assert algo.donation_fraction == held

    def test_nano_pool_uses_longer_window(self, algo):
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            mode, _ = algo.get_decision(
                10_000,
                10_000,
                POOL_STATS,
                {"type": "Nano"},
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert mode in ("P2POOL", "XVB", "SPLIT")


class TestVipReserve:
    def test_difficulty_reserve_caps_donation(self, algo):
        """The reserve keeps p2pool enough hashrate to hold a PPLNS share (VIP)."""
        # window = 2160*10 = 21600s; min_p2pool = 120e6/21600 * 2 ~ 11_111 H/s.
        frac = algo._max_donation_fraction(46_300, 21600, POOL_STATS_DIFF)
        assert frac == pytest.approx(1 - 11_111 / 46_300, rel=0.02)

    def test_falls_back_to_flat_cap_without_difficulty(self, algo):
        assert algo._max_donation_fraction(46_300, 21600, POOL_STATS) == algo.max_donation_fraction

    def test_reserve_never_exceeds_hard_cap(self, algo):
        # Huge hashrate, tiny difficulty -> sparable ~1.0, clamped to the hard cap.
        frac = algo._max_donation_fraction(10_000_000, 21600, {"difficulty": 1_000})
        assert frac == algo.max_donation_fraction

    def test_loop_clamped_to_reserve(self, algo):
        """The integrator can never push the donated fraction past the reserve."""
        algo.donation_level = "mega"  # unsustainable target -> loop pushes up hard
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            for _ in range(50):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS_DIFF,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                    RECENT_SHARES,
                )
            cap = algo._max_donation_fraction(46_300, 21600, POOL_STATS_DIFF)
            assert algo.donation_fraction <= cap + 1e-9


class TestHelpers:
    def test_reference_cushion_is_absolute_capped(self, algo):
        # Cushion above target is capped in ABSOLUTE H/s, so a huge tier doesn't
        # waste a percentage of a huge number.
        assert algo._reference_hr(1_000_000) == pytest.approx(1_000_000 + 1_000)
        # Small tier uses the percentage (3% of 10k = 300).
        assert algo._reference_hr(10_000) == pytest.approx(10_300)

    def test_fraction_to_ms_zero_and_positive(self, algo):
        assert algo._fraction_to_ms(0) == 0
        assert algo._fraction_to_ms(-1) == 0
        assert algo._fraction_to_ms(0.2) == pytest.approx(
            0.2 * XVB_TIME_ALGO_MS + XVB_SWITCH_OVERHEAD_MS, abs=1
        )

    def test_advance_noop_when_no_hashrate(self, algo):
        algo.donation_fraction = 0.3
        algo._advance_controller(0, 10_000, 0, 0.85)
        assert algo.donation_fraction == 0.3  # unchanged

    def test_advance_clamps_to_bounds(self, algo):
        algo.donation_fraction = 0.5
        # Way above reference -> error negative -> would go negative -> clamps at 0.
        for _ in range(100):
            algo._advance_controller(46_300, 10_000, 10_000_000, 0.85)
        assert algo.donation_fraction == 0.0

    def test_routed_fraction_for_instrumentation(self, algo):
        assert algo._routed_fraction("P2POOL", 0) == 0.0
        assert algo._routed_fraction("XVB", XVB_TIME_ALGO_MS) == 1.0
        assert algo._routed_fraction("SPLIT", XVB_TIME_ALGO_MS // 2) == pytest.approx(0.5)

    def test_get_target_uses_state_manager_tiers(self, algo):
        algo.state_manager.get_tiers.return_value = {"donor": 1_000}
        # 2000 * 0.85 = 1700 >= 1000 -> threshold 1000
        assert algo._get_target_donation_hr(2_000) == 1_000

    def test_default_auto_targets_highest_sustainable(self, algo):
        # 1_000_000 * 0.85 = 850_000 -> Whale (100_000).
        assert algo._get_target_donation_hr(1_000_000) == 100_000

    def test_explicit_tier_not_downgraded(self, algo):
        algo.donation_level = "mega"
        assert algo._get_target_donation_hr(15_000) == 1_000_000


class TestStaleStatsGuard:
    """#311: when the xmrvsbeast.com stats fetch goes quiet, avg_1h freezes. The
    controller must not keep steering off that frozen number (it over-donates against
    a target it can't refresh). `last_update` (bumped only on a real fetch, #136) is
    the freshness signal."""

    def test_predicate_cold_start_is_not_stale(self, algo):
        # Never fetched (no/zero last_update) -> cold start, NOT stale: the
        # feedforward ramp must be left alone to climb to tier.
        assert algo._stats_are_stale({}) is False
        assert algo._stats_are_stale({"last_update": 0}) is False

    def test_predicate_fresh_is_not_stale(self, algo):
        assert algo._stats_are_stale({"last_update": _fresh_ts()}) is False

    def test_predicate_old_fetch_is_stale(self, algo):
        assert algo._stats_are_stale({"last_update": _stale_ts()}) is True

    def test_stale_read_holds_fraction_instead_of_winding_up(self, algo):
        """The bug: a frozen avg_1h below reference keeps ramping the donated
        fraction up. With a stale read the loop must HOLD, not advance."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # Seed from a fresh reading so we have a sane held fraction.
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            held = algo.donation_fraction
            # Now the fetch is stale and frozen below reference — must NOT ramp.
            for _ in range(10):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _stale_ts()},
                    RECENT_SHARES,
                )
            assert algo.donation_fraction == held  # held, not wound up

    def test_fresh_read_below_reference_still_ramps(self, algo):
        """Guard against over-correcting: a *fresh* below-tier read must still drive
        the #9/#70 catch-up. Only stale reads are frozen out."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            seeded = algo.donation_fraction
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            assert algo.donation_fraction > seeded  # fresh read still ramps

    def test_prolonged_stale_decays_fraction_toward_zero(self, algo):
        """Past the longer decay grace, holding blind is the bigger risk: the fail-safe
        must bleed the held fraction toward 0, not freeze it (the short-hold behavior)."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            # Seed a real held fraction from a fresh read.
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            held = algo.donation_fraction
            assert held > 0
            # One cycle past the decay grace: strictly smaller than the held fraction.
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _decay_ts()},
                RECENT_SHARES,
            )
            assert algo.donation_fraction < held
            # Keep decaying: it converges to exactly 0 (snapped at the floor), fully stopping.
            for _ in range(20):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _decay_ts()},
                    RECENT_SHARES,
                )
            assert algo.donation_fraction == 0.0

    def test_fresh_read_resumes_control_after_decay(self, algo):
        """The decay is a fail-safe, not a latch: once a genuine fetch lands again the
        controller must resume normal steering from the decayed fraction."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            # Decay it down over a prolonged outage.
            for _ in range(5):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _decay_ts()},
                    RECENT_SHARES,
                )
            decayed = algo.donation_fraction
            # A fresh, below-reference read resumes the catch-up ramp (advance runs again).
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            assert algo.donation_fraction > decayed  # control resumed, not still decaying

    async def test_smart_sleep_does_not_bail_early_on_stale_below_tier(self, algo):
        """The dominant symptom (#311): a frozen below-tier avg_1h made _smart_sleep
        end every p2pool dwell early, driving the effective split to ~55% XvB. With a
        stale read the under-tier override must pause — let the dwell run."""
        algo.data_service.latest_data = {
            "total_live_h15": 15_000,
            "total_live_h10": 15_000,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,  # frozen far below tier
            "fail_count": 0,
            "last_update": _stale_ts(),
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(90, check_interval_sec=30)
        assert slept.await_count == 3  # full dwell, no early bail

    async def test_smart_sleep_still_bails_on_fresh_below_tier(self, algo):
        """Regression guard: the catch-up early-exit must still fire on a FRESH
        below-tier read (mirrors test_aborts_early_when_below_tier with last_update)."""
        algo.data_service.latest_data = {
            "total_live_h15": 15_000,
            "total_live_h10": 15_000,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,
            "fail_count": 0,
            "last_update": _fresh_ts(),
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30)
        assert slept.await_count == 1  # bailed early to catch up


class TestSwitchMiners:
    async def test_switch_updates_proxy_and_state(self, algo):
        algo.proxy_client.get_config.return_value = {"pools": [], "other": "keep"}
        await algo.switch_miners("XVB")
        algo.proxy_client.update_config.assert_called_once()
        sent = algo.proxy_client.update_config.call_args[0][0]
        assert sent["other"] == "keep"  # preserves existing config
        assert sent["pools"][0]["enabled"] is True
        algo.state_manager.update_xvb_stats.assert_called_once()

    async def test_switch_aborts_on_bad_config(self, algo):
        algo.proxy_client.get_config.return_value = None
        await algo.switch_miners("P2POOL")
        algo.proxy_client.update_config.assert_not_called()

    async def test_xvb_pool_routed_over_tor_by_default(self, algo):
        # #166: the XvB pool carries a per-pool socks5 (Tor); the local p2pool pool never does.
        algo.proxy_client.get_config.return_value = {"pools": []}
        with (
            patch("mining_dashboard.service.algo_service.XVB_TOR_ENABLED", True),
            patch("mining_dashboard.service.algo_service.XVB_TOR_SOCKS5", "172.28.0.25:9050"),
        ):
            await algo.switch_miners("XVB")
        pools = algo.proxy_client.update_config.call_args[0][0]["pools"]
        xvb, local = pools[0], pools[1]  # enabled XvB pool first in XVB mode
        assert xvb["enabled"] is True and xvb["socks5"] == "172.28.0.25:9050"
        assert "socks5" not in local  # local p2pool dials direct, never via Tor

    async def test_local_pool_never_routed_over_tor(self, algo):
        # Even in P2POOL mode (XvB pool present but disabled), only the XvB pool carries socks5.
        algo.proxy_client.get_config.return_value = {"pools": []}
        with (
            patch("mining_dashboard.service.algo_service.XVB_TOR_ENABLED", True),
            patch("mining_dashboard.service.algo_service.XVB_TOR_SOCKS5", "172.28.0.25:9050"),
        ):
            await algo.switch_miners("P2POOL")
        pools = algo.proxy_client.update_config.call_args[0][0]["pools"]
        local, xvb = pools[0], pools[1]  # enabled local pool first in P2POOL mode
        assert "socks5" not in local
        assert xvb["socks5"] == "172.28.0.25:9050"

    async def test_xvb_tor_opt_out_no_socks5(self, algo):
        # xvb.tor:false → XVB_TOR_ENABLED False → no pool carries socks5 (direct clearnet, max yield).
        algo.proxy_client.get_config.return_value = {"pools": []}
        with patch("mining_dashboard.service.algo_service.XVB_TOR_ENABLED", False):
            await algo.switch_miners("XVB")
        pools = algo.proxy_client.update_config.call_args[0][0]["pools"]
        assert all("socks5" not in p for p in pools)


class TestSmartSleep:
    LATEST = {"total_live_h15": 15_000, "total_live_h10": 15_000, "pool": {}, "shares": []}

    async def test_aborts_early_when_decision_flips_to_donate(self, algo):
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}
        algo.get_decision = MagicMock(return_value=("SPLIT", 60_000))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30)
        assert slept.await_count == 1  # bailed after the first check

    async def test_aborts_early_when_below_tier(self, algo):
        """Even if the cached decision is P2POOL, a 1h average below the tier means
        we must catch up — bail to re-decide rather than wait out the dwell."""
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30)
        assert slept.await_count == 1

    async def test_split_remainder_not_ended_by_held_split_decision(self, algo):
        """#423: during a SPLIT remainder the re-read decision is SPLIT by
        construction (the fraction is static with advance=False). That must NOT
        end the dwell — pre-fix it did, collapsing every remainder to one tick,
        so the actuated donation duty became slice/(slice+tick) instead of
        slice/cycle: a sustained credited overshoot the controller couldn't
        unwind because its commanded fraction was already near zero."""
        algo.data_service.latest_data = dict(self.LATEST)
        # In tier: 1h above the VIP threshold, so the catch-up override is quiet.
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("SPLIT", 15_000))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(90, check_interval_sec=30, held_decision="SPLIT")
        assert slept.await_count == 3  # full remainder, no early bail

    async def test_split_remainder_still_bails_when_below_tier(self, algo):
        """The catch-up override survives the #423 fix: a fresh below-tier 1h
        average ends even a SPLIT remainder early (undershoot loses the tier)."""
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("SPLIT", 15_000))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30, held_decision="SPLIT")
        assert slept.await_count == 1

    async def test_split_remainder_bails_when_decision_changes(self, algo):
        """A decision that *changed* from the held one (a constraint tripped —
        shares gone, failures) still ends the remainder early."""
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30, held_decision="SPLIT")
        assert slept.await_count == 1

    async def test_sleeps_full_duration_when_in_tier_on_p2pool(self, algo):
        algo.data_service.latest_data = dict(self.LATEST)
        # In tier (1h above the VIP threshold) and decision P2POOL -> rest, no bail.
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(90, check_interval_sec=30)
        assert slept.await_count == 3  # 90s / 30s ticks, no early abort


class TestRunLoop:
    async def test_run_invokes_switch_then_stops(self, algo):
        algo.data_service.latest_data = {
            "total_live_h10": 10_000,
            "total_live_h15": 10_000,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        algo.switch_miners = MagicMock(side_effect=lambda *a, **k: asyncio.sleep(0))
        # Break the infinite loop on the second sleep call.
        with patch("asyncio.sleep", side_effect=[None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        assert algo.switch_miners.called

    async def test_run_split_remainder_dwell_holds_split_decision(self, algo):
        """#423 wiring: the SPLIT branch must hand the remainder to _smart_sleep
        with held_decision="SPLIT" — the actuated-duty fix lives in that argument."""
        algo.data_service.latest_data = {
            "total_live_h10": 46_300,
            "total_live_h15": 46_300,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("SPLIT", 15_000))
        algo.switch_miners = AsyncMock()
        algo._smart_sleep = AsyncMock(side_effect=Exception("stop"))
        # sleeps: initial 5s, the 15s donated slice, then the error-path sleep raises.
        with patch("asyncio.sleep", side_effect=[None, None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        expected_remainder = (XVB_TIME_ALGO_MS - 15_000) / 1000
        algo._smart_sleep.assert_awaited_once_with(expected_remainder, held_decision="SPLIT")

    async def test_run_skips_switching_while_workers_rejected(self, algo):
        # When a node is down and workers are rejected (Issue #31), the proxy is stopped —
        # the loop must not try to reconfigure it.
        algo.data_service.workers_rejected = True
        algo.switch_miners = MagicMock(side_effect=lambda *a, **k: asyncio.sleep(0))
        with patch("asyncio.sleep", side_effect=[None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        assert not algo.switch_miners.called


class TestWarmResume:
    """Warm-resume of the closed-loop state on restart / backup failover (#249).

    The seed precedence is: this host's own persisted commanded fraction (a restart, or a stack
    that has already steered) beats the primary's standby (a first failover), which beats the cold
    feedforward estimate (a fresh install with no history)."""

    def test_seed_prefers_own_persisted_fraction(self, algo):
        # Own state wins over standby: an authoritative stack owns its steering, so a stale standby
        # from a departed primary can't override it.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.4}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.9}
        assert algo._seed_donation_fraction(1000, 2000, 0.85) == 0.4

    def test_seed_adopts_standby_when_no_own_state(self, algo):
        # The failover case: an idle backup never steered (own fraction 0.0), so at handover it
        # adopts the primary's last-known commanded fraction.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.3}
        assert algo._seed_donation_fraction(1000, 2000, 0.85) == 0.3

    def test_seed_clamps_standby_to_vip_reserve(self, algo):
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.99}
        assert algo._seed_donation_fraction(1000, 2000, 0.5) == 0.5

    def test_seed_cold_start_uses_feedforward_when_no_state(self, algo):
        # Fresh install: no own state, no standby -> the original feedforward seed, unchanged.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = None
        # reference = 1000 + min(1000*0.03, 1000) = 1030; feedforward = 1030 / current_hr.
        assert algo._seed_donation_fraction(1000, 2000, 0.85) == pytest.approx(1030 / 2000)

    def test_get_decision_seeds_from_standby_on_failover(self, algo):
        # Integration: the first real donating cycle on a warm backup adopts the standby fraction
        # rather than cold-ramping from feedforward.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.35}
        assert algo.donation_fraction is None
        algo.get_decision(
            2000,
            2000,
            POOL_STATS,
            P2P_MAIN,
            {"avg_1h": 500, "last_update": _fresh_ts()},
            RECENT_SHARES,
        )
        assert algo.donation_fraction == pytest.approx(0.35)
