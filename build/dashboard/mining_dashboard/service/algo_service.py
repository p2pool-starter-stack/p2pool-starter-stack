import asyncio
import logging
import time
import math
from mining_dashboard.config.config import (
    XVB_TIME_ALGO_MS,
    MONERO_WALLET_ADDRESS,
    XVB_DONOR_ID,
    P2POOL_URL,
    XVB_POOL_URL,
    XVB_MIN_TIME_SEND_MS,
    ENABLE_XVB,
    XVB_DONATION_LEVEL,
    XVB_MAX_DONATION_FRACTION,
    XVB_MAINT_MARGIN_PCT,
    XVB_MAINT_MARGIN_ABS_CAP,
    XVB_CATCHUP_GAIN_1H,
    XVB_CATCHUP_GAIN_24H,
    XVB_SWITCH_OVERHEAD_MS,
    UPDATE_INTERVAL
)
from mining_dashboard.helper.utils import resolve_target_threshold

logger = logging.getLogger("AlgoService")

class AlgoService:
    def __init__(self, state_manager, proxy_client, data_service):
        self.state_manager = state_manager
        self.proxy_client = proxy_client
        self.data_service = data_service
        # XvB donation controller tuning (see config.py).
        self.donation_level = XVB_DONATION_LEVEL
        self.max_donation_fraction = XVB_MAX_DONATION_FRACTION
        self.maint_margin_pct = XVB_MAINT_MARGIN_PCT
        self.maint_margin_abs_cap = XVB_MAINT_MARGIN_ABS_CAP
        self.catchup_gain_1h = XVB_CATCHUP_GAIN_1H
        self.catchup_gain_24h = XVB_CATCHUP_GAIN_24H

    async def switch_miners(self, mode, state_label=None):
        """
        Configures the upstream pool priority for the XMRig Proxy.
        """
        if mode == "P2POOL":
            pools = [
                {"url": P2POOL_URL, "user": MONERO_WALLET_ADDRESS, "pass": "x", "enabled": True, "coin": "monero"},
                {"url": XVB_POOL_URL, "user": XVB_DONOR_ID, "pass": "x", "enabled": False, "coin": "monero"}
            ]
        else:
            pools = [
                {"url": XVB_POOL_URL, "user": XVB_DONOR_ID, "pass": "x", "enabled": True, "coin": "monero"},
                {"url": P2POOL_URL, "user": MONERO_WALLET_ADDRESS, "pass": "x", "enabled": False, "coin": "monero"}
            ]

        try:
            # Fetch current full configuration to preserve other settings
            current_config = await asyncio.to_thread(self.proxy_client.get_config)
            if not current_config or not isinstance(current_config, dict):
                logger.error("Failed to fetch valid proxy config, aborting switch.")
                return

            current_config["pools"] = pools

            # Execute update via Proxy Client with the full configuration
            await asyncio.to_thread(self.proxy_client.update_config, current_config)
            
            # Update state manager with the new active mode
            final_label = state_label if state_label else mode
            await asyncio.to_thread(self.state_manager.update_xvb_stats, mode=final_label)
            logger.info(f"Switched Proxy to mode: {mode} (Label: {final_label})")
        except Exception as e:
            logger.error(f"Failed to switch proxy mode: {e}")

    def get_decision(self, current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares):
        """
        Evaluates the current mining state to determine the next operation mode.

        Args:
            current_hr (float): Current real-time (10s) hashrate for calculation.
            stable_hr (float): Stable (15m) hashrate for tier selection.
            p2pool_stats (dict): Statistics from the local P2Pool node.
            p2p_stats (dict): P2P network statistics (for pool type detection).
            xvb_stats (dict): Historical statistics for XvB mining.
            shares (list): List of recent shares with timestamps.

        Returns:
            tuple: (Mode String ["P2POOL"|"XVB"|"SPLIT"], Duration in ms)
        """
        # Feature Flag: Check if XvB switching is globally disabled
        if not ENABLE_XVB:
            return "P2POOL", 0

        # Constraint: Enforce P2Pool mode if no shares have been found recently.
        # This uses the same logic as the dashboard UI to count shares within the PPLNS window.
        pool_type = p2p_stats.get('type', 'Main')
        pplns_window = p2pool_stats.get('pplns_window', 2160)
        
        block_time = 10  # Default for Main/Mini
        if pool_type == "Nano":
            block_time = 30

        window_duration = pplns_window * block_time
        cutoff = time.time() - window_duration
        shares_in_window_count = sum(1 for s in shares if s.get('ts', 0) >= cutoff)

        if shares_in_window_count == 0:
            logger.info(f"Decision Strategy: Force P2POOL (Zero shares in PPLNS window of {window_duration}s)")
            return "P2POOL", 0

        # Constraint: Fallback to P2Pool if XvB endpoint failures exceed threshold.
        fail_count = xvb_stats.get('fail_count', 0)
        if fail_count >= 3:
            logger.warning(f"Decision Strategy: Force P2POOL (Excessive XvB failures: {fail_count})")
            return "P2POOL", 0

        # Highest tier we can sustain, capped by the configured donation level.
        # Uses STABLE hashrate so the target doesn't jump with short-term variance.
        target_hr = self._get_target_donation_hr(stable_hr)

        # If no tier qualifies (can't sustain even the lowest), stay on P2Pool.
        if target_hr == 0:
             return "P2POOL", 0

        avg_24h = xvb_stats.get('avg_24h', 0)
        avg_1h = xvb_stats.get('avg_1h', 0)

        # Feedback controller: time to donate this cycle to hold the measured
        # averages just above target (maintenance), ramping up when behind.
        needed_time_ms = self._get_needed_time(current_hr, target_hr, avg_1h, avg_24h)
        if needed_time_ms <= 0:
            return "P2POOL", 0

        # Enforce the minimum dwell so a slice is long enough to submit shares.
        if needed_time_ms < XVB_MIN_TIME_SEND_MS:
            needed_time_ms = XVB_MIN_TIME_SEND_MS

        # If the P2Pool remainder would be tiny (< 30s), commit the whole cycle to
        # XvB to avoid inefficient short switches.
        if (XVB_TIME_ALGO_MS - needed_time_ms) < 30000:
            needed_time_ms = XVB_TIME_ALGO_MS

        if needed_time_ms >= XVB_TIME_ALGO_MS:
            logger.info(f"Decision: Full XVB cycle (target {target_hr:.0f}; 1h {avg_1h:.0f} / 24h {avg_24h:.0f})")
            return "XVB", XVB_TIME_ALGO_MS

        logger.info(f"Decision: Split ({needed_time_ms}ms to XvB; target {target_hr:.0f}; 1h {avg_1h:.0f} / 24h {avg_24h:.0f})")
        return "SPLIT", int(needed_time_ms)

    def _get_target_donation_hr(self, stable_hr):
        """
        Resolves the donation tier threshold to target for the given (stable)
        hashrate. "auto" picks the highest sustainable tier; an explicit tier is
        honored as-is (not downgraded). Returns 0 to donate nothing.
        """
        tiers = self.state_manager.get_tiers()
        target, _ = resolve_target_threshold(
            tiers, stable_hr, self.donation_level, self.max_donation_fraction
        )
        return target

    def _get_needed_time(self, current_hr, target_hr, avg_1h=0, avg_24h=0):
        """
        Donation time (ms) for this cycle to hold the measured average just above
        the tier threshold.

        The proxy donates the full hashrate during a slice, so the windowed
        average XvB measures ≈ donated_fraction * current_hr. We pick a desired
        effective rate R and convert it via R / current_hr:

            R = target
                + maintenance cushion (small %, capped in absolute H/s)
                + proportional catch-up for any trailing average below target

        The maintenance cushion keeps us just above target without the flat-5%
        waste at high tiers; the catch-up ramps donation when behind instead of
        dumping a full cycle. The fraction is clamped to max_donation_fraction so
        p2pool always keeps a slice (needed for VIP status / round validity).
        """
        if current_hr <= 0:
            return 0

        # Steady-state: sit just above target. Small %, capped absolutely.
        rate = target_hr + min(target_hr * self.maint_margin_pct, self.maint_margin_abs_cap)

        # Proportional catch-up when a trailing average is below target.
        if avg_1h < target_hr:
            rate += (target_hr - avg_1h) * self.catchup_gain_1h
        if avg_24h < target_hr:
            rate += (target_hr - avg_24h) * self.catchup_gain_24h

        fraction = min(rate / current_hr, self.max_donation_fraction)
        needed = fraction * XVB_TIME_ALGO_MS + XVB_SWITCH_OVERHEAD_MS
        return math.ceil(needed)

    async def _smart_sleep(self, duration_sec, check_interval_sec=None):
        """
        Sleep through a P2Pool dwell in chunks, re-running the decision each chunk.
        Returns early if the algorithm would now donate (hashrate dropped or a
        trailing average fell below tier), so the next cycle reacts in seconds
        instead of waiting out the full window. Uses only cached state — no extra
        external API calls.
        """
        if check_interval_sec is None:
            check_interval_sec = UPDATE_INTERVAL

        elapsed = 0
        while elapsed < duration_sec:
            tick = min(check_interval_sec, duration_sec - elapsed)
            await asyncio.sleep(tick)
            elapsed += tick

            try:
                latest = self.data_service.latest_data
                stable_hr = latest.get("total_live_h15", 0) or latest.get("total_live_h10", 0)
                current_hr = latest.get("total_live_h10", 0) or stable_hr
                xvb_stats = self.state_manager.get_xvb_stats()
                shares = latest.get("shares", [])
                p2pool_stats = latest.get("pool", {}).get("pool", {})
                p2p_stats = latest.get("pool", {}).get("p2p", {})

                decision, _ = self.get_decision(
                    current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares
                )
                if decision in ("XVB", "SPLIT"):
                    logger.info("Smart-sleep: donation target needs attention — ending P2Pool dwell early.")
                    return
            except Exception as e:
                logger.debug(f"Smart-sleep check error: {e}")

    async def run(self):
        """
        Periodic task to execute the mining strategy algorithm.
        Determines the optimal mining mode and manages worker switching cycles.
        """
        logger.info("Service Started: Algorithm Control Loop")
        await asyncio.sleep(5) 
        
        while True:
            try:
                # Access latest data from DataService
                latest_data = self.data_service.latest_data
                
                # Use 10s average for immediate reaction to hashrate drops
                current_hr = latest_data.get("total_live_h10", 0)
                if current_hr == 0:
                    current_hr = latest_data.get("total_live_h15", 0)

                # Use 15m average for stable tier selection
                stable_hr = latest_data.get("total_live_h15", 0)
                if stable_hr == 0:
                    stable_hr = current_hr

                p2pool_data = latest_data.get("pool", {})
                p2pool_stats = p2pool_data.get("pool", {})
                p2p_stats = p2pool_data.get("p2p", {})
                xvb_stats = self.state_manager.get_xvb_stats()
                shares = latest_data.get("shares", [])
                
                # Execute decision logic
                decision, xvb_duration = self.get_decision(current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares)
                
                if decision == "P2POOL":
                    await self.switch_miners("P2POOL", state_label="P2POOL")
                    # Poll during the dwell so a hashrate/average drop is caught
                    # within seconds instead of after the full cycle.
                    await self._smart_sleep(XVB_TIME_ALGO_MS / 1000)

                elif decision == "XVB":
                    await self.switch_miners("XVB", state_label="XVB")
                    await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)

                elif decision == "SPLIT":
                    # Split Mode: Allocate time slice to XvB, remainder to P2Pool
                    await self.switch_miners("XVB", state_label="XVB (Split)")
                    await asyncio.sleep(xvb_duration / 1000)

                    remainder = (XVB_TIME_ALGO_MS - xvb_duration) / 1000
                    if remainder > 0:
                        await self.switch_miners("P2POOL", state_label="P2POOL (Split)")
                        await self._smart_sleep(remainder)

            except Exception as e:
                logger.error(f"Algorithm Error: {e}")
                await asyncio.sleep(10)